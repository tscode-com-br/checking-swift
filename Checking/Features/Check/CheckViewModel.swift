import Foundation
import Observation

/// Máquina de estado de auth/conta — port da fatia auth de CheckViewModel.kt. `@Observable @MainActor`;
/// jobs canceláveis (debounce 800ms, polling 10s, SSE). Ver port_spec_auth_lifecycle §6.
/// (Fluxos de main-screen — projetos/locations/transport — são deferidos aos seus slices.)
@Observable
@MainActor
final class CheckViewModel {
    private(set) var uiState = CheckUiState()
    private var languageCode = "pt"

    private let appPreferences: any AppPreferencesStore
    private let securePasswordStore: any SecurePasswordStore
    private let authRepository: any AuthRepository
    private let projectRepository: any ProjectListing
    private let checkRepository: any CheckRepository
    private let orchestrator: any OrchestratorRunning
    private let checkEventStream: any CheckEventStreaming
    private let activityLogger: any ActivityLogging
    private let clock: any Clock

    private var passwordVerifyTask: Task<Void, Never>?
    private var chaveTask: Task<Void, Never>?
    private var pendingApprovalPollTask: Task<Void, Never>?
    private var pollGeneration = 0       // token: só a geração mais recente pode limpar pendingApprovalPollTask
    private var checkSseTask: Task<Void, Never>?
    // Sem `deinit`: `deinit` de uma classe `@MainActor` roda nonisolated (Swift 6) e não pode acessar estas
    // propriedades isoladas. Em vez disso, `startPendingApprovalPolling`/`startCheckStream` capturam `[weak self]`
    // — ao desalocar o VM, a próxima checagem acha `self` nil e o loop sai sozinho (sem retenção indefinida).

    init(appPreferences: any AppPreferencesStore, securePasswordStore: any SecurePasswordStore,
         authRepository: any AuthRepository, projectRepository: any ProjectListing,
         checkRepository: any CheckRepository, orchestrator: any OrchestratorRunning,
         checkEventStream: any CheckEventStreaming, activityLogger: any ActivityLogging, clock: any Clock) {
        self.appPreferences = appPreferences; self.securePasswordStore = securePasswordStore
        self.authRepository = authRepository; self.projectRepository = projectRepository
        self.checkRepository = checkRepository; self.orchestrator = orchestrator
        self.checkEventStream = checkEventStream; self.activityLogger = activityLogger; self.clock = clock
        Task { await restore() }
    }

    // MARK: - init / restore

    private func restore() async {
        let storedLang = await appPreferences.language()
        languageCode = resolveInitialLanguageCode(storedLang.isEmpty ? nil : storedLang)
        let storedChave = await appPreferences.chave()
        if storedChave.count == 4 {
            let storedPw = securePasswordStore.getPassword(storedChave)
            let settings = await loadUserSettings(storedChave)
            uiState.chave = storedChave
            uiState.password = storedPw
            applySettings(settings)
            uiState.isInitializing = false
            await probeStatus(storedChave)
        } else {
            uiState.isInitializing = false
        }
    }

    private func applySettings(_ settings: UserSettings) {
        uiState.automaticActivitiesEnabled = settings.automaticActivitiesEnabled
        uiState.scheduledPauseEnabled = settings.scheduledPauseEnabled
        uiState.scheduledPauseFrom = settings.scheduledPauseFrom
        uiState.scheduledPauseTo = settings.scheduledPauseTo
        uiState.suspendSaturdays = settings.suspendSaturdays
        uiState.suspendSundays = settings.suspendSundays
        uiState.notifyActivities = settings.notifyActivities
        uiState.notifyScheduledPause = settings.notifyScheduledPause
        uiState.notifyAccident = settings.notifyAccident
    }

    private func loadUserSettings(_ chave: String) async -> UserSettings {
        let raw = await appPreferences.userSettingsJson()
        let map = try? JSONCoding.decoder.decode([String: UserSettings].self, from: Data(raw.utf8))
        return resolvePersistedUserSettings(map, chave)
    }

    // MARK: - chave / senha

