import Foundation
import Observation

/// Máquina de estado do Check — autenticação + registro manual/projetos/localização. `@Observable @MainActor`;
/// jobs canceláveis (debounce 800ms, polling 10s, SSE). Ver specs de auth, decisão e UI.
@Observable
@MainActor
final class CheckViewModel {
    private(set) var uiState = CheckUiState()
    private(set) var languageCode = "pt"

    private let appPreferences: any AppPreferencesStore
    private let securePasswordStore: any SecurePasswordStore
    private let authRepository: any AuthRepository
    private let projectRepository: any ProjectRepository
    private let checkRepository: any CheckRepository
    private let captureLocationUseCase: any LocationCapturing
    private let offlineQueue: any OfflineCheckQueueing
    private let permissionsInspector: any PermissionsInspecting
    private let orchestrator: any OrchestratorRunning
    private let significantLocationMonitor: any SignificantLocationMonitoring
    private let checkEventStream: any CheckEventStreaming
    private let activityLogger: any ActivityLogging
    private let activityLog: ActivityLog?
    private let geofenceRegionManager: (any GeofenceRegionManaging)?
    private let clock: any Clock
    private let usesFixtureState: Bool

    private var passwordVerifyTask: Task<Void, Never>?
    private var chaveTask: Task<Void, Never>?
    private var pendingApprovalPollTask: Task<Void, Never>?
    private var pollGeneration = 0       // token: só a geração mais recente pode limpar pendingApprovalPollTask
    private var checkSseTask: Task<Void, Never>?
    private var settingsPersistenceTask: Task<Void, Never>?
    private var settingsReconciliationTask: Task<Void, Never>?
    private var projectMembershipSyncTask: Task<Void, Never>?
    private var pendingProjectMemberships: [String]?
    private var authoritativeUserProjects: UserProjects?
    private var projectMembershipSyncGeneration = 0
    private var projectMembershipLoadGeneration = 0
    private var activityLoadGeneration = 0
    // Sem `deinit`: `deinit` de uma classe `@MainActor` roda nonisolated (Swift 6) e não pode acessar estas
    // propriedades isoladas. Em vez disso, `startPendingApprovalPolling`/`startCheckStream` capturam `[weak self]`
    // — ao desalocar o VM, a próxima checagem acha `self` nil e o loop sai sozinho (sem retenção indefinida).