    func onChaveChanged(_ rawValue: String) {
        let sanitized = sanitizeSettingsChave(rawValue)
        chaveTask?.cancel()                                      // aborta o fluxo de probe/login da chave anterior
        passwordVerifyTask?.cancel()
        stopPendingApprovalPolling()
        stopCheckStream()

        uiState.chave = sanitized
        uiState.password = ""
        uiState.authStatus = nil
        uiState.prompt = ""
        uiState.isStatusLoading = false
        uiState.statusErrored = false
        uiState.dialogOpen = nil
        uiState.dismissedAssistanceForChave = ""
        uiState.notificationPrimary = ""
        uiState.notificationSecondary = ""
        uiState.notificationTone = .none
        uiState.historyState = nil

        chaveTask = Task {
            await appPreferences.setChave(sanitized)
            if sanitized.count != 4 {
                _ = await authRepository.logout()
                return
            }
            let storedPw = securePasswordStore.getPassword(sanitized)
            if !storedPw.isEmpty { uiState.password = storedPw }
            await probeStatus(sanitized)
        }
    }

    func onPasswordChanged(_ rawValue: String) {
        uiState.password = rawValue
        passwordVerifyTask?.cancel()
        guard let status = uiState.authStatus, status.hasPassword, isPasswordVerificationInputValid(rawValue) else { return }
        passwordVerifyTask = Task {
            try? await Task.sleep(for: .milliseconds(800))     // debounce cancelável a cada tecla
            if Task.isCancelled { return }
            await attemptLogin(uiState.chave, rawValue)
        }
    }

    // MARK: - probe / polling

    private func probeStatus(_ chave: String) async {
        _ = await authRepository.logout()                       // limpa sessão obsoleta ANTES
        guard uiState.chave == chave else { return }             // chave mudou enquanto aguardava — descarta
        uiState.isStatusLoading = true
        switch await authRepository.getStatus(chave) {
        case .success(let status):
            guard uiState.chave == chave else { return }         // resposta tardia p/ chave abandonada — descarta
            uiState.authStatus = status
            uiState.isStatusLoading = false
            uiState.prompt = resolvePrompt(status)
            if status.pendingApproval {
                uiState.notificationPrimary = t("auth.awaitingApproval", lang: languageCode)
                uiState.notificationSecondary = ""
                uiState.notificationTone = .error
                startPendingApprovalPolling(chave)
            } else {
                stopPendingApprovalPolling()
                maybeAutoOpenAssistanceDialog(status)
                let storedPw = uiState.password
                if status.hasPassword && !storedPw.isEmpty {
                    await attemptLogin(chave, storedPw)          // auto-login
                }
            }
        case .failure:
            guard uiState.chave == chave else { return }
            uiState.isStatusLoading = false
            uiState.statusErrored = true
        }
    }

    private func startPendingApprovalPolling(_ chave: String) {
        guard pendingApprovalPollTask == nil else { return }     // guarda de reentrância (isActive)
        pollGeneration += 1
        let myGeneration = pollGeneration
        pendingApprovalPollTask = Task { [weak self] in
            while true {
                // lê via self? fraco — NÃO retém self durante o sleep de 10s abaixo.
                guard let stillAwaiting = self?.uiState.isAwaitingApproval, stillAwaiting,
                      self?.uiState.chave == chave else { break }
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                guard let self, self.uiState.chave == chave, self.uiState.isAwaitingApproval else { break }
                await self.probeStatus(chave)
            }
            // só limpa se ainda for o poller mais recente (evita que um cleanup tardio de um poller
            // superseded apague o estado de um poller mais novo já iniciado por stopPendingApprovalPolling→start).
            if let self, self.pollGeneration == myGeneration { self.pendingApprovalPollTask = nil }
        }
    }

    private func stopPendingApprovalPolling() {
        pollGeneration += 1                                      // invalida qualquer cleanup tardio em voo
        pendingApprovalPollTask?.cancel()
        pendingApprovalPollTask = nil
    }

    private func resolvePrompt(_ status: AuthStatus) -> String {
        if status.authenticated { return "" }
        if status.hasPassword { return t("auth.enterPasswordPrompt", lang: languageCode) }
        return t("auth.createPasswordPrompt", lang: languageCode)
    }

    private func maybeAutoOpenAssistanceDialog(_ status: AuthStatus) {
        if status.pendingApproval { return }
        if uiState.dismissedAssistanceForChave == status.chave { return }
        if status.found && !status.hasPassword && !status.authenticated {
            uiState.dialogOpen = .passwordChange
        } else if !status.found {
            uiState.dialogOpen = .selfRegistration
            uiState.selfRegistrationFields.chave = status.chave
        }
    }

    // MARK: - login

    private func attemptLogin(_ chave: String, _ password: String) async {
        guard chave.count == 4, isPasswordVerificationInputValid(password) else { return }
        guard uiState.chave == chave else { return }              // já mudou antes de tentar — não mostra "verificando"
        uiState.notificationPrimary = t("status.passwordVerifying", lang: languageCode)
        uiState.notificationTone = .info
        switch await authRepository.login(chave, password) {
        case .success(let status):
            if status.authenticated { securePasswordStore.setPassword(chave, password) }   // credencial válida — persiste sempre
            guard uiState.chave == chave else { return }          // resposta tardia p/ chave abandonada — não pisa na UI atual
            uiState.authStatus = status
            uiState.prompt = resolvePrompt(status)
            if status.authenticated {
                onAuthenticationSucceeded(chave, status)
                activityLogger.logAuth("Signed in.", .info)
            } else {
                uiState.notificationPrimary = localizeApiMessage(status.message, lang: languageCode)
                uiState.notificationTone = .error
                activityLogger.logError("Sign-in failed.")
            }
        case .failure(let error):
            guard uiState.chave == chave else { return }
            if case .unauthorized = error {
                uiState.notificationPrimary = ""
                uiState.notificationSecondary = ""
                uiState.notificationTone = .none
            } else {
                uiState.notificationPrimary = t("status.apiCommunicationFailure", lang: languageCode)
                uiState.notificationTone = .error
            }
            activityLogger.logError("Sign-in failed.")
        }
    }

    private func onAuthenticationSucceeded(_ chave: String, _ status: AuthStatus) {
        uiState.notificationPrimary = t("status.authenticationCompleted", lang: languageCode)
        uiState.notificationTone = .teal
        // ensureEngineRunningIfEligible (gate D5) + loadUserProjects/catalog/locations → deferidos (slices próprios).
        Task {
            uiState.isHistoryLoading = true
            switch await authRepository.getHistory(chave) {
            case .success(let history):
                guard uiState.chave == chave else { return }      // chave mudou durante o load — descarta
                uiState.historyState = history
                uiState.transportEnabled = history.transportEnabled
                uiState.isHistoryLoading = false
                if uiState.selectedManualLocation == nil { uiState.selectedManualLocation = history.currentLocal }
            case .failure:
                guard uiState.chave == chave else { return }
                uiState.isHistoryLoading = false
            }
        }
        Task {
            let dismissed = await appPreferences.getFlag(nudgeFlag(chave))
            guard uiState.chave == chave else { return }
            uiState.showAutoActivitiesNudge = shouldShowAutoActivitiesNudge(
                authenticated: status.authenticated, autoEnabled: uiState.automaticActivitiesEnabled, dismissed: dismissed)
        }
        startCheckStream(chave)
    }

    // MARK: - autocadastro / senha

    func submitSelfRegistration() {
        let fields = uiState.selfRegistrationFields
        let chave = uiState.chave

        if fields.nome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            uiState.selfRegistrationFields.errorMessage = t("registrationDialog.fullNameRequired", lang: languageCode); return
        }
        let email = fields.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty && !email.contains("@") {
            uiState.selfRegistrationFields.errorMessage = t("registrationDialog.emailInvalid", lang: languageCode); return
        }
        if !isPasswordLengthValid(fields.password) {
            uiState.selfRegistrationFields.errorMessage = t("registrationDialog.passwordInvalid", lang: languageCode); return
        }
        if fields.password != fields.confirmPw {
            uiState.selfRegistrationFields.errorMessage = t("registrationDialog.confirmMismatch", lang: languageCode); return
        }
        let selectedProjectNames = fields.projectCatalog.filter { fields.selectedProjectIds.contains($0.id) }.map(\.name)
        if selectedProjectNames.isEmpty {
            uiState.selfRegistrationFields.errorMessage = t("projects.selectAtLeastOne", lang: languageCode); return
        }