    init(appPreferences: any AppPreferencesStore, securePasswordStore: any SecurePasswordStore,
         authRepository: any AuthRepository, projectRepository: any ProjectRepository,
         checkRepository: any CheckRepository, captureLocationUseCase: any LocationCapturing,
         offlineQueue: any OfflineCheckQueueing, permissionsInspector: any PermissionsInspecting,
         orchestrator: any OrchestratorRunning,
         significantLocationMonitor: any SignificantLocationMonitoring,
         checkEventStream: any CheckEventStreaming, activityLogger: any ActivityLogging, clock: any Clock,
         activityLog: ActivityLog? = nil,
         geofenceRegionManager: (any GeofenceRegionManaging)? = nil,
         initialState: CheckUiState? = nil,
         initialLanguageCode: String? = nil) {
        self.appPreferences = appPreferences; self.securePasswordStore = securePasswordStore
        self.authRepository = authRepository; self.projectRepository = projectRepository
        self.checkRepository = checkRepository; self.captureLocationUseCase = captureLocationUseCase
        self.offlineQueue = offlineQueue; self.permissionsInspector = permissionsInspector
        self.orchestrator = orchestrator
        self.significantLocationMonitor = significantLocationMonitor
        self.checkEventStream = checkEventStream; self.activityLogger = activityLogger
        self.activityLog = activityLog; self.geofenceRegionManager = geofenceRegionManager; self.clock = clock
        self.usesFixtureState = initialState != nil
        if let initialLanguageCode { self.languageCode = resolveLanguageCode(initialLanguageCode) }
        if let initialState { self.uiState = initialState }
        else { Task { await restore() } }
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
        let previousChave = uiState.chave
        if previousChave.count == 4, previousChave != sanitized {
            Task { await orchestrator.invalidateAutomationContext() }
        }
        chaveTask?.cancel()                                      // aborta o fluxo de probe/login da chave anterior
        passwordVerifyTask?.cancel()
        stopPendingApprovalPolling()
        stopCheckStream()
        resetProjectMembershipSync()

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
        uiState.historyDialog = CheckHistoryDialogState()
        uiState.activityEntries = []
        uiState.activityNextOffset = 0
        uiState.activityCanLoadMore = false
        uiState.isActivitiesLoading = false
        uiState.userProjects = nil
        uiState.mainProjectCatalog = []
        uiState.availableLocations = []
        uiState.isProjectsLoading = false
        uiState.isProjectMembershipSyncing = false
        uiState.isLocationLoading = false
        uiState.selectedManualLocation = nil
        uiState.locationMatch = nil
        uiState.permissionsStatus = nil
        uiState.backgroundLocationConsentGranted = false
        applySettings(UserSettings(projects: [], activeProject: "", automaticActivitiesEnabled: false))

        chaveTask = Task {
            await significantLocationMonitor.stop()
            await geofenceRegionManager?.unregisterAll()
            await appPreferences.setChave(sanitized)
            if sanitized.count != 4 {
                _ = await authRepository.logout()
                return
            }
            let settings = await loadUserSettings(sanitized)
            guard uiState.chave == sanitized else { return }
            applySettings(settings)
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

    /// A UI Android autentica após o debounce; o botão explícito da tela técnica usa a mesma máquina de
    /// estado, mas permite ao ensaio físico começar de modo determinístico sem esperar o teclado.
    func submitLogin() {
        passwordVerifyTask?.cancel()
        let chave = uiState.chave
        let password = uiState.password
        Task { await attemptLogin(chave, password) }
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
        Task {
            let consent = !(await appPreferences.backgroundLocationConsentAt()).isEmpty
            guard uiState.chave == chave else { return }
            uiState.backgroundLocationConsentGranted = consent
        }
        Task { await loadUserProjects(chave: chave) }
        Task { await loadMainProjectCatalog(chave: chave) }
        Task { await refreshPermissionState(captureIfEligible: true) }
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
        if usesFixtureState { return }
        if uiState.isAwaitingApproval {
            let chave = uiState.chave
            if chave.count == 4 { Task { await probeStatus(chave) } }
            return
        }
        if uiState.isAuthenticated {
            refreshCheckState()
            let chave = uiState.chave
            Task {
                // A API é a fonte de verdade. Isso elimina memberships locais obsoletas antes de
                // avaliar qualquer check-in/out automático no retorno ao primeiro plano.
                await loadUserProjects(chave: chave)
                guard uiState.chave == chave, uiState.isAuthenticated,
                      !uiState.isProjectMembershipSyncing else { return }
                if uiState.automaticActivitiesEnabled,
                   let activeProject = uiState.userProjects?.activeProject,
                   !activeProject.isEmpty {
                    await refreshPermissionState(captureIfEligible: true)
                }
            }
        }
    }

    /// Ativação usada pela tela técnica e, depois, pela UI definitiva. Além do toggle, persiste os projetos
    /// do usuário porque o orquestrador lê exclusivamente `userSettingsJson` quando o app está suspenso.
    /// Retorna `false` sem ativar se a sessão/projeto não estiver configurado.
    func setAutomaticActivitiesEnabled(_ enabled: Bool) async -> Bool {
        let chave = uiState.chave
        guard chave.count == 4, uiState.isAuthenticated else { return false }
        let membershipLoadGeneration = projectMembershipLoadGeneration
        var refreshedProjects: UserProjects?

        if enabled {
            guard !uiState.isProjectsLoading, !uiState.isProjectMembershipSyncing else { return false }
            switch await projectRepository.getUserProjects() {
            case .success(let userProjects):
                guard uiState.chave == chave, uiState.isAuthenticated,
                      !uiState.isProjectMembershipSyncing,
                      membershipLoadGeneration == projectMembershipLoadGeneration else { return false }
                authoritativeUserProjects = userProjects
                uiState.userProjects = userProjects
                guard !userProjects.projects.isEmpty else {
                    let persistence = enqueueSettingsUpdate { settings in
                        settings.projects = []
                        settings.activeProject = ""
                        settings.automaticActivitiesEnabled = false
                    }
                    await persistence.value
                    guard uiState.chave == chave, uiState.isAuthenticated else { return false }
                    let persistedSettings = await loadUserSettings(chave)
                    guard uiState.chave == chave, uiState.isAuthenticated else { return false }
                    applySettings(persistedSettings)
                    await orchestrator.invalidateAutomationContext()
                    guard uiState.chave == chave, uiState.isAuthenticated else { return false }
                    uiState.availableLocations = []
                    uiState.selectedManualLocation = nil
                    showNoProjectNotification()
                    await reconcileAutomaticLocationServices()
                    return false
                }
                let activeProject = userProjects.projects.contains(userProjects.activeProject)
                    ? userProjects.activeProject
                    : userProjects.projects[0]
                let normalizedProjects = UserProjects(
                    projects: userProjects.projects,
                    activeProject: activeProject)
                refreshedProjects = normalizedProjects
                uiState.userProjects = normalizedProjects
                updateNoProjectNotification(for: normalizedProjects)
            case .failure(let error):
                if case .unauthorized = error { handleAuthExpiry() }
                return false
            }
        }

        let projectsForPersistence = refreshedProjects
        let persistence = enqueueSettingsUpdate { settings in
            if let projectsForPersistence {
                settings.projects = projectsForPersistence.projects
                settings.activeProject = projectsForPersistence.activeProject
            }
            settings.automaticActivitiesEnabled = enabled
        }
        await persistence.value
        guard uiState.chave == chave, uiState.isAuthenticated else { return false }

        var stableProjects: UserProjects?
        if enabled {
            guard await waitForProjectMembershipStability(chave: chave),
                  let currentProjects = uiState.userProjects else { return false }
            stableProjects = currentProjects

            // Se uma checkbox mudou durante a persistência acima, restaura nas preferências o estado
            // final confirmado pelo worker antes de permitir que o orquestrador execute.
            let correction = enqueueSettingsUpdate { settings in
                settings.projects = currentProjects.projects
                settings.activeProject = currentProjects.activeProject
                if currentProjects.projects.isEmpty || currentProjects.activeProject.isEmpty {
                    settings.automaticActivitiesEnabled = false
                }
            }
            await correction.value
            guard await waitForProjectMembershipStability(chave: chave) else { return false }
            guard uiState.userProjects == currentProjects else {
                return await setAutomaticActivitiesEnabled(true)
            }
        }

        let persistedSettings = await loadUserSettings(chave)
        guard uiState.chave == chave, uiState.isAuthenticated else { return false }
        applySettings(persistedSettings)
        if !enabled {
            // Somente depois de OFF estar durável: invalida qualquer captura automática que atravessou await.
            await orchestrator.invalidateAutomationContext()
            guard uiState.chave == chave, uiState.isAuthenticated else { return false }
        }
        let hasStableActiveProject = stableProjects.map {
            !$0.projects.isEmpty && !$0.activeProject.isEmpty
        } ?? false
        if enabled && !hasStableActiveProject {
            uiState.availableLocations = []
            uiState.selectedManualLocation = nil
            showNoProjectNotification()
            await reconcileAutomaticLocationServices()
            return false
        }
        uiState.showAutoActivitiesNudge = enabled ? false : uiState.showAutoActivitiesNudge
        activityLogger.logSystem(
            enabled ? "Automatic activities enabled by user." : "Automatic activities disabled by user.",
            .info
        )
        if enabled {
            guard await waitForProjectMembershipStability(chave: chave) else { return false }
            guard uiState.userProjects == stableProjects else {
                return await setAutomaticActivitiesEnabled(true)
            }
        }
        await reconcileAutomaticLocationServices(forceGeofenceRefresh: enabled)
        // No OFF, permite também ao orquestrador cancelar notificações futuras da Pausa Programada.
        await orchestrator.runOnce(.foreground)
        return true
    }

    private func refreshCheckState() {
        let chave = uiState.chave
        Task {
            switch await checkRepository.getState(chave) {
            case .success(let state):
                guard uiState.chave == chave, uiState.isAuthenticated else { return }
                uiState.historyState = state
                uiState.transportEnabled = state.transportEnabled
                if uiState.selectedManualLocation == nil { uiState.selectedManualLocation = state.currentLocal }
                await orchestrator.confirmedState(chave: chave, newState: state)
            case .failure(let error):
                guard uiState.chave == chave else { return }
                if case .unauthorized = error { handleAuthExpiry() }
            }
        }
    }

    private func handleAuthExpiry() {
        stopCheckStream()
        resetProjectMembershipSync()
        let expiredChave = uiState.chave
        Task {
            guard uiState.chave == expiredChave, !uiState.isAuthenticated else { return }
            await orchestrator.invalidateAutomationContext()
            guard uiState.chave == expiredChave, !uiState.isAuthenticated else { return }
            await significantLocationMonitor.stop()
            await geofenceRegionManager?.unregisterAll()
        }
        if var status = uiState.authStatus { status.authenticated = false; uiState.authStatus = status }
        uiState.isSubmitting = false
        uiState.isProjectsLoading = false
        uiState.isProjectMembershipSyncing = false
        uiState.isHistoryLoading = false
        uiState.isLocationLoading = false
        uiState.notificationPrimary = ""
        uiState.notificationSecondary = ""
        uiState.notificationTone = .none
        uiState.userProjects = nil
        uiState.mainProjectCatalog = []
        uiState.availableLocations = []
        uiState.historyState = nil
        uiState.locationMatch = nil
        uiState.selectedManualLocation = nil
        uiState.showAutoActivitiesNudge = false
        // MANTÉM chave/senha (permite re-entrar).
    }

    // MARK: - authenticated main screen

    func onActionSelected(_ action: CheckAction) { uiState.selectedAction = action }

    func onInformeSelected(_ informe: UiInformeType) { uiState.selectedInforme = informe }

    func onManualLocationSelected(_ location: String) { uiState.selectedManualLocation = location }

    func onRefreshLocation() {
        captureLocation()
        Task { await orchestrator.runOnce(.foreground) }
    }

    func captureLocation() {
        guard uiState.automaticActivitiesEnabled, uiState.locationPermissionSufficient,
              !uiState.isLocationLoading else { return }
        uiState.isLocationLoading = true
        let chave = uiState.chave
        let threshold = uiState.locationMatch?.accuracyThresholdMeters ?? 30
        Task {
            let result = await captureLocationUseCase(threshold)
            guard uiState.chave == chave, uiState.isAuthenticated else { return }
            switch result {
            case .matched(let match):
                uiState.locationMatch = match
                uiState.isLocationLoading = false
                if match.status != .accuracyTooLow { uiState.selectedManualLocation = nil }
            case .noPermission:
                uiState.locationPermissionSufficient = false
                uiState.isLocationLoading = false
            case .timeout, .networkError:
                uiState.isLocationLoading = false
            }
        }
    }

    private func refreshPermissionState(captureIfEligible: Bool) async {
        let status = await permissionsInspector.inspect()
        guard uiState.isAuthenticated else { return }
        uiState.permissionsStatus = status
        uiState.locationPermissionSufficient = status.preciseLocationGranted
        if !status.preciseLocationGranted {
            uiState.locationMatch = nil
            uiState.isLocationLoading = false
        } else if captureIfEligible && uiState.automaticActivitiesEnabled {
            captureLocation()
        }
    }

    private func loadAvailableLocations(chave: String) async {
        switch await checkRepository.getLocations() {
        case .success(let options):
            guard uiState.chave == chave, uiState.isAuthenticated else { return }
            uiState.availableLocations = options.items
        case .failure(let error):
            guard uiState.chave == chave else { return }
            if case .unauthorized = error { handleAuthExpiry() }
        }
    }

    private func loadUserProjects(chave: String) async {
        // Uma seleção otimista em andamento já será reconciliada pelo worker de PUT. Um GET paralelo
        // poderia repor temporariamente o estado antigo do servidor sobre as checkboxes recém-alteradas.
        guard projectMembershipSyncTask == nil else { return }
        projectMembershipLoadGeneration += 1
        let loadGeneration = projectMembershipLoadGeneration
        uiState.isProjectsLoading = true
        switch await projectRepository.getUserProjects() {
        case .success(let projects):
            guard uiState.chave == chave, uiState.isAuthenticated,
                  loadGeneration == projectMembershipLoadGeneration else { return }
            let previousActiveProject = (authoritativeUserProjects ?? uiState.userProjects)?.activeProject
            authoritativeUserProjects = projects
            uiState.userProjects = projects
            updateNoProjectNotification(for: projects)
            await persistUserProjects(chave: chave, projects: projects.projects, activeProject: projects.activeProject)
            guard uiState.chave == chave, uiState.isAuthenticated,
                  loadGeneration == projectMembershipLoadGeneration else { return }
            if let previousActiveProject, previousActiveProject != projects.activeProject {
                await orchestrator.invalidateAutomationContext()
                guard uiState.chave == chave, uiState.isAuthenticated,
                      loadGeneration == projectMembershipLoadGeneration else { return }
            }
            if projects.projects.isEmpty {
                uiState.availableLocations = []
                uiState.selectedManualLocation = nil
            } else {
                await loadAvailableLocations(chave: chave)
            }
            await reconcileAutomaticLocationServices(forceGeofenceRefresh: true)
            await orchestrator.runOnce(.foreground)
            guard uiState.chave == chave, uiState.isAuthenticated,
                  loadGeneration == projectMembershipLoadGeneration else { return }
            uiState.isProjectsLoading = false
        case .failure(let error):
            guard uiState.chave == chave, loadGeneration == projectMembershipLoadGeneration else { return }
            if case .unauthorized = error { handleAuthExpiry() }
            else {
                uiState.isProjectsLoading = false
                uiState.notificationPrimary = t("projects.userProjectsLoadFailed", lang: languageCode)
                uiState.notificationSecondary = ""
                uiState.notificationTone = .error
            }
        }
    }

    private func loadMainProjectCatalog(chave: String) async {
        switch await projectRepository.listProjects() {
        case .success(let catalog):
            guard uiState.chave == chave, uiState.isAuthenticated else { return }
            uiState.mainProjectCatalog = catalog
        case .failure(let error):
            guard uiState.chave == chave else { return }
            if case .unauthorized = error { handleAuthExpiry() }
        }
    }

    func onProjectMembershipToggled(_ projectName: String) {
        guard uiState.isAuthenticated, let currentState = uiState.userProjects else { return }
        projectMembershipLoadGeneration += 1
        uiState.isProjectsLoading = false

        let current = currentState.projects
        let next = current.contains(projectName)
            ? current.filter { $0 != projectName }
            : current + [projectName]
        let optimisticActiveProject = next.contains(currentState.activeProject)
            ? currentState.activeProject
            : next.first ?? ""

        if authoritativeUserProjects == nil {
            authoritativeUserProjects = currentState
        }
        pendingProjectMemberships = next
        uiState.userProjects = UserProjects(projects: next, activeProject: optimisticActiveProject)
        uiState.isProjectMembershipSyncing = true

        let chave = uiState.chave
        guard projectMembershipSyncTask == nil else { return }
        let syncGeneration = projectMembershipSyncGeneration
        projectMembershipSyncTask = Task { [weak self] in
            await self?.synchronizeProjectMemberships(chave: chave, generation: syncGeneration)
        }
    }

    private func synchronizeProjectMemberships(chave: String, generation: Int) async {
        var needsReconciliation = false
        var needsAccuracyRetryInvalidation = false

        while !Task.isCancelled {
            guard uiState.chave == chave, uiState.isAuthenticated,
                  generation == projectMembershipSyncGeneration,
                  let requestedProjects = pendingProjectMemberships else { break }
            pendingProjectMemberships = nil

            switch await projectRepository.updateUserProjects(requestedProjects) {
            case .success(let projects):
                guard !Task.isCancelled, uiState.chave == chave, uiState.isAuthenticated,
                      generation == projectMembershipSyncGeneration else { return }
                let previousActiveProject = authoritativeUserProjects?.activeProject ?? ""
                // A resposta do servidor é a fonte autoritativa. Se houve outro toque enquanto o PUT
                // estava em andamento, preservamos apenas a seleção otimista mais nova até o próximo PUT.
                authoritativeUserProjects = projects
                if previousActiveProject != projects.activeProject {
                    needsAccuracyRetryInvalidation = true
                }
                needsReconciliation = true
                uiState.selectedManualLocation = nil
                if pendingProjectMemberships == nil {
                    uiState.userProjects = projects
                    if uiState.notificationPrimary == t("projects.updateFailed", lang: languageCode) {
                        uiState.notificationPrimary = ""
                        uiState.notificationSecondary = ""
                        uiState.notificationTone = .none
                    }
                }

            case .failure(let error):
                guard !Task.isCancelled, uiState.chave == chave,
                      generation == projectMembershipSyncGeneration else { return }
                if case .unauthorized = error {
                    handleAuthExpiry()
                    return
                }
                uiState.notificationPrimary = t("projects.updateFailed", lang: languageCode)
                uiState.notificationTone = .error
                if pendingProjectMemberships == nil, let authoritativeUserProjects {
                    uiState.userProjects = authoritativeUserProjects
                    needsReconciliation = true
                }
            }

            // Um toque ocorrido durante o request já contém a seleção completa desejada. Envia-o antes
            // dos efeitos derivados, mantendo PUTs estritamente ordenados e sem resposta antiga pisar nele.
            if pendingProjectMemberships != nil { continue }

            if needsReconciliation, let authoritativeUserProjects {
                updateNoProjectNotification(for: authoritativeUserProjects)
                await persistUserProjects(
                    chave: chave,
                    projects: authoritativeUserProjects.projects,
                    activeProject: authoritativeUserProjects.activeProject)
                guard !Task.isCancelled, uiState.chave == chave, uiState.isAuthenticated,
                      generation == projectMembershipSyncGeneration else { return }
                if pendingProjectMemberships != nil { continue }
                if needsAccuracyRetryInvalidation {
                    // Só uma mudança real de contexto ativo invalida o prazo; GET/PUT idêntico não reinicia
                    // um episódio válido nem repete sua notificação.
                    await orchestrator.invalidateAutomationContext()
                    guard !Task.isCancelled, uiState.chave == chave, uiState.isAuthenticated,
                          generation == projectMembershipSyncGeneration else { return }
                    if pendingProjectMemberships != nil { continue }
                    needsAccuracyRetryInvalidation = false
                }

                if authoritativeUserProjects.projects.isEmpty {
                    uiState.availableLocations = []
                } else {
                    await loadAvailableLocations(chave: chave)
                }
                guard !Task.isCancelled, uiState.chave == chave, uiState.isAuthenticated,
                      generation == projectMembershipSyncGeneration else { return }
                if pendingProjectMemberships != nil { continue }

                await reconcileAutomaticLocationServices(forceGeofenceRefresh: true)
                guard !Task.isCancelled, uiState.chave == chave, uiState.isAuthenticated,
                      generation == projectMembershipSyncGeneration else { return }
                if pendingProjectMemberships != nil { continue }

                await orchestrator.runOnce(.foreground)
                guard !Task.isCancelled, uiState.chave == chave, uiState.isAuthenticated,
                      generation == projectMembershipSyncGeneration else { return }
                if pendingProjectMemberships != nil { continue }

                needsReconciliation = false
            }
        }

        guard generation == projectMembershipSyncGeneration else { return }
        projectMembershipSyncTask = nil
        uiState.isProjectMembershipSyncing = false

        // Um novo toque pode chegar na última suspensão dos efeitos derivados. Não o deixa sem worker.
        if pendingProjectMemberships != nil {
            onProjectMembershipSyncNeeded(chave: chave)
        }
    }

    private func onProjectMembershipSyncNeeded(chave: String) {
        guard projectMembershipSyncTask == nil, pendingProjectMemberships != nil else { return }
        uiState.isProjectMembershipSyncing = true
        let syncGeneration = projectMembershipSyncGeneration
        projectMembershipSyncTask = Task { [weak self] in
            await self?.synchronizeProjectMemberships(chave: chave, generation: syncGeneration)
        }
    }

    private func resetProjectMembershipSync() {
        projectMembershipSyncGeneration += 1
        projectMembershipLoadGeneration += 1
        projectMembershipSyncTask?.cancel()
        projectMembershipSyncTask = nil
        pendingProjectMemberships = nil
        authoritativeUserProjects = nil
        uiState.isProjectMembershipSyncing = false
    }

    private func waitForProjectMembershipStability(chave: String) async -> Bool {
        while uiState.chave == chave, uiState.isAuthenticated {
            if let syncTask = projectMembershipSyncTask {
                await syncTask.value
                continue
            }
            if uiState.isProjectsLoading {
                try? await Task.sleep(for: .milliseconds(10))
                continue
            }
            return true
        }
        return false
    }

    private func persistUserProjects(chave: String, projects: [String], activeProject: String) async {
        guard chave == uiState.chave, chave.count == 4 else { return }
        let persistence = enqueueSettingsUpdate { settings in
            settings.projects = projects
            settings.activeProject = activeProject
        }
        await persistence.value
    }

    private func showNoProjectNotification() {
        uiState.notificationPrimary = t("projects.noActiveProject", lang: languageCode)
        uiState.notificationSecondary = ""
        uiState.notificationTone = .error
    }

    private func updateNoProjectNotification(for projects: UserProjects) {
        if projects.projects.isEmpty {
            showNoProjectNotification()
            return
        }

        let noProjectMessages = Set(supportedLanguages.map {
            t("projects.noActiveProject", lang: $0.code)
        })
        if noProjectMessages.contains(uiState.notificationPrimary) {
            uiState.notificationPrimary = ""
            uiState.notificationSecondary = ""
            uiState.notificationTone = .none
        }
    }

    func onSubmit() {
        let state = uiState
        guard state.canSubmit else { return }
        guard let project = state.userProjects?.activeProject, !project.isEmpty else {
            showNoProjectNotification()
            return
        }
        guard !state.automaticActivitiesEnabled || state.isAccuracyTooLow else {
            uiState.notificationPrimary = t("registration.disableAutomaticActivitiesForManualSubmit", lang: languageCode)
            uiState.notificationTone = .error
            return
        }

        let location: String?
        if state.requiresManualLocation {
            if let selected = state.selectedManualLocation {
                location = selected
            } else if state.selectedAction == .checkOut {
                location = "Desconhecido"
            } else {
                uiState.notificationPrimary = t("location.selectManualLocation", lang: languageCode)
                uiState.notificationTone = .error
                return
            }
        } else {
            location = state.locationMatch?.resolvedLocal
        }

        let informe: InformeType = state.selectedInforme == .normal ? .normal : .retroativo
        let eventTime = clock.now()
        let clientEventId = UUID().uuidString
        uiState.isSubmitting = true
        Task {
            switch await checkRepository.submit(
                chave: state.chave,
                projeto: project,
                action: state.selectedAction,
                local: location,
                informe: informe,
                eventTime: eventTime,
                clientEventId: clientEventId) {
            case .success(let newState):
                guard uiState.chave == state.chave, uiState.isAuthenticated else { return }
                await orchestrator.acceptedCheck(
                    chave: state.chave,
                    project: project,
                    action: state.selectedAction,
                    newState: newState)
                guard uiState.chave == state.chave, uiState.isAuthenticated else { return }
                uiState.historyState = newState
                uiState.isSubmitting = false
                uiState.notificationPrimary = t(
                    state.selectedAction == .checkIn ? "status.checkinCompleted" : "status.checkoutCompleted",
                    lang: languageCode)
                uiState.notificationTone = .success
                uiState.selectedManualLocation = newState.currentLocal
                logManual(action: state.selectedAction, location: location, success: true)
                refreshCheckState()
            case .failure(let error):
                if case .unauthorized = error {
                    guard uiState.chave == state.chave else { return }
                    handleAuthExpiry()
                    activityLogger.logError("Session expired — sign in again.")
                } else if case .network = error {
                    await offlineQueue.enqueue(.decided(PendingCheckEvent.Decided(
                        chave: state.chave,
                        projeto: project,
                        capturedAtEpochMs: Int64((eventTime.timeIntervalSince1970 * 1000).rounded()),
                        clientEventId: clientEventId,
                        action: state.selectedAction == .checkOut ? "checkout" : "checkin",
                        local: location,
                        informe: informe == .retroativo ? "retroativo" : "normal")))
                    guard uiState.chave == state.chave else { return }
                    await orchestrator.invalidateAccuracyRetry()
                    guard uiState.chave == state.chave else { return }
                    uiState.isSubmitting = false
                    uiState.notificationPrimary = t("status.savedOffline", lang: languageCode)
                    uiState.notificationTone = .success
                    activityLogger.logQueuedOffline(
                        .user, state.selectedAction == .checkIn ? .checkIn : .checkOut, location)
                } else if case .conflict = error {
                    // Um 409 pode significar que a membership foi removida em outro cliente. Revalida
                    // antes de escolher a mensagem, pois nem todo conflito do endpoint é "sem projeto".
                    await loadUserProjects(chave: state.chave)
                    guard uiState.chave == state.chave, uiState.isAuthenticated else { return }
                    uiState.isSubmitting = false
                    if uiState.userProjects?.projects.isEmpty == true {
                        showNoProjectNotification()
                    } else {
                        uiState.notificationPrimary = t("status.submitFailed", lang: languageCode)
                        uiState.notificationSecondary = ""
                        uiState.notificationTone = .error
                    }
                    logManual(action: state.selectedAction, location: location, success: false)
                } else {
                    guard uiState.chave == state.chave else { return }
                    let detail: String? = if case .http(_, let message) = error { message } else { nil }
                    uiState.isSubmitting = false
                    uiState.notificationPrimary = detail.map { localizeApiMessage($0, lang: languageCode) }
                        ?? t("status.submitFailed", lang: languageCode)
                    uiState.notificationTone = .error
                    logManual(action: state.selectedAction, location: location, success: false)
                }
            }
        }
    }

    private func logManual(action: CheckAction, location: String?, success: Bool) {
        if action == .checkIn { activityLogger.logCheckIn(.user, location, success: success) }
        else { activityLogger.logCheckOut(.user, location, success: success) }
    }

    /// LGPD art. 18 — wipe local só em sucesso do servidor; 409 mantém a sessão.
    func deleteAccount() {
        Task {
            switch await authRepository.deleteAccount() {
            case .success:
                // Cancela também as transições locais da Pausa Programada antes de apagar o mapa
                // de configurações que permite ao orquestrador encontrá-las.
                _ = await setAutomaticActivitiesEnabled(false)
                await orchestrator.invalidateAutomationContext()
                await significantLocationMonitor.stop()
                await geofenceRegionManager?.unregisterAll()
                securePasswordStore.clearAll()
                await appPreferences.clearAll()
                await offlineQueue.clear()
                stopCheckStream()
                stopPendingApprovalPolling()
                resetProjectMembershipSync()
                uiState = CheckUiState(isInitializing: false)
            case .failure(let error):
                let message = { if case .conflict = error { return t("settings.deleteAccountBlocked", lang: languageCode) }
                                return t("settings.deleteAccountFailed", lang: languageCode) }()
                uiState.notificationPrimary = message
                uiState.notificationTone = .error
            }
        }
    }

    /// LGPD art. 18 — equivalente ao `PrivacyViewModel.deleteLocalData` do Kotlin. Para o motor antes
    /// de apagar credenciais, preferências, fila GPS pendente, logs locais e sessão. Não toca nos dados
    /// já enviados ao servidor; essa solicitação continua sendo feita pelo canal de privacidade.
    func deleteLocalData() async {
        if uiState.isAuthenticated { _ = await setAutomaticActivitiesEnabled(false) }
        await orchestrator.invalidateAutomationContext()
        await significantLocationMonitor.stop()
        await geofenceRegionManager?.unregisterAll()
        _ = await authRepository.logout()
        activityLog?.clear()
        await offlineQueue.clear()
        securePasswordStore.clearAll()
        await appPreferences.clearAll()
        EvaluationLog.shared.reset()
        stopCheckStream()
        stopPendingApprovalPolling()
        passwordVerifyTask?.cancel()
        chaveTask?.cancel()
        settingsPersistenceTask?.cancel()
        resetProjectMembershipSync()
        uiState = CheckUiState(isInitializing: false)
        languageCode = "pt"
    }

    // MARK: - dialogs / self-reg fields

    func openSettings() { uiState.dialogOpen = .settings }

    func selectLanguage(_ code: String) {
        let resolved = resolveLanguageCode(code)
        guard resolved != languageCode else { return }
        languageCode = resolved
        if let status = uiState.authStatus { uiState.prompt = resolvePrompt(status) }
        Task { await appPreferences.setLanguage(resolved) }
    }

    func openAutoActivitiesDialog() {
        uiState.dialogOpen = .autoActivities
        uiState.showAutoActivitiesNudge = false
        Task { await refreshPermissionState(captureIfEligible: false) }
    }

    func dismissAutoActivitiesNudge() {
        let chave = uiState.chave
        uiState.showAutoActivitiesNudge = false
        Task { await appPreferences.setFlag(nudgeFlag(chave), true) }
    }

    func toggleAutomaticActivities(_ enabled: Bool) {
        Task {
            let changed = await setAutomaticActivitiesEnabled(enabled)
            guard changed else {
                if uiState.userProjects?.projects.isEmpty == true {
                    showNoProjectNotification()
                } else {
                    uiState.notificationPrimary = t("autoActivities.enableFailed", lang: languageCode)
                    uiState.notificationSecondary = ""
                    uiState.notificationTone = .error
                }
                return
            }
            await refreshPermissionState(captureIfEligible: enabled)
        }
    }

    func recordBackgroundLocationConsent() {
        uiState.backgroundLocationConsentGranted = true
        Task {
            await appPreferences.setBackgroundLocationConsentAt(ISOInstant.string(clock.now()))
            activityLogger.logSystem("Background location consent granted by user.", .info)
            await reconcileAutomaticLocationServices()
        }
    }

    func finishPermissionReview() {
        if usesFixtureState { return }
        Task {
            await refreshPermissionState(captureIfEligible: true)
            guard let status = uiState.permissionsStatus else { return }
            if uiState.automaticActivitiesEnabled && !status.ladder.minimumToStartGranted {
                _ = await setAutomaticActivitiesEnabled(false)
                uiState.notificationPrimary = t("autoActivities.insufficientPermissions", lang: languageCode)
                uiState.notificationTone = .error
            } else {
                await reconcileAutomaticLocationServices()
            }
        }
    }

    /// Fonte única do ciclo dos gatilhos nativos. O fluxo normal agora arma as geofences depois do login,
    /// ao habilitar a automação, após mudanças de projeto/permissão e a cada restauração em foreground.
    /// Quando qualquer gate deixa de ser válido, ambos os serviços são removidos para evitar regiões
    /// obsoletas de outra conta/projeto.
    private func reconcileAutomaticLocationServices(forceGeofenceRefresh: Bool = false) async {
        let chave = uiState.chave
        let persistedSettings = chave.count == 4
            ? await loadUserSettings(chave)
            : UserSettings(projects: [], activeProject: "", automaticActivitiesEnabled: false)
        guard uiState.chave == chave else { return }
        let activeProject = uiState.userProjects?.activeProject ?? persistedSettings.activeProject
        guard chave.count == 4, uiState.isAuthenticated, uiState.automaticActivitiesEnabled,
              !activeProject.isEmpty else {
            await significantLocationMonitor.stop()
            await geofenceRegionManager?.unregisterAll()
            return
        }

        let storedConsent = !(await appPreferences.backgroundLocationConsentAt()).isEmpty
        let consentGranted = uiState.backgroundLocationConsentGranted || storedConsent
        let permissions = await permissionsInspector.inspect()
        guard uiState.chave == chave, uiState.isAuthenticated else { return }
        uiState.permissionsStatus = permissions
        uiState.locationPermissionSufficient = permissions.preciseLocationGranted

        guard consentGranted, permissions.preciseLocationGranted else {
            await significantLocationMonitor.stop()
            await geofenceRegionManager?.unregisterAll()
            return
        }

        await significantLocationMonitor.start()
        let currentLocal = uiState.historyState?.currentLocal
        await geofenceRegionManager?.register(
            chave: chave,
            hints: GeofencePriorityHints(currentLocalName: currentLocal),
            forceRefresh: forceGeofenceRefresh)
    }

    func openScheduledPauseDialog() { uiState.dialogOpen = .scheduledPause }

    func openNotificationsDialog() { uiState.dialogOpen = .notifications }

    // Snapshot-at-open, newest-first, paginado em blocos de 30 — paridade com o Android.
    func openActivitiesDialog() {
        activityLoadGeneration += 1
        let generation = activityLoadGeneration
        uiState.dialogOpen = .activities
        uiState.activityEntries = []
        uiState.activityNextOffset = 0
        uiState.activityCanLoadMore = false
        uiState.isActivitiesLoading = true
        guard let activityLog else {
            uiState.isActivitiesLoading = false
            return
        }
        Task {
            let page = await Task.detached(priority: .utility) {
                (try? activityLog.page(offset: 0, limit: ActivityLog.pageSize)) ?? []
            }.value
            guard generation == activityLoadGeneration, uiState.dialogOpen == .activities else { return }
            uiState.activityEntries = page
            uiState.activityNextOffset = page.count
            uiState.activityCanLoadMore = page.count == ActivityLog.pageSize
            uiState.isActivitiesLoading = false
        }
    }

    func loadMoreActivities() {
        guard !uiState.isActivitiesLoading, uiState.activityCanLoadMore, let activityLog else { return }
        let generation = activityLoadGeneration
        let offset = uiState.activityNextOffset
        uiState.isActivitiesLoading = true
        Task {
            let page = await Task.detached(priority: .utility) {
                (try? activityLog.page(offset: offset, limit: ActivityLog.pageSize)) ?? []
            }.value
            guard generation == activityLoadGeneration, uiState.dialogOpen == .activities else { return }
            uiState.activityEntries.append(contentsOf: page)
            uiState.activityNextOffset += page.count
            uiState.activityCanLoadMore = page.count == ActivityLog.pageSize
            uiState.isActivitiesLoading = false
        }
    }

    func clearActivities() {
        activityLoadGeneration += 1
        let generation = activityLoadGeneration
        uiState.isActivitiesLoading = true
        guard let activityLog else {
            uiState.activityEntries = []
            uiState.activityNextOffset = 0
            uiState.activityCanLoadMore = false
            uiState.isActivitiesLoading = false
            return
        }
        Task {
            await Task.detached(priority: .utility) { activityLog.clear() }.value
            guard generation == activityLoadGeneration else { return }
            uiState.activityEntries = []
            uiState.activityNextOffset = 0
            uiState.activityCanLoadMore = false
            uiState.isActivitiesLoading = false
        }
    }

    func onScheduledPauseSettingChanged(
        enabled: Bool, from: String, to: String, suspendSat: Bool, suspendSun: Bool
    ) {
        uiState.scheduledPauseEnabled = enabled
        uiState.scheduledPauseFrom = from
        uiState.scheduledPauseTo = to
        uiState.suspendSaturdays = suspendSat
        uiState.suspendSundays = suspendSun
        let persisted = enqueueSettingsUpdate { settings in
                settings.scheduledPauseEnabled = enabled
                settings.scheduledPauseFrom = from
                settings.scheduledPauseTo = to
                settings.suspendSaturdays = suspendSat
                settings.suspendSundays = suspendSun
        }
        reconcileSettingsAfterPersistence(persisted, scheduledPauseChanged: true)
    }

    func onNotificationSettingsChanged(activities: Bool, scheduledPause: Bool, accident: Bool) {
        uiState.notifyActivities = activities
        uiState.notifyScheduledPause = scheduledPause
        uiState.notifyAccident = accident
        let persisted = enqueueSettingsUpdate { settings in
                settings.notifyActivities = activities
                settings.notifyScheduledPause = scheduledPause
                settings.notifyAccident = accident
        }
        reconcileSettingsAfterPersistence(persisted)
    }

    func openHistory(_ action: CheckAction) {
        uiState.dialogOpen = .history
        uiState.historyDialog = CheckHistoryDialogState(action: action, isLoading: true)
        loadHistoryDialog()
    }

    func retryHistoryDialog() {
        uiState.historyDialog.isLoading = true
        uiState.historyDialog.isError = false
        loadHistoryDialog()
    }

    private func loadHistoryDialog() {
        let chave = uiState.chave
        Task {
            switch await checkRepository.getHistory(chave) {
            case .success(let entries):
                guard uiState.chave == chave, uiState.dialogOpen == .history else { return }
                uiState.historyDialog.entries = entries.filter { $0.action == uiState.historyDialog.action }
                uiState.historyDialog.isLoading = false
                uiState.historyDialog.isError = false
            case .failure(let error):
                guard uiState.chave == chave, uiState.dialogOpen == .history else { return }
                if case .unauthorized = error { handleAuthExpiry(); return }
                uiState.historyDialog.isLoading = false
                uiState.historyDialog.isError = true
            }
        }
    }

    private func updatePersistedSettings(chave: String, _ update: (inout UserSettings) -> Void) async {
        guard chave.count == 4 else { return }
        let raw = await appPreferences.userSettingsJson()
        var map = (try? JSONCoding.decoder.decode([String: UserSettings].self, from: Data(raw.utf8))) ?? [:]
        var settings = resolvePersistedUserSettings(map, chave)
        update(&settings)
        map = withPersistedUserSettings(map, chave, settings)
        guard let data = try? JSONCoding.encoder.encode(map),
              let json = String(data: data, encoding: .utf8) else { return }
        await appPreferences.setUserSettingsJson(json)
    }

    @discardableResult
    private func enqueueSettingsUpdate(
        _ update: @escaping (inout UserSettings) -> Void
    ) -> Task<Void, Never> {
        let chave = uiState.chave
        let previous = settingsPersistenceTask
        let task = Task {
            await previous?.value
            await updatePersistedSettings(chave: chave, update)
        }
        settingsPersistenceTask = task
        return task
    }

    private func reconcileSettingsAfterPersistence(
        _ persistence: Task<Void, Never>,
        scheduledPauseChanged: Bool = false
    ) {
        // DatePicker pode emitir várias alterações rápidas. Só a configuração mais recente deve
        // reavaliar a pausa, e somente depois de estar disponível ao orquestrador nas preferências.
        settingsReconciliationTask?.cancel()
        settingsReconciliationTask = Task {
            await persistence.value
            guard !Task.isCancelled else { return }
            if scheduledPauseChanged {
                await orchestrator.scheduledPauseSettingsDidChange()
            } else {
                await orchestrator.runOnce(.foreground)
            }
        }
    }

    func openPasswordChangeDialog() { uiState.dialogOpen = .passwordChange }

    func openSelfRegistrationDialog() {
        uiState.dialogOpen = .selfRegistration
        uiState.dismissedAssistanceForChave = ""
        uiState.selfRegistrationFields.chave = uiState.chave
    }

    func onPasswordChangeOldPwChanged(_ value: String) {
        uiState.passwordChangeFields.oldPw = value
    }

    func onPasswordChangeNewPwChanged(_ value: String) {
        uiState.passwordChangeFields.newPw = value
    }

    func onPasswordChangeConfirmPwChanged(_ value: String) {
        uiState.passwordChangeFields.confirmPw = value
    }

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