        uiState.selfRegistrationFields.isBusy = true
        uiState.selfRegistrationFields.errorMessage = ""

        Task {
            let result = await authRepository.selfRegister(
                chave, fields.nome.trimmingCharacters(in: .whitespacesAndNewlines), selectedProjectNames,
                email.isEmpty ? nil : email, fields.password, fields.confirmPw)
            switch result {
            case .success(let status):
                securePasswordStore.setPassword(chave, fields.password)   // SEMPRE (auto-login pós-aprovação)
                if status.queueFull {
                    uiState.authStatus = status
                    uiState.prompt = ""
                    uiState.dialogOpen = nil
                    uiState.dismissedAssistanceForChave = chave
                    uiState.selfRegistrationFields = SelfRegistrationFields(chave: chave)
                    uiState.notificationPrimary = t("auth.registrationQueueFull", lang: languageCode)
                    uiState.notificationSecondary = ""
                    uiState.notificationTone = .error
                } else if status.pendingApproval {
                    uiState.authStatus = status
                    uiState.prompt = ""
                    uiState.dialogOpen = nil
                    uiState.dismissedAssistanceForChave = chave
                    uiState.selfRegistrationFields = SelfRegistrationFields(chave: chave)
                    uiState.notificationPrimary = t("auth.awaitingApproval", lang: languageCode)
                    uiState.notificationSecondary = ""
                    uiState.notificationTone = .error
                    startPendingApprovalPolling(chave)
                } else {
                    uiState.authStatus = status
                    uiState.prompt = resolvePrompt(status)
                    uiState.dialogOpen = nil
                    uiState.dismissedAssistanceForChave = chave
                    uiState.selfRegistrationFields = SelfRegistrationFields(chave: chave)
                    if status.authenticated { onAuthenticationSucceeded(chave, status) }
                }
            case .failure:
                uiState.selfRegistrationFields.isBusy = false
                uiState.selfRegistrationFields.errorMessage = t("registrationDialog.submitFailed", lang: languageCode)
            }
        }
    }

    func submitPasswordChange() {
        let fields = uiState.passwordChangeFields
        let chave = uiState.chave
        let hasExistingPassword = uiState.hasPassword

        if hasExistingPassword && !isPasswordLengthValid(fields.oldPw) {
            uiState.passwordChangeFields.errorMessage = t("passwordDialog.oldPasswordInvalid", lang: languageCode); return
        }
        if !isPasswordLengthValid(fields.newPw) {
            uiState.passwordChangeFields.errorMessage = t("passwordDialog.newPasswordInvalid", lang: languageCode); return
        }
        if fields.newPw != fields.confirmPw {
            uiState.passwordChangeFields.errorMessage = t("passwordDialog.confirmMismatch", lang: languageCode); return
        }

        uiState.passwordChangeFields.isBusy = true
        uiState.passwordChangeFields.errorMessage = ""

        Task {
            let result = hasExistingPassword
                ? await authRepository.changePassword(chave, fields.oldPw, fields.newPw)
                : await authRepository.registerPassword(chave, nil, fields.newPw)
            switch result {
            case .success(let status):
                securePasswordStore.setPassword(chave, fields.newPw)
                uiState.authStatus = status
                uiState.prompt = resolvePrompt(status)
                uiState.dialogOpen = nil
                uiState.dismissedAssistanceForChave = chave
                uiState.passwordChangeFields = PasswordChangeFields()
                if status.authenticated { onAuthenticationSucceeded(chave, status) }
            case .failure:
                uiState.passwordChangeFields.isBusy = false
                uiState.passwordChangeFields.errorMessage = t("passwordDialog.changeFailed", lang: languageCode)
            }
        }
    }

    // MARK: - foreground / expiry / delete

    func onForegroundResume() {
        if uiState.isAwaitingApproval {
            let chave = uiState.chave
            if chave.count == 4 { Task { await probeStatus(chave) } }
            return
        }
        if uiState.isAuthenticated {
            refreshCheckState()
            if uiState.automaticActivitiesEnabled {
                Task { await orchestrator.runOnce(.foreground) }
            }
        }
    }

    private func refreshCheckState() {
        let chave = uiState.chave
        Task {
            switch await checkRepository.getState(chave) {
            case .success(let state):
                uiState.historyState = state
                uiState.transportEnabled = state.transportEnabled
            case .failure(let error):
                if case .unauthorized = error { handleAuthExpiry() }
            }
        }
    }

    private func handleAuthExpiry() {
        stopCheckStream()
        if var status = uiState.authStatus { status.authenticated = false; uiState.authStatus = status }
        uiState.isSubmitting = false
        uiState.isProjectsLoading = false
        uiState.isHistoryLoading = false
        uiState.isLocationLoading = false
        uiState.notificationPrimary = ""
        uiState.notificationSecondary = ""
        uiState.notificationTone = .none
        uiState.userProjects = nil
        uiState.historyState = nil
        uiState.locationMatch = nil
        uiState.selectedManualLocation = nil
        uiState.showAutoActivitiesNudge = false
        // MANTÉM chave/senha (permite re-entrar).
    }

    /// LGPD art. 18 — wipe local só em sucesso do servidor; 409 mantém a sessão.
    func deleteAccount() {
        Task {
            switch await authRepository.deleteAccount() {
            case .success:
                securePasswordStore.clearAll()
                await appPreferences.clearAll()
                stopCheckStream()
                stopPendingApprovalPolling()
                // TODO(D6): offlineQueue.clear() — incluir a fila offline cifrada no wipe (spec §6).
                uiState = CheckUiState(isInitializing: false)
            case .failure(let error):
                let message = { if case .conflict = error { return t("settings.deleteAccountBlocked", lang: languageCode) }
                                return t("settings.deleteAccountFailed", lang: languageCode) }()
                uiState.notificationPrimary = message
                uiState.notificationTone = .error
            }
        }
    }

    // MARK: - dialogs / self-reg fields

    func dismissDialog() {
        if uiState.dialogOpen == .passwordChange || uiState.dialogOpen == .selfRegistration {
            uiState.dialogOpen = nil
            uiState.dismissedAssistanceForChave = uiState.chave
        } else {
            uiState.dialogOpen = nil
        }
    }

    func onRegChaveChanged(_ value: String) {
        let sanitized = sanitizeSettingsChave(value)
        uiState.chave = sanitized
        uiState.selfRegistrationFields.chave = sanitized
    }
    func onRegNomeChanged(_ value: String) { uiState.selfRegistrationFields.nome = value }
    func onRegEmailChanged(_ value: String) { uiState.selfRegistrationFields.email = autofillPetrobrasEmailDomain(value) }
    func onRegPasswordChanged(_ value: String) { uiState.selfRegistrationFields.password = value }
    func onRegConfirmPwChanged(_ value: String) { uiState.selfRegistrationFields.confirmPw = value }
    func onRegProjectToggled(_ id: Int) {
        var ids = uiState.selfRegistrationFields.selectedProjectIds
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        uiState.selfRegistrationFields.selectedProjectIds = ids
    }

    func loadProjectCatalogForRegistration() {
        if !uiState.selfRegistrationFields.projectCatalog.isEmpty { return }   // já carregado — evita re-fetch
        uiState.selfRegistrationFields.isLoadingProjects = true
        Task {
            if case .success(let projects) = await projectRepository.listProjects() {
                uiState.selfRegistrationFields.projectCatalog = projects
            }
            uiState.selfRegistrationFields.isLoadingProjects = false
        }
    }

    // MARK: - SSE

    private func startCheckStream(_ chave: String) {
        checkSseTask?.cancel()
        checkSseTask = Task { [weak self] in
            // stream obtido sem reter self além desta expressão — o loop não segura self entre eventos.
            guard let stream = self?.checkEventStream.events(chave: chave) else { return }
            for await _ in stream {
                guard let self else { return }
                self.refreshCheckState()
            }
        }
    }
    private func stopCheckStream() {
        checkSseTask?.cancel()
        checkSseTask = nil
    }

    private func nudgeFlag(_ chave: String) -> String { "auto_activities_prompt_dismissed_\(chave)" }
}

/// Nudge de primeira ativação — authenticated & !autoEnabled & !dismissed.
func shouldShowAutoActivitiesNudge(authenticated: Bool, autoEnabled: Bool, dismissed: Bool) -> Bool {
    authenticated && !autoEnabled && !dismissed
}
