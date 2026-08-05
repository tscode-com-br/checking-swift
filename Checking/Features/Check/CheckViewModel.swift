import Foundation
import Observation

/// Máquina de estado do Check — autenticação + registro manual/projetos/localização. `@Observable @MainActor`;
/// jobs canceláveis (debounce 800ms, polling 10s, SSE). Ver specs de auth, decisão e UI.
@Observable
@MainActor
final class CheckViewModel {
    private struct ActiveRemoteContext: Sendable, Equatable {
        let chave: String
        let chaveMutationGeneration: Int
        let activationGeneration: UInt64
    }

    private enum StatusProbeSessionPolicy: Sendable, Equatable {
        case replaceIdentity
        case preserveCurrentSession
    }

    private struct LocalRestoreSnapshot: Sendable, Equatable {
        let chave: String
        let chaveMutationGeneration: Int
    }

    private struct CandidateAuthenticatedSession: Sendable, Equatable {
        let chave: String
        let chaveMutationGeneration: Int
        let epoch: UInt64
    }

    private enum PermissionActivationReview: Sendable, Equatable {
        case safeToReconcile
        case disabledAndReconciled
        case blocked
    }

    private enum LoginAttemptResult: Sendable {
        case response(AppResult<AuthStatus>)
        case staleContext
    }

    private struct SessionCookieProducerTasks: Sendable {
        let passwordVerification: Task<Void, Never>?
        let accountMutation: Task<Void, Never>?
        let keyMutation: Task<Void, Never>?
        let activeRemoteRestore: Task<Void, Never>?
        let approvalPolling: Task<Void, Never>?

        func waitForCompletion() async {
            await passwordVerification?.value
            await accountMutation?.value
            await keyMutation?.value
            await activeRemoteRestore?.value
            await approvalPolling?.value
        }
    }

    private struct DestructiveContextTasks: Sendable {
        let sessionInvalidation: AuthSessionInvalidation?
        let sessionCookieProducers: SessionCookieProducerTasks
        let manualSubmit: Task<Void, Never>?
        let settingsPersistence: Task<Void, Never>?
        let settingsReconciliation: Task<Void, Never>?
        let projectMembershipSync: Task<Void, Never>?
        let localPreferenceMutation: Task<Void, Never>?

        /// Tasks que nunca tentam abrir uma nova transição podem ser drenadas enquanto o barrier
        /// destrutivo permanece fechado. Isso garante que nenhum enqueue/write iniciado antes do wipe
        /// reapareça depois de `clearAll`.
        func waitForLocalWrites() async {
            await sessionCookieProducers.waitForCompletion()
            await manualSubmit?.value
            await settingsPersistence?.value
            await settingsReconciliation?.value
            await localPreferenceMutation?.value
        }

        /// A sincronização de memberships pode estar aguardando o mesmo barrier do owner destrutivo.
        /// Ela é cancelada antes do wipe e drenada somente depois de `end`, quando seus guards de
        /// geração/contexto a fazem sair sem voltar a gravar a identidade anterior.
        func waitForBarrierParticipants() async {
            await projectMembershipSync?.value
        }
    }

    private(set) var uiState = CheckUiState()
    private(set) var languageCode = "pt"

    private let appPreferences: any AppPreferencesStore
    private let securePasswordStore: any SecurePasswordStore
    private let authRepository: any AuthRepository
    private let authSessionCoordinator: any AuthSessionCoordinating
    private let projectRepository: any ProjectRepository
    private let checkRepository: any CheckRepository
    private let captureLocationUseCase: any LocationCapturing
    private let offlineQueue: any OfflineCheckQueueing
    private let permissionsInspector: any PermissionsInspecting
    private let orchestrator: any OrchestratorRunning
    private let significantLocationMonitor: any SignificantLocationMonitoring
    private let checkEventStream: any CheckEventStreaming
    private let activityLogger: any ActivityLogging
    private let evaluationJournal: any EvaluationJournaling
    private let activityLog: ActivityLog?
    private let geofenceRegionManager: (any GeofenceRegionManaging)?
    private let clock: any Clock
    private let uiLifecycleBehavior: CheckUILifecycleBehavior
    private let approvalPollingSleeper: any Sleeping
    private let usesFixtureState: Bool

    private var localRestoreTask: Task<LocalRestoreSnapshot?, Never>?
    private var activeRemoteRestoreTask: Task<Void, Never>?
    private var sceneActivationGate = CheckSceneActivationGate()
    private var activeRestoreGeneration: UInt64 = 0
    private var candidateAuthenticationEpoch: UInt64 = 0
    private var currentCandidateAuthenticatedSession: CandidateAuthenticatedSession?
    private var hydratedCandidateAuthenticatedSession: CandidateAuthenticatedSession?
    private var passwordVerifyTask: Task<Void, Never>?
    private var sessionMutationFenceTask: Task<Void, Never>?
    private var sessionMutationFenceGeneration: UInt64 = 0
    private var destructiveContextWipeInProgress = false
    private var accountDeletionInProgress = false
    private var accountMutationTask: Task<Void, Never>?
    private var accountMutationGeneration = 0
    private var accountMutationInFlightGeneration: Int?
    private var manualSubmitTask: Task<Void, Never>?
    private var manualSubmitGeneration = 0
    private var chaveTask: Task<Void, Never>?
    private var chaveMutationGeneration = 0
    private var chaveMutationInFlightGeneration: Int?
    private var chaveMutationRemoteHandledGeneration: Int?
    private var pendingApprovalPollTask: Task<Void, Never>?
    private var pollGeneration = 0       // token: só a geração mais recente pode limpar pendingApprovalPollTask
    private var checkSseTask: Task<Void, Never>?
    private var settingsPersistenceTask: Task<Void, Never>?
    private var settingsReconciliationTask: Task<Void, Never>?
    private var settingsPersistenceGeneration = 0
    private var localPreferenceMutationTask: Task<Void, Never>?
    private var localPreferenceMutationGeneration = 0
    private var projectMembershipSyncTask: Task<Void, Never>?
    private var pendingProjectMemberships: [String]?
    private var projectMembershipRequiresContextTransition = false
    private var authoritativeUserProjects: UserProjects?
    private var projectMembershipSyncGeneration = 0
    private var projectMembershipLoadGeneration = 0
    private var projectCatalogLoadTask: Task<Void, Never>?
    private var projectCatalogLoadGeneration = 0
    private var activityLoadGeneration = 0
    private var nativeLocationServicesGeneration = 0
    // Sem `deinit`: `deinit` de uma classe `@MainActor` roda nonisolated (Swift 6) e não pode acessar estas
    // propriedades isoladas. Em vez disso, `startPendingApprovalPolling`/`startCheckStream` capturam `[weak self]`
    // — ao desalocar o VM, a próxima checagem acha `self` nil e o loop sai sozinho (sem retenção indefinida).

    init(appPreferences: any AppPreferencesStore, securePasswordStore: any SecurePasswordStore,
         authRepository: any AuthRepository,
         authSessionCoordinator: any AuthSessionCoordinating,
         projectRepository: any ProjectRepository,
         checkRepository: any CheckRepository, captureLocationUseCase: any LocationCapturing,
         offlineQueue: any OfflineCheckQueueing, permissionsInspector: any PermissionsInspecting,
         orchestrator: any OrchestratorRunning,
         significantLocationMonitor: any SignificantLocationMonitoring,
         checkEventStream: any CheckEventStreaming, activityLogger: any ActivityLogging, clock: any Clock,
         evaluationJournal: any EvaluationJournaling = NoopEvaluationJournal(),
         activityLog: ActivityLog? = nil,
         geofenceRegionManager: (any GeofenceRegionManaging)? = nil,
         backgroundReliabilityProfile: BackgroundReliabilityProfile = .legacyWithDiagnostics,
         approvalPollingSleeper: any Sleeping = TaskSleeper(),
         initialState: CheckUiState? = nil,
         initialLanguageCode: String? = nil) {
        self.appPreferences = appPreferences; self.securePasswordStore = securePasswordStore
        self.authRepository = authRepository
        self.authSessionCoordinator = authSessionCoordinator
        self.projectRepository = projectRepository
        self.checkRepository = checkRepository; self.captureLocationUseCase = captureLocationUseCase
        self.offlineQueue = offlineQueue; self.permissionsInspector = permissionsInspector
        self.orchestrator = orchestrator
        self.significantLocationMonitor = significantLocationMonitor
        self.checkEventStream = checkEventStream; self.activityLogger = activityLogger
        self.evaluationJournal = evaluationJournal
        self.activityLog = activityLog; self.geofenceRegionManager = geofenceRegionManager; self.clock = clock
        self.uiLifecycleBehavior = backgroundReliabilityProfile.uiLifecycleBehavior
        self.approvalPollingSleeper = approvalPollingSleeper
        self.usesFixtureState = initialState != nil
        if let initialLanguageCode { self.languageCode = resolveLanguageCode(initialLanguageCode) }
        if let initialState { self.uiState = initialState }
        else {
            let localRestore = Task { [weak self] () -> LocalRestoreSnapshot? in
                guard let self else { return nil }
                return await self.restoreLocalState()
            }
            self.localRestoreTask = localRestore
            if uiLifecycleBehavior == .legacyCompatible {
                Task { [weak self] in
                    guard let snapshot = await localRestore.value else { return }
                    await self?.restoreLegacyRemoteState(snapshot)
                }
            }
        }
    }

    // MARK: - init / restore

    var usesHeadlessLifecycleGuard: Bool {
        uiLifecycleBehavior == .headlessGuarded
    }

    private func restoreLocalState() async -> LocalRestoreSnapshot? {
        let restoreGeneration = chaveMutationGeneration
        let storedLang = await appPreferences.language()
        let storedChave = await appPreferences.chave()
        let storedPw = storedChave.count == 4
            ? securePasswordStore.getPassword(storedChave)
            : ""
        let settings = storedChave.count == 4
            ? await loadUserSettings(storedChave)
            : nil

        guard restoreGeneration == chaveMutationGeneration, !Task.isCancelled else {
            uiState.isInitializing = false
            return nil
        }
        languageCode = resolveInitialLanguageCode(storedLang.isEmpty ? nil : storedLang)
        if storedChave.count == 4 {
            uiState.chave = storedChave
            uiState.password = storedPw
            if let settings { applySettings(settings) }
        }
        uiState.isInitializing = false
        guard storedChave.count == 4 else { return nil }
        return LocalRestoreSnapshot(
            chave: storedChave,
            chaveMutationGeneration: restoreGeneration
        )
    }

    private func restoreLegacyRemoteState(_ snapshot: LocalRestoreSnapshot) async {
        guard snapshot.chaveMutationGeneration == chaveMutationGeneration,
              uiState.chave == snapshot.chave else { return }
        await probeStatus(snapshot.chave, sessionPolicy: .replaceIdentity)
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

    private func activeRemoteContext(for chave: String) -> ActiveRemoteContext? {
        guard uiLifecycleBehavior == .headlessGuarded,
              sceneActivationGate.currentState == .active else { return nil }
        return ActiveRemoteContext(
            chave: chave,
            chaveMutationGeneration: chaveMutationGeneration,
            activationGeneration: activeRestoreGeneration
        )
    }

    private func isRemoteContextValid(_ context: ActiveRemoteContext?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let context else { return true }
        return uiLifecycleBehavior == .headlessGuarded
            && sceneActivationGate.currentState == .active
            && context.chave == uiState.chave
            && context.chaveMutationGeneration == chaveMutationGeneration
            && context.activationGeneration == activeRestoreGeneration
    }

    private func isAuthenticatedSessionCurrent(
        chave: String,
        remoteContext: ActiveRemoteContext?
    ) -> Bool {
        uiState.chave == chave
            && uiState.isAuthenticated
            && isRemoteContextValid(remoteContext)
    }

    private func invalidateActiveRemoteRestore() {
        guard uiLifecycleBehavior == .headlessGuarded else { return }
        activeRestoreGeneration &+= 1
        activeRemoteRestoreTask?.cancel()
        activeRemoteRestoreTask = nil
        // Uma resposta antiga não deve limpar o indicador de uma ativação nova; por isso o owner da
        // geração encerra seus próprios estados visuais no instante da invalidação.
        uiState.isStatusLoading = false
        uiState.isHistoryLoading = false
        uiState.isProjectsLoading = false
        uiState.isLocationLoading = false
    }

    private func beginCandidateAuthenticatedSession(
        chave: String
    ) -> CandidateAuthenticatedSession {
        candidateAuthenticationEpoch &+= 1
        let session = CandidateAuthenticatedSession(
            chave: chave,
            chaveMutationGeneration: chaveMutationGeneration,
            epoch: candidateAuthenticationEpoch
        )
        currentCandidateAuthenticatedSession = session
        hydratedCandidateAuthenticatedSession = nil
        return session
    }

    private func invalidateCandidateAuthenticatedSession() {
        guard uiLifecycleBehavior == .headlessGuarded else { return }
        candidateAuthenticationEpoch &+= 1
        currentCandidateAuthenticatedSession = nil
        hydratedCandidateAuthenticatedSession = nil
    }

    private func isCandidateAuthenticatedSessionCurrent(
        _ session: CandidateAuthenticatedSession
    ) -> Bool {
        currentCandidateAuthenticatedSession == session
            && session.chave == uiState.chave
            && session.chaveMutationGeneration == chaveMutationGeneration
            && uiState.isAuthenticated
    }

    /// Tail serial, somente em memória, para mutações de autenticação que podem receber `Set-Cookie` e
    /// operações que limpam/substituem o cookie. A mutação real entra no tail — apenas aguardá-lo antes
    /// da chamada deixaria uma resposta tardia capaz de repor a sessão depois de um logout/wipe.
    @discardableResult
    private func enqueueSessionCookieOperation<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> Value
    ) -> Task<Value, Never> {
        let previous = sessionMutationFenceTask
        sessionMutationFenceGeneration &+= 1
        let operationTask = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        sessionMutationFenceTask = Task { @MainActor in
            _ = await operationTask.value
        }
        return operationTask
    }

    @discardableResult
    private func enqueueSessionMutationFence(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        enqueueSessionCookieOperation(operation)
    }

    private func awaitSessionMutationFence() async {
        while true {
            let generation = sessionMutationFenceGeneration
            let fence = sessionMutationFenceTask
            await fence?.value
            if generation == sessionMutationFenceGeneration {
                return
            }
        }
    }

    // MARK: - chave / senha

    func onChaveChanged(_ rawValue: String) {
        changeChave(rawValue, shouldProbeWhenComplete: true)
    }

    /// Uma chave digitada no cadastro é apenas um rascunho até o submit. Quando ela é adotada, usa a
    /// mesma transição de identidade, mas o próprio cadastro — e não um probe concorrente — é a operação
    /// remota autoritativa.
    private func changeChave(
        _ rawValue: String,
        shouldProbeWhenComplete: Bool
    ) {
        guard !destructiveContextWipeInProgress,
              !accountDeletionInProgress else { return }
        let sanitized = sanitizeSettingsChave(rawValue)
        let previousChave = uiState.chave
        let sessionInvalidation = previousChave == sanitized
            ? nil
            : authSessionCoordinator.invalidateCurrentIdentity()
        let changesAutomationContext =
            previousChave.count == 4 && previousChave != sanitized
        chaveMutationGeneration += 1
        let mutationGeneration = chaveMutationGeneration
        chaveMutationInFlightGeneration = mutationGeneration
        chaveMutationRemoteHandledGeneration = nil
        nativeLocationServicesGeneration += 1
        invalidateActiveRemoteRestore()
        invalidateCandidateAuthenticatedSession()
        chaveTask?.cancel()                                      // aborta o fluxo de probe/login da chave anterior
        passwordVerifyTask?.cancel()
        accountMutationGeneration += 1
        accountMutationTask?.cancel()
        accountMutationTask = nil
        accountMutationInFlightGeneration = nil
        manualSubmitGeneration += 1
        manualSubmitTask?.cancel()
        manualSubmitTask = nil
        settingsPersistenceGeneration += 1
        settingsPersistenceTask?.cancel()
        settingsPersistenceTask = nil
        settingsReconciliationTask?.cancel()
        settingsReconciliationTask = nil
        localPreferenceMutationGeneration += 1
        localPreferenceMutationTask?.cancel()
        localPreferenceMutationTask = nil
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

        if changesAutomationContext {
            enqueueSessionMutationFence {
                let transition =
                    await self.orchestrator.beginAutomationContextTransition()

                // O owner destrutivo nunca é cancelado pela próxima tecla: stop/logout e persistência da
                // identidade mais recente terminam antes que qualquer probe/login posterior use cookie.
                await self.significantLocationMonitor.stop()
                await self.geofenceRegionManager?.unregisterAll()
                if let sessionInvalidation {
                    await self.authSessionCoordinator.completeInvalidatedLogout(
                        sessionInvalidation
                    )
                }

                var persistedGeneration = -1
                repeat {
                    persistedGeneration = self.chaveMutationGeneration
                    await self.appPreferences.setChave(self.uiState.chave)
                } while persistedGeneration != self.chaveMutationGeneration

                await self.orchestrator.endAutomationContextTransition(transition)
            }
        }
        chaveTask = Task {
            defer {
                if self.chaveMutationInFlightGeneration == mutationGeneration {
                    self.chaveMutationInFlightGeneration = nil
                }
            }
            let mutationIsCurrent: @MainActor () -> Bool = {
                !Task.isCancelled
                    && mutationGeneration == self.chaveMutationGeneration
                    && self.uiState.chave == sanitized
            }

            await awaitSessionMutationFence()
            guard mutationIsCurrent() else { return }
            if !changesAutomationContext {
                await significantLocationMonitor.stop()
                guard mutationIsCurrent() else { return }
                await geofenceRegionManager?.unregisterAll()
                guard mutationIsCurrent() else { return }
                await appPreferences.setChave(sanitized)
                guard mutationIsCurrent() else { return }
                if let sessionInvalidation {
                    let logoutFence = enqueueSessionMutationFence {
                        await self.authSessionCoordinator.completeInvalidatedLogout(
                            sessionInvalidation
                        )
                    }
                    await logoutFence.value
                    guard mutationIsCurrent() else { return }
                }
            }
            if sanitized.count != 4 {
                return
            }
            let settings = await loadUserSettings(sanitized)
            guard mutationIsCurrent() else { return }
            applySettings(settings)
            guard mutationIsCurrent() else { return }
            let storedPw = securePasswordStore.getPassword(sanitized)
            if !storedPw.isEmpty { uiState.password = storedPw }
            guard mutationIsCurrent() else { return }
            guard shouldProbeWhenComplete else { return }
            let sessionPolicy: StatusProbeSessionPolicy =
                sessionInvalidation == nil
                    ? .replaceIdentity
                    : .preserveCurrentSession
            if uiLifecycleBehavior == .headlessGuarded {
                guard let context = activeRemoteContext(for: sanitized) else { return }
                await probeStatus(
                    sanitized,
                    sessionPolicy: sessionPolicy,
                    remoteContext: context
                )
                guard mutationIsCurrent(),
                      isRemoteContextValid(context) else { return }
                chaveMutationRemoteHandledGeneration = mutationGeneration
            } else {
                await probeStatus(sanitized, sessionPolicy: sessionPolicy)
            }
        }
    }

    func onPasswordChanged(_ rawValue: String) {
        uiState.password = rawValue
        passwordVerifyTask?.cancel()
        guard !accountDeletionInProgress else { return }
        guard let status = uiState.authStatus, status.hasPassword, isPasswordVerificationInputValid(rawValue) else { return }
        passwordVerifyTask = Task {
            try? await Task.sleep(for: .milliseconds(800))     // debounce cancelável a cada tecla
            if Task.isCancelled { return }
            let chave = uiState.chave
            await attemptLogin(
                chave,
                rawValue,
                remoteContext: activeRemoteContext(for: chave)
            )
        }
    }

    /// A UI Android autentica após o debounce; o botão explícito da tela técnica usa a mesma máquina de
    /// estado, mas permite ao ensaio físico começar de modo determinístico sem esperar o teclado.
    func submitLogin() {
        guard !accountDeletionInProgress else { return }
        passwordVerifyTask?.cancel()
        let chave = uiState.chave
        let password = uiState.password
        passwordVerifyTask = Task {
            await attemptLogin(
                chave,
                password,
                remoteContext: activeRemoteContext(for: chave)
            )
        }
    }

    // MARK: - probe / polling

    private func probeStatus(
        _ chave: String,
        sessionPolicy: StatusProbeSessionPolicy,
        remoteContext: ActiveRemoteContext? = nil
    ) async {
        guard !destructiveContextWipeInProgress,
              isRemoteContextValid(remoteContext) else { return }
        if sessionPolicy == .replaceIdentity {
            let invalidation = authSessionCoordinator.invalidateCurrentIdentity()
            let replacement = enqueueSessionMutationFence {
                let transition =
                    await self.orchestrator.beginAutomationContextTransition()
                if self.isRemoteContextValid(remoteContext),
                   self.uiState.chave == chave {
                    await self.authSessionCoordinator.completeInvalidatedLogout(
                        invalidation
                    )
                } else {
                    await self.authSessionCoordinator.completeInvalidatedTransition(
                        invalidation
                    )
                }
                await self.orchestrator.endAutomationContextTransition(transition)
            }
            await replacement.value
        } else {
            await awaitSessionMutationFence()
        }
        guard isRemoteContextValid(remoteContext),
              !destructiveContextWipeInProgress,
              uiState.chave == chave else { return }             // chave mudou enquanto aguardava — descarta
        let sessionGeneration = await authSessionCoordinator.useCurrentSession()
        guard isRemoteContextValid(remoteContext),
              !destructiveContextWipeInProgress,
              uiState.chave == chave else { return }
        uiState.isStatusLoading = true
        let statusResult = await authRepository.getStatus(chave)
        guard await authSessionCoordinator.isCurrent(sessionGeneration),
              isRemoteContextValid(remoteContext),
              !destructiveContextWipeInProgress,
              uiState.chave == chave else { return }
        switch statusResult {
        case .success(let status):
            guard isRemoteContextValid(remoteContext),
                  !destructiveContextWipeInProgress,
                  uiState.chave == chave else { return }         // resposta tardia p/ chave abandonada — descarta
            uiState.authStatus = status
            if !status.authenticated {
                invalidateCandidateAuthenticatedSession()
            }
            uiState.isStatusLoading = false
            uiState.prompt = resolvePrompt(status)
            if status.pendingApproval {
                uiState.notificationPrimary = t("auth.awaitingApproval", lang: languageCode)
                uiState.notificationSecondary = ""
                uiState.notificationTone = .error
                startPendingApprovalPolling(chave, remoteContext: remoteContext)
            } else {
                stopPendingApprovalPolling()
                maybeAutoOpenAssistanceDialog(status)
                let storedPw = uiState.password
                if uiLifecycleBehavior == .headlessGuarded,
                   let context = remoteContext,
                   status.authenticated {
                    await onAuthenticationSucceeded(
                        chave,
                        status,
                        remoteContext: context
                    )
                } else if status.hasPassword && !storedPw.isEmpty {
                    await attemptLogin(
                        chave,
                        storedPw,
                        remoteContext: remoteContext,
                        usesStoredCredential: true
                    )                                           // auto-login
                }
            }
        case .failure:
            guard isRemoteContextValid(remoteContext),
                  uiState.chave == chave else { return }
            uiState.isStatusLoading = false
            uiState.statusErrored = true
        }
    }

    private func startPendingApprovalPolling(
        _ chave: String,
        remoteContext: ActiveRemoteContext? = nil
    ) {
        let pollingContext: ActiveRemoteContext?
        if uiLifecycleBehavior == .headlessGuarded {
            pollingContext = remoteContext ?? activeRemoteContext(for: chave)
            guard pollingContext != nil else { return }
        } else {
            pollingContext = nil
        }
        guard pendingApprovalPollTask == nil else { return }     // guarda de reentrância (isActive)
        pollGeneration += 1
        let myGeneration = pollGeneration
        pendingApprovalPollTask = Task { [weak self] in
            while true {
                // lê via self? fraco — NÃO retém self durante o sleep de 10s abaixo.
                guard let stillAwaiting = self?.uiState.isAwaitingApproval, stillAwaiting,
                      self?.uiState.chave == chave,
                      self?.isRemoteContextValid(pollingContext) == true,
                      let sleeper = self?.approvalPollingSleeper else { break }
                await sleeper.sleep(milliseconds: 10_000)
                if Task.isCancelled { break }
                guard let self, self.uiState.chave == chave, self.uiState.isAwaitingApproval,
                      self.isRemoteContextValid(pollingContext) else { break }
                await self.probeStatus(
                    chave,
                    sessionPolicy: pollingContext == nil
                        ? .replaceIdentity
                        : .preserveCurrentSession,
                    remoteContext: pollingContext
                )
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

    private func attemptLogin(
        _ chave: String,
        _ password: String,
        remoteContext: ActiveRemoteContext? = nil,
        usesStoredCredential: Bool = false
    ) async {
        guard !destructiveContextWipeInProgress,
              !accountDeletionInProgress,
              chave.count == 4,
              isPasswordVerificationInputValid(password) else { return }
        guard !destructiveContextWipeInProgress,
              !Task.isCancelled,
              uiState.chave == chave else { return }
        let effectiveContext: ActiveRemoteContext?
        if uiLifecycleBehavior == .headlessGuarded {
            effectiveContext = remoteContext ?? activeRemoteContext(for: chave)
            guard let effectiveContext,
                  isRemoteContextValid(effectiveContext) else { return }
        } else {
            effectiveContext = nil
        }
        guard uiState.chave == chave else { return }              // já mudou antes de tentar — não mostra "verificando"
        uiState.notificationPrimary = t("status.passwordVerifying", lang: languageCode)
        uiState.notificationTone = .info
        let explicitSessionGeneration: AuthSessionGeneration?
        if usesStoredCredential {
            explicitSessionGeneration = nil
        } else {
            explicitSessionGeneration = await authSessionCoordinator.useCurrentSession()
            guard !Task.isCancelled,
                  !destructiveContextWipeInProgress,
                  !accountDeletionInProgress,
                  isRemoteContextValid(effectiveContext),
                  uiState.chave == chave else { return }
        }
        let loginRequest = enqueueSessionCookieOperation { () -> LoginAttemptResult in
            if usesStoredCredential {
                switch await self.authSessionCoordinator.silentRelogin(chave) {
                case .refreshed(let status):
                    return .response(.success(status))
                case .missingPassword:
                    return .response(.failure(.unauthorized))
                case .failed(let error):
                    return .response(.failure(error))
                case .staleContext:
                    return .staleContext
                }
            }
            return .response(
                await self.authSessionCoordinator.login(chave, password)
            )
        }
        let loginResult = await loginRequest.value
        if let explicitSessionGeneration {
            guard await authSessionCoordinator.isCurrent(explicitSessionGeneration),
                  !Task.isCancelled,
                  !destructiveContextWipeInProgress,
                  !accountDeletionInProgress,
                  isRemoteContextValid(effectiveContext),
                  uiState.chave == chave else { return }
        }
        switch loginResult {
        case .staleContext:
            return
        case .response(.success(let status)):
            guard isRemoteContextValid(effectiveContext),
                  !destructiveContextWipeInProgress,
                  uiState.chave == chave else { return }          // resposta tardia p/ chave abandonada — não pisa na UI atual
            if status.authenticated, !usesStoredCredential {
                securePasswordStore.setPassword(chave, password)  // credencial válida — persiste sempre
            }
            uiState.authStatus = status
            if !status.authenticated {
                invalidateCandidateAuthenticatedSession()
            }
            uiState.prompt = resolvePrompt(status)
            if status.authenticated {
                await onAuthenticationSucceeded(
                    chave,
                    status,
                    remoteContext: effectiveContext
                )
                activityLogger.logAuth("Signed in.", .info)
            } else {
                uiState.notificationPrimary = localizeApiMessage(status.message, lang: languageCode)
                uiState.notificationTone = .error
                activityLogger.logError("Sign-in failed.")
            }
        case .response(.failure(let error)):
            guard isRemoteContextValid(effectiveContext) else { return }
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

    private func onAuthenticationSucceeded(
        _ chave: String,
        _ status: AuthStatus,
        remoteContext: ActiveRemoteContext? = nil
    ) async {
        if uiLifecycleBehavior == .headlessGuarded {
            // Autenticação explícita (cadastro/troca de senha) não pertence ao restore de cena em voo.
            // Invalida primeiro esse pipeline para que respostas da sessão anterior, ainda que da mesma
            // chave, não possam hidratar UI ou reabrir o stream sobre o novo cookie.
            if remoteContext == nil {
                invalidateActiveRemoteRestore()
                stopPendingApprovalPolling()
                stopCheckStream()
            }
            let session = beginCandidateAuthenticatedSession(chave: chave)
            guard let context = remoteContext ?? activeRemoteContext(for: chave),
                  isRemoteContextValid(context),
                  isCandidateAuthenticatedSessionCurrent(session) else { return }
            await restoreAuthenticatedRemoteState(
                chave: chave,
                status: status,
                context: context,
                session: session
            )
            return
        }

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

    private func restoreAuthenticatedRemoteState(
        chave: String,
        status: AuthStatus,
        context: ActiveRemoteContext,
        session: CandidateAuthenticatedSession
    ) async {
        guard isRemoteContextValid(context),
              isCandidateAuthenticatedSessionCurrent(session) else { return }
        uiState.notificationPrimary = t("status.authenticationCompleted", lang: languageCode)
        uiState.notificationTone = .teal

        uiState.isHistoryLoading = true
        switch await authRepository.getHistory(chave) {
        case .success(let history):
            guard isRemoteContextValid(context),
                  isCandidateAuthenticatedSessionCurrent(session) else { return }
            uiState.historyState = history
            uiState.transportEnabled = history.transportEnabled
            uiState.isHistoryLoading = false
            if uiState.selectedManualLocation == nil {
                uiState.selectedManualLocation = history.currentLocal
            }
        case .failure:
            guard isRemoteContextValid(context),
                  isCandidateAuthenticatedSessionCurrent(session) else { return }
            uiState.isHistoryLoading = false
        }

        let dismissed = await appPreferences.getFlag(nudgeFlag(chave))
        guard isRemoteContextValid(context),
              isCandidateAuthenticatedSessionCurrent(session) else { return }
        uiState.showAutoActivitiesNudge = shouldShowAutoActivitiesNudge(
            authenticated: status.authenticated,
            autoEnabled: uiState.automaticActivitiesEnabled,
            dismissed: dismissed
        )

        let consent = !(await appPreferences.backgroundLocationConsentAt()).isEmpty
        guard isRemoteContextValid(context),
              isCandidateAuthenticatedSessionCurrent(session) else { return }
        uiState.backgroundLocationConsentGranted = consent

        let permissionReview = await reviewPermissionsAfterActivation(
            captureIfEligible: false,
            remoteContext: context
        )
        guard isRemoteContextValid(context),
              isCandidateAuthenticatedSessionCurrent(session) else { return }
        await loadUserProjects(
            chave: chave,
            remoteContext: context,
            runForegroundReconciliation: permissionReview == .safeToReconcile
        )
        guard isRemoteContextValid(context),
              isCandidateAuthenticatedSessionCurrent(session) else { return }
        await loadMainProjectCatalog(chave: chave, remoteContext: context)
        guard isRemoteContextValid(context),
              isCandidateAuthenticatedSessionCurrent(session) else { return }
        if permissionReview == .safeToReconcile,
           uiState.automaticActivitiesEnabled,
           !(uiState.userProjects?.activeProject ?? "").isEmpty {
            await captureLocation(remoteContext: context)
        }
        guard isRemoteContextValid(context),
              isCandidateAuthenticatedSessionCurrent(session) else { return }
        startCheckStream(chave, remoteContext: context)
        guard isRemoteContextValid(context),
              isCandidateAuthenticatedSessionCurrent(session) else { return }
        hydratedCandidateAuthenticatedSession = session
    }

    private func reconcileAuthenticatedRemoteState(context: ActiveRemoteContext) async {
        guard isRemoteContextValid(context), uiState.isAuthenticated else { return }
        let permissionReview = await reviewPermissionsAfterActivation(
            captureIfEligible: false,
            remoteContext: context
        )
        guard isRemoteContextValid(context), uiState.isAuthenticated else { return }
        await refreshCheckState(remoteContext: context)
        guard isRemoteContextValid(context), uiState.isAuthenticated else { return }

        await loadUserProjects(
            chave: context.chave,
            remoteContext: context,
            runForegroundReconciliation: permissionReview == .safeToReconcile
        )
        guard isRemoteContextValid(context), uiState.isAuthenticated,
              !uiState.isProjectMembershipSyncing else { return }
        let captureIfEligible =
            permissionReview == .safeToReconcile
                && uiState.automaticActivitiesEnabled
                && !(uiState.userProjects?.activeProject ?? "").isEmpty
        if captureIfEligible {
            await captureLocation(remoteContext: context)
        }
        guard isRemoteContextValid(context), uiState.isAuthenticated else { return }
        startCheckStream(context.chave, remoteContext: context)
    }

    /// Reproduz, de forma estruturada, a revisão que a tela legada executa ao voltar ao foreground.
    /// O candidato não depende de `onAppear`: permissões revogadas em Settings são aplicadas antes de
    /// reabrir o stream e nenhuma resposta de uma ativação antiga pode atualizar a UI.
    @discardableResult
    private func reviewPermissionsAfterActivation(
        captureIfEligible: Bool,
        remoteContext: ActiveRemoteContext?
    ) async -> PermissionActivationReview {
        await refreshPermissionState(
            captureIfEligible: captureIfEligible,
            remoteContext: remoteContext
        )
        guard isRemoteContextValid(remoteContext),
              let status = uiState.permissionsStatus else { return .blocked }
        if uiState.automaticActivitiesEnabled
            && !status.ladder.minimumToStartGranted {
            let disabled = await setAutomaticActivitiesEnabled(false)
            guard isRemoteContextValid(remoteContext) else { return .blocked }
            uiState.notificationPrimary = t(
                "autoActivities.insufficientPermissions",
                lang: languageCode
            )
            uiState.notificationTone = .error
            return disabled ? .disabledAndReconciled : .blocked
        } else {
            await reconcileAutomaticLocationServices(
                remoteContext: remoteContext
            )
            guard isRemoteContextValid(remoteContext) else { return .blocked }
            return .safeToReconcile
        }
    }

    // MARK: - autocadastro / senha

    func submitSelfRegistration() {
        guard !destructiveContextWipeInProgress,
              !accountDeletionInProgress else { return }
        let fields = uiState.selfRegistrationFields
        let chave = sanitizeSettingsChave(fields.chave)

        if chave.count != 4 {
            uiState.selfRegistrationFields.errorMessage = t(
                "auth.invalidFourCharacterKey",
                lang: languageCode
            )
            return
        }
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

        if chave != uiState.chave {
            changeChave(chave, shouldProbeWhenComplete: false)
            uiState.selfRegistrationFields = fields
            uiState.selfRegistrationFields.chave = chave
            uiState.dialogOpen = .selfRegistration
        }
        let identityTransitionTask = chaveTask
        uiState.selfRegistrationFields.isBusy = true
        uiState.selfRegistrationFields.errorMessage = ""

        accountMutationGeneration += 1
        let mutationGeneration = accountMutationGeneration
        accountMutationInFlightGeneration = mutationGeneration
        accountMutationTask?.cancel()
        accountMutationTask = Task {
            defer {
                if self.accountMutationInFlightGeneration == mutationGeneration {
                    self.accountMutationInFlightGeneration = nil
                }
            }
            await identityTransitionTask?.value
            guard !Task.isCancelled,
                  !destructiveContextWipeInProgress,
                  mutationGeneration == accountMutationGeneration,
                  uiState.chave == chave else { return }
            let sessionGeneration = await authSessionCoordinator.useCurrentSession()
            guard !Task.isCancelled,
                  !destructiveContextWipeInProgress,
                  !accountDeletionInProgress,
                  mutationGeneration == accountMutationGeneration,
                  uiState.chave == chave else { return }
            let registrationRequest = enqueueSessionCookieOperation {
                await self.authSessionCoordinator.selfRegister(
                    chave,
                    fields.nome.trimmingCharacters(in: .whitespacesAndNewlines),
                    selectedProjectNames,
                    email.isEmpty ? nil : email,
                    fields.password,
                    fields.confirmPw
                )
            }
            let result = await registrationRequest.value
            guard await authSessionCoordinator.isCurrent(sessionGeneration),
                  !Task.isCancelled,
                  !destructiveContextWipeInProgress,
                  !accountDeletionInProgress,
                  mutationGeneration == accountMutationGeneration,
                  uiState.chave == chave else { return }
            switch result {
            case .success(let status):
                securePasswordStore.setPassword(chave, fields.password)   // SEMPRE (auto-login pós-aprovação)
                if status.queueFull {
                    uiState.authStatus = status
                    invalidateCandidateAuthenticatedSession()
                    uiState.prompt = ""
                    uiState.dialogOpen = nil
                    uiState.dismissedAssistanceForChave = chave
                    uiState.selfRegistrationFields = SelfRegistrationFields(chave: chave)
                    uiState.notificationPrimary = t("auth.registrationQueueFull", lang: languageCode)
                    uiState.notificationSecondary = ""
                    uiState.notificationTone = .error
                } else if status.pendingApproval {
                    uiState.authStatus = status
                    invalidateCandidateAuthenticatedSession()
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
                    if !status.authenticated {
                        invalidateCandidateAuthenticatedSession()
                    }
                    uiState.prompt = resolvePrompt(status)
                    uiState.dialogOpen = nil
                    uiState.dismissedAssistanceForChave = chave
                    uiState.selfRegistrationFields = SelfRegistrationFields(chave: chave)
                    if status.authenticated {
                        await onAuthenticationSucceeded(chave, status)
                    }
                }
            case .failure:
                uiState.selfRegistrationFields.isBusy = false
                uiState.selfRegistrationFields.errorMessage = t("registrationDialog.submitFailed", lang: languageCode)
            }
        }
    }

    func submitPasswordChange() {
        guard !destructiveContextWipeInProgress,
              !accountDeletionInProgress else { return }
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

        accountMutationGeneration += 1
        let mutationGeneration = accountMutationGeneration
        accountMutationInFlightGeneration = mutationGeneration
        accountMutationTask?.cancel()
        accountMutationTask = Task {
            defer {
                if self.accountMutationInFlightGeneration == mutationGeneration {
                    self.accountMutationInFlightGeneration = nil
                }
            }
            guard !Task.isCancelled,
                  !destructiveContextWipeInProgress,
                  mutationGeneration == accountMutationGeneration,
                  uiState.chave == chave else { return }
            let sessionGeneration = await authSessionCoordinator.useCurrentSession()
            guard !Task.isCancelled,
                  !destructiveContextWipeInProgress,
                  !accountDeletionInProgress,
                  mutationGeneration == accountMutationGeneration,
                  uiState.chave == chave else { return }
            let passwordRequest = enqueueSessionCookieOperation {
                if hasExistingPassword {
                    await self.authSessionCoordinator.changePassword(
                        chave,
                        fields.oldPw,
                        fields.newPw
                    )
                } else {
                    await self.authSessionCoordinator.registerPassword(
                        chave,
                        nil,
                        fields.newPw
                    )
                }
            }
            let result = await passwordRequest.value
            guard await authSessionCoordinator.isCurrent(sessionGeneration),
                  !Task.isCancelled,
                  !destructiveContextWipeInProgress,
                  !accountDeletionInProgress,
                  mutationGeneration == accountMutationGeneration,
                  uiState.chave == chave else { return }
            switch result {
            case .success(let status):
                securePasswordStore.setPassword(chave, fields.newPw)
                uiState.authStatus = status
                if !status.authenticated {
                    invalidateCandidateAuthenticatedSession()
                }
                uiState.prompt = resolvePrompt(status)
                uiState.dialogOpen = nil
                uiState.dismissedAssistanceForChave = chave
                uiState.passwordChangeFields = PasswordChangeFields()
                if status.authenticated {
                    await onAuthenticationSucceeded(chave, status)
                }
            case .failure:
                uiState.passwordChangeFields.isBusy = false
                uiState.passwordChangeFields.errorMessage = t("passwordDialog.changeFailed", lang: languageCode)
            }
        }
    }

    // MARK: - foreground / expiry / delete

    /// Única entrada de scene state do pipeline candidato. O gate aceita a primeira cena já ativa,
    /// deduplica reconstruções e reabre uma restauração somente após uma transição realmente não ativa.
    func sceneStateDidChange(_ state: EvaluationApplicationState) async {
        guard !Task.isCancelled,
              uiLifecycleBehavior == .headlessGuarded,
              !usesFixtureState else { return }

        switch sceneActivationGate.transition(to: state) {
        case .becameInactive:
            invalidateActiveRemoteRestore()
            stopPendingApprovalPolling()
            stopCheckStream()

        case .becameActive:
            activeRestoreGeneration &+= 1
            let activationGeneration = activeRestoreGeneration
            let identityGeneration = chaveMutationGeneration
            let localRestore = localRestoreTask
            let task = Task { [weak self] in
                _ = await localRestore?.value
                guard let self else { return }
                await self.restoreRemoteStateWhenActive(
                    activationGeneration: activationGeneration,
                    identityGeneration: identityGeneration
                )
            }
            activeRemoteRestoreTask = task
            await task.value
            if activationGeneration == activeRestoreGeneration {
                activeRemoteRestoreTask = nil
            }

        case .unchanged:
            if state == .active {
                await activeRemoteRestoreTask?.value
            }
        }
    }

    private func restoreRemoteStateWhenActive(
        activationGeneration: UInt64,
        identityGeneration: Int
    ) async {
        guard !destructiveContextWipeInProgress,
              sceneActivationGate.currentState == .active,
              activationGeneration == activeRestoreGeneration,
              identityGeneration == chaveMutationGeneration,
              !Task.isCancelled else { return }

        if chaveMutationInFlightGeneration == identityGeneration,
           let identityTask = chaveTask {
            await identityTask.value
            guard sceneActivationGate.currentState == .active,
                  activationGeneration == activeRestoreGeneration,
                  identityGeneration == chaveMutationGeneration,
                  !Task.isCancelled else { return }
            if chaveMutationRemoteHandledGeneration == identityGeneration {
                return
            }
        }

        await awaitSessionMutationFence()
        guard sceneActivationGate.currentState == .active,
              activationGeneration == activeRestoreGeneration,
              identityGeneration == chaveMutationGeneration,
              !destructiveContextWipeInProgress,
              !Task.isCancelled else { return }

        if accountMutationInFlightGeneration == accountMutationGeneration,
           let mutationTask = accountMutationTask {
            // Cadastro/troca de senha são operações explícitas e autoritativas. Se uma ativação as
            // encontra em voo, aguarda o terminal e não inicia um probe concorrente; sucesso ativo
            // hidrata por conta própria e sucesso em background fica marcado para o próximo active.
            await mutationTask.value
            return
        }

        let chave = uiState.chave
        guard chave.count == 4 else { return }
        let context = ActiveRemoteContext(
            chave: chave,
            chaveMutationGeneration: identityGeneration,
            activationGeneration: activationGeneration
        )
        guard isRemoteContextValid(context) else { return }

        // Em um relaunch anterior ao primeiro unlock, o Keychain pode ter retornado vazio no restore
        // local. A primeira cena realmente ativa relê somente a credencial local, sem tocar na rede.
        if uiState.password.isEmpty {
            let unlockedPassword = securePasswordStore.getPassword(chave)
            guard isRemoteContextValid(context) else { return }
            if !unlockedPassword.isEmpty { uiState.password = unlockedPassword }
        }

        if uiState.isAwaitingApproval {
            await probeStatus(
                chave,
                sessionPolicy: .preserveCurrentSession,
                remoteContext: context
            )
        } else if uiState.isAuthenticated {
            if let session = currentCandidateAuthenticatedSession,
               hydratedCandidateAuthenticatedSession != session,
               isCandidateAuthenticatedSessionCurrent(session),
               let status = uiState.authStatus {
                await restoreAuthenticatedRemoteState(
                    chave: chave,
                    status: status,
                    context: context,
                    session: session
                )
            } else {
                await reconcileAuthenticatedRemoteState(context: context)
            }
        } else {
            await probeStatus(
                chave,
                sessionPolicy: .preserveCurrentSession,
                remoteContext: context
            )
        }
    }

    func onForegroundResume() {
        if usesFixtureState || uiLifecycleBehavior == .headlessGuarded { return }
        if uiState.isAwaitingApproval {
            let chave = uiState.chave
            if chave.count == 4 {
                Task {
                    await probeStatus(chave, sessionPolicy: .replaceIdentity)
                }
            }
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
        if !enabled {
            nativeLocationServicesGeneration += 1
            return await disableAutomaticActivities(chave: chave)
        }
        let membershipLoadGeneration = projectMembershipLoadGeneration
        var refreshedProjects: UserProjects?
        var activationTransition: AutomationContextTransitionToken?

        if enabled {
            guard !uiState.isProjectsLoading, !uiState.isProjectMembershipSyncing else { return false }
            switch await projectRepository.getUserProjects() {
            case .success(let userProjects):
                guard uiState.chave == chave, uiState.isAuthenticated,
                      !uiState.isProjectMembershipSyncing,
                      membershipLoadGeneration == projectMembershipLoadGeneration else { return false }
                let previousActiveProject =
                    (authoritativeUserProjects ?? uiState.userProjects)?.activeProject
                authoritativeUserProjects = userProjects
                uiState.userProjects = userProjects
                guard !userProjects.projects.isEmpty else {
                    let transition = await orchestrator.beginAutomationContextTransition()
                    let contextStillValid =
                        uiState.chave == chave
                            && uiState.isAuthenticated
                            && membershipLoadGeneration == projectMembershipLoadGeneration
                    guard contextStillValid else {
                        await orchestrator.endAutomationContextTransition(transition)
                        return false
                    }
                    let persistence = enqueueSettingsUpdate { settings in
                        settings.projects = []
                        settings.activeProject = ""
                        settings.automaticActivitiesEnabled = false
                    }
                    await persistence.value
                    if uiState.chave == chave, uiState.isAuthenticated {
                        let persistedSettings = await loadUserSettings(chave)
                        if uiState.chave == chave, uiState.isAuthenticated {
                            applySettings(persistedSettings)
                            uiState.availableLocations = []
                            uiState.selectedManualLocation = nil
                            showNoProjectNotification()
                            await reconcileAutomaticLocationServices()
                        }
                    }
                    await orchestrator.endAutomationContextTransition(transition)
                    return false
                }
                let activeProject = userProjects.projects.contains(userProjects.activeProject)
                    ? userProjects.activeProject
                    : userProjects.projects[0]
                let normalizedProjects = UserProjects(
                    projects: userProjects.projects,
                    activeProject: activeProject)
                refreshedProjects = normalizedProjects
                if let previousActiveProject,
                   previousActiveProject != normalizedProjects.activeProject {
                    activationTransition =
                        await orchestrator.beginAutomationContextTransition()
                    guard uiState.chave == chave, uiState.isAuthenticated,
                          !uiState.isProjectMembershipSyncing,
                          membershipLoadGeneration == projectMembershipLoadGeneration else {
                        if let activationTransition {
                            await orchestrator.endAutomationContextTransition(
                                activationTransition
                            )
                        }
                        return false
                    }
                }
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
        if let activationTransition {
            await orchestrator.endAutomationContextTransition(activationTransition)
        }
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

    /// Persiste OFF enquanto o barrier de contexto permanece fechado. Isso impede que uma avaliação da
    /// configuração anterior atravesse um await e submeta depois que o usuário revogou a automação.
    private func disableAutomaticActivities(chave: String) async -> Bool {
        let transition = await orchestrator.beginAutomationContextTransition()
        let persistence = enqueueSettingsUpdate { settings in
            settings.automaticActivitiesEnabled = false
        }
        await persistence.value

        var completed = false
        if uiState.chave == chave, uiState.isAuthenticated {
            let persistedSettings = await loadUserSettings(chave)
            if uiState.chave == chave, uiState.isAuthenticated {
                applySettings(persistedSettings)
                await reconcileAutomaticLocationServices()
                completed = uiState.chave == chave && uiState.isAuthenticated
            }
        }
        await orchestrator.endAutomationContextTransition(transition)
        guard completed else { return false }

        activityLogger.logSystem("Automatic activities disabled by user.", .info)
        // Fora do barrier: reconcilia os tickets especiais da Pausa Programada já com OFF durável.
        await orchestrator.runOnce(.foreground)
        return true
    }

    private func refreshCheckState() {
        let chave = uiState.chave
        let remoteContext: ActiveRemoteContext?
        if uiLifecycleBehavior == .headlessGuarded {
            remoteContext = activeRemoteContext(for: chave)
            guard remoteContext != nil else { return }
        } else {
            remoteContext = nil
        }
        Task {
            await refreshCheckState(
                chave: chave,
                remoteContext: remoteContext
            )
        }
    }

    private func refreshCheckState(remoteContext: ActiveRemoteContext) async {
        await refreshCheckState(
            chave: remoteContext.chave,
            remoteContext: remoteContext
        )
    }

    private func refreshCheckState(
        chave: String,
        remoteContext: ActiveRemoteContext?
    ) async {
        guard isAuthenticatedSessionCurrent(
            chave: chave,
            remoteContext: remoteContext
        ) else { return }
        switch await checkRepository.getState(chave) {
        case .success(let state):
            guard isAuthenticatedSessionCurrent(
                chave: chave,
                remoteContext: remoteContext
            ) else { return }
            uiState.historyState = state
            uiState.transportEnabled = state.transportEnabled
            if uiState.selectedManualLocation == nil {
                uiState.selectedManualLocation = state.currentLocal
            }
            await orchestrator.confirmedState(chave: chave, newState: state)
        case .failure(let error):
            guard isRemoteContextValid(remoteContext),
                  uiState.chave == chave else { return }
            if case .unauthorized = error { handleAuthExpiry() }
        }
    }

    private func handleAuthExpiry() {
        guard !destructiveContextWipeInProgress else { return }
        let invalidation = authSessionCoordinator.invalidateCurrentIdentity()
        invalidateActiveRemoteRestore()
        invalidateCandidateAuthenticatedSession()
        stopCheckStream()
        resetProjectMembershipSync()
        nativeLocationServicesGeneration += 1
        let expiredChave = uiState.chave
        if var status = uiState.authStatus {
            status.authenticated = false
            uiState.authStatus = status
        }
        enqueueSessionMutationFence {
            let transition =
                await self.orchestrator.beginAutomationContextTransition()
            if self.uiState.chave == expiredChave,
               !self.uiState.isAuthenticated {
                await self.significantLocationMonitor.stop()
                await self.geofenceRegionManager?.unregisterAll()
                await self.authSessionCoordinator.completeInvalidatedLogout(
                    invalidation
                )
            } else {
                await self.authSessionCoordinator.completeInvalidatedTransition(
                    invalidation
                )
            }
            await self.orchestrator.endAutomationContextTransition(transition)
        }
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
        let remoteContext: ActiveRemoteContext?
        if uiLifecycleBehavior == .headlessGuarded {
            remoteContext = activeRemoteContext(for: uiState.chave)
            guard remoteContext != nil else { return }
        } else {
            remoteContext = nil
        }
        Task {
            await captureLocation(remoteContext: remoteContext)
        }
    }

    private func captureLocation(remoteContext: ActiveRemoteContext?) async {
        guard isRemoteContextValid(remoteContext) else { return }
        guard uiState.automaticActivitiesEnabled, uiState.locationPermissionSufficient,
              !uiState.isLocationLoading else { return }
        uiState.isLocationLoading = true
        let chave = uiState.chave
        let threshold = uiState.locationMatch?.accuracyThresholdMeters ?? 30
        let result = await captureLocationUseCase(threshold)
        guard isAuthenticatedSessionCurrent(
            chave: chave,
            remoteContext: remoteContext
        ) else { return }
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

    private func refreshPermissionState(
        captureIfEligible: Bool,
        remoteContext: ActiveRemoteContext? = nil
    ) async {
        guard isRemoteContextValid(remoteContext) else { return }
        let chave = uiState.chave
        let status = await permissionsInspector.inspect()
        guard isAuthenticatedSessionCurrent(
            chave: chave,
            remoteContext: remoteContext
        ) else { return }
        uiState.permissionsStatus = status
        uiState.locationPermissionSufficient = status.preciseLocationGranted
        if !status.preciseLocationGranted {
            uiState.locationMatch = nil
            uiState.isLocationLoading = false
        } else if captureIfEligible && uiState.automaticActivitiesEnabled {
            if remoteContext != nil {
                await captureLocation(remoteContext: remoteContext)
            } else {
                captureLocation()
            }
        }
    }

    private func loadAvailableLocations(
        chave: String,
        remoteContext: ActiveRemoteContext? = nil
    ) async {
        guard isAuthenticatedSessionCurrent(
            chave: chave,
            remoteContext: remoteContext
        ) else { return }
        switch await checkRepository.getLocations() {
        case .success(let options):
            guard isAuthenticatedSessionCurrent(
                chave: chave,
                remoteContext: remoteContext
            ) else { return }
            uiState.availableLocations = options.items
        case .failure(let error):
            guard isRemoteContextValid(remoteContext),
                  uiState.chave == chave else { return }
            if case .unauthorized = error { handleAuthExpiry() }
        }
    }

    private func loadUserProjects(
        chave: String,
        remoteContext: ActiveRemoteContext? = nil,
        runForegroundReconciliation: Bool = true
    ) async {
        // Uma seleção otimista em andamento já será reconciliada pelo worker de PUT. Um GET paralelo
        // poderia repor temporariamente o estado antigo do servidor sobre as checkboxes recém-alteradas.
        guard projectMembershipSyncTask == nil,
              isAuthenticatedSessionCurrent(
                  chave: chave,
                  remoteContext: remoteContext
              ) else { return }
        projectMembershipLoadGeneration += 1
        let loadGeneration = projectMembershipLoadGeneration
        uiState.isProjectsLoading = true
        switch await projectRepository.getUserProjects() {
        case .success(let projects):
            guard isAuthenticatedSessionCurrent(
                      chave: chave,
                      remoteContext: remoteContext
                  ),
                  loadGeneration == projectMembershipLoadGeneration else { return }
            let previousActiveProject = (authoritativeUserProjects ?? uiState.userProjects)?.activeProject
            let activeProjectChanged =
                previousActiveProject.map { $0 != projects.activeProject } == true
            let transition = activeProjectChanged
                ? await orchestrator.beginAutomationContextTransition()
                : nil
            guard isAuthenticatedSessionCurrent(
                      chave: chave,
                      remoteContext: remoteContext
                  ),
                  loadGeneration == projectMembershipLoadGeneration else {
                if let transition {
                    await orchestrator.endAutomationContextTransition(transition)
                }
                return
            }
            authoritativeUserProjects = projects
            uiState.userProjects = projects
            updateNoProjectNotification(for: projects)
            await persistUserProjects(chave: chave, projects: projects.projects, activeProject: projects.activeProject)
            guard isAuthenticatedSessionCurrent(
                chave: chave,
                remoteContext: remoteContext
            ), loadGeneration == projectMembershipLoadGeneration else {
                if let transition {
                    await orchestrator.endAutomationContextTransition(transition)
                }
                return
            }
            // Mesmo que o servidor devolva círculos geometricamente iguais, eles agora pertencem a outro
            // contexto. Remover o conjunto anterior ainda dentro do barrier evita reutilizar uma geração
            // física/confirmada da conta ou projeto anterior.
            if activeProjectChanged {
                await geofenceRegionManager?.unregisterAll()
            }
            if let transition {
                await orchestrator.endAutomationContextTransition(transition)
            }
            guard isAuthenticatedSessionCurrent(
                      chave: chave,
                      remoteContext: remoteContext
                  ),
                  loadGeneration == projectMembershipLoadGeneration else { return }
            if projects.projects.isEmpty {
                uiState.availableLocations = []
                uiState.selectedManualLocation = nil
            } else {
                await loadAvailableLocations(
                    chave: chave,
                    remoteContext: remoteContext
                )
            }
            guard isAuthenticatedSessionCurrent(
                chave: chave,
                remoteContext: remoteContext
            ) else { return }
            await reconcileAutomaticLocationServices(
                forceGeofenceRefresh: true,
                remoteContext: remoteContext
            )
            guard isAuthenticatedSessionCurrent(
                chave: chave,
                remoteContext: remoteContext
            ) else { return }
            if runForegroundReconciliation {
                await orchestrator.runOnce(.foreground)
            }
            guard isAuthenticatedSessionCurrent(
                      chave: chave,
                      remoteContext: remoteContext
                  ),
                  loadGeneration == projectMembershipLoadGeneration else { return }
            uiState.isProjectsLoading = false
        case .failure(let error):
            guard isRemoteContextValid(remoteContext),
                  uiState.chave == chave,
                  loadGeneration == projectMembershipLoadGeneration else { return }
            if case .unauthorized = error { handleAuthExpiry() }
            else {
                uiState.isProjectsLoading = false
                uiState.notificationPrimary = t("projects.userProjectsLoadFailed", lang: languageCode)
                uiState.notificationSecondary = ""
                uiState.notificationTone = .error
            }
        }
    }

    private func loadMainProjectCatalog(
        chave: String,
        remoteContext: ActiveRemoteContext? = nil
    ) async {
        guard isAuthenticatedSessionCurrent(
            chave: chave,
            remoteContext: remoteContext
        ) else { return }
        switch await projectRepository.listProjects() {
        case .success(let catalog):
            guard isAuthenticatedSessionCurrent(
                chave: chave,
                remoteContext: remoteContext
            ) else { return }
            uiState.mainProjectCatalog = catalog
        case .failure(let error):
            guard isRemoteContextValid(remoteContext),
                  uiState.chave == chave else { return }
            if case .unauthorized = error { handleAuthExpiry() }
        }
    }

    func onProjectMembershipToggled(_ projectName: String) {
        guard uiState.isAuthenticated, let currentState = uiState.userProjects else { return }
        nativeLocationServicesGeneration += 1
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
        if optimisticActiveProject != currentState.activeProject {
            projectMembershipRequiresContextTransition = true
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
        var contextTransition: AutomationContextTransitionToken?
        var activeProjectChanged = false

        while !Task.isCancelled {
            guard uiState.chave == chave, uiState.isAuthenticated,
                  generation == projectMembershipSyncGeneration,
                  let requestedProjects = pendingProjectMemberships else { break }
            pendingProjectMemberships = nil
            if projectMembershipRequiresContextTransition, contextTransition == nil {
                // A geração muda antes do primeiro request que pode remover/trocar o projeto ativo.
                contextTransition = await orchestrator.beginAutomationContextTransition()
                guard !Task.isCancelled, uiState.chave == chave, uiState.isAuthenticated,
                      generation == projectMembershipSyncGeneration else {
                    if let contextTransition {
                        await orchestrator.endAutomationContextTransition(contextTransition)
                    }
                    return
                }
            }

            switch await projectRepository.updateUserProjects(requestedProjects) {
            case .success(let projects):
                guard !Task.isCancelled, uiState.chave == chave, uiState.isAuthenticated,
                      generation == projectMembershipSyncGeneration else {
                    if let contextTransition {
                        await orchestrator.endAutomationContextTransition(contextTransition)
                    }
                    return
                }
                let previousActiveProject = authoritativeUserProjects?.activeProject ?? ""
                if previousActiveProject != projects.activeProject {
                    activeProjectChanged = true
                    if contextTransition == nil {
                        contextTransition = await orchestrator.beginAutomationContextTransition()
                        guard !Task.isCancelled, uiState.chave == chave, uiState.isAuthenticated,
                              generation == projectMembershipSyncGeneration else {
                            if let contextTransition {
                                await orchestrator.endAutomationContextTransition(contextTransition)
                            }
                            return
                        }
                    }
                }
                // A resposta do servidor é a fonte autoritativa. Se houve outro toque enquanto o PUT
                // estava em andamento, preservamos apenas a seleção otimista mais nova até o próximo PUT.
                authoritativeUserProjects = projects
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
                      generation == projectMembershipSyncGeneration else {
                    if let contextTransition {
                        await orchestrator.endAutomationContextTransition(contextTransition)
                    }
                    return
                }
                if case .unauthorized = error {
                    if let contextTransition {
                        await orchestrator.endAutomationContextTransition(contextTransition)
                    }
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
                      generation == projectMembershipSyncGeneration else {
                    if let contextTransition {
                        await orchestrator.endAutomationContextTransition(contextTransition)
                    }
                    return
                }
                if pendingProjectMemberships != nil { continue }

                if authoritativeUserProjects.projects.isEmpty {
                    uiState.availableLocations = []
                } else {
                    await loadAvailableLocations(chave: chave)
                }
                guard !Task.isCancelled, uiState.chave == chave, uiState.isAuthenticated,
                      generation == projectMembershipSyncGeneration else {
                    if let contextTransition {
                        await orchestrator.endAutomationContextTransition(contextTransition)
                    }
                    return
                }
                if pendingProjectMemberships != nil { continue }

                if activeProjectChanged {
                    // Não reutilizar regiões físicas de um projeto anterior se o conjunto remoto coincidir
                    // por ID/geometria. O próximo register recomeça uma geração nova depois desta limpeza.
                    await geofenceRegionManager?.unregisterAll()
                    guard !Task.isCancelled, uiState.chave == chave, uiState.isAuthenticated,
                          generation == projectMembershipSyncGeneration else {
                        if let contextTransition {
                            await orchestrator.endAutomationContextTransition(contextTransition)
                        }
                        return
                    }
                    activeProjectChanged = false
                }
                await reconcileAutomaticLocationServices(forceGeofenceRefresh: true)
                guard !Task.isCancelled, uiState.chave == chave, uiState.isAuthenticated,
                      generation == projectMembershipSyncGeneration else {
                    if let contextTransition {
                        await orchestrator.endAutomationContextTransition(contextTransition)
                    }
                    return
                }
                if pendingProjectMemberships != nil { continue }

                if let transition = contextTransition {
                    await orchestrator.endAutomationContextTransition(transition)
                    contextTransition = nil
                    projectMembershipRequiresContextTransition = false
                }
                await orchestrator.runOnce(.foreground)
                guard !Task.isCancelled, uiState.chave == chave, uiState.isAuthenticated,
                      generation == projectMembershipSyncGeneration else { return }
                if pendingProjectMemberships != nil { continue }

                needsReconciliation = false
            }
        }

        if let contextTransition {
            await orchestrator.endAutomationContextTransition(contextTransition)
        }
        projectMembershipRequiresContextTransition = false
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
        projectMembershipRequiresContextTransition = false
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
        manualSubmitGeneration += 1
        let submissionGeneration = manualSubmitGeneration
        manualSubmitTask?.cancel()
        manualSubmitTask = Task {
            switch await checkRepository.submit(
                chave: state.chave,
                projeto: project,
                action: state.selectedAction,
                local: location,
                informe: informe,
                eventTime: eventTime,
                clientEventId: clientEventId) {
            case .success(let newState):
                guard !Task.isCancelled,
                      submissionGeneration == manualSubmitGeneration,
                      uiState.chave == state.chave,
                      uiState.isAuthenticated else { return }
                await orchestrator.acceptedCheck(
                    chave: state.chave,
                    project: project,
                    action: state.selectedAction,
                    newState: newState)
                guard !Task.isCancelled,
                      submissionGeneration == manualSubmitGeneration,
                      uiState.chave == state.chave,
                      uiState.isAuthenticated else { return }
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
                    guard !Task.isCancelled,
                          submissionGeneration == manualSubmitGeneration,
                          uiState.chave == state.chave else { return }
                    handleAuthExpiry()
                    activityLogger.logError("Session expired — sign in again.")
                } else if case .network = error {
                    guard !Task.isCancelled,
                          submissionGeneration == manualSubmitGeneration,
                          uiState.chave == state.chave,
                          uiState.isAuthenticated else { return }
                    await offlineQueue.enqueue(.decided(PendingCheckEvent.Decided(
                        chave: state.chave,
                        projeto: project,
                        capturedAtEpochMs: Int64((eventTime.timeIntervalSince1970 * 1000).rounded()),
                        clientEventId: clientEventId,
                        action: state.selectedAction == .checkOut ? "checkout" : "checkin",
                        local: location,
                        informe: informe == .retroativo ? "retroativo" : "normal")))
                    guard !Task.isCancelled,
                          submissionGeneration == manualSubmitGeneration,
                          uiState.chave == state.chave,
                          uiState.isAuthenticated else { return }
                    await orchestrator.invalidateAccuracyRetry()
                    guard !Task.isCancelled,
                          submissionGeneration == manualSubmitGeneration,
                          uiState.chave == state.chave,
                          uiState.isAuthenticated else { return }
                    uiState.isSubmitting = false
                    uiState.notificationPrimary = t("status.savedOffline", lang: languageCode)
                    uiState.notificationTone = .success
                    activityLogger.logQueuedOffline(
                        .user, state.selectedAction == .checkIn ? .checkIn : .checkOut, location)
                } else if case .conflict = error {
                    guard !Task.isCancelled,
                          submissionGeneration == manualSubmitGeneration,
                          uiState.chave == state.chave,
                          uiState.isAuthenticated else { return }
                    // Um 409 pode significar que a membership foi removida em outro cliente. Revalida
                    // antes de escolher a mensagem, pois nem todo conflito do endpoint é "sem projeto".
                    await loadUserProjects(chave: state.chave)
                    guard !Task.isCancelled,
                          submissionGeneration == manualSubmitGeneration,
                          uiState.chave == state.chave,
                          uiState.isAuthenticated else { return }
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
                    guard !Task.isCancelled,
                          submissionGeneration == manualSubmitGeneration,
                          uiState.chave == state.chave else { return }
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

    /// Invalida producers locais antes do primeiro `await` destrutivo. A geração de persistence impede que
    /// uma task cancelada, mas já enfileirada, volte a gravar preferências depois do wipe.
    private func prepareForDestructiveContextWipe(
        invalidateSession: Bool = true
    ) -> DestructiveContextTasks {
        destructiveContextWipeInProgress = true
        let sessionInvalidation = invalidateSession
            ? authSessionCoordinator.invalidateCurrentIdentity()
            : nil
        let authenticationTask = passwordVerifyTask
        let accountTask = accountMutationTask
        let submitTask = manualSubmitTask
        let keyTask = chaveTask
        let remoteRestoreTask = activeRemoteRestoreTask
        let approvalTask = pendingApprovalPollTask
        let persistenceTask = settingsPersistenceTask
        let reconciliationTask = settingsReconciliationTask
        let membershipTask = projectMembershipSyncTask
        let preferenceTask = localPreferenceMutationTask

        nativeLocationServicesGeneration += 1
        invalidateActiveRemoteRestore()
        invalidateCandidateAuthenticatedSession()
        passwordVerifyTask?.cancel()
        passwordVerifyTask = nil
        accountMutationGeneration += 1
        accountMutationTask?.cancel()
        accountMutationTask = nil
        accountMutationInFlightGeneration = nil
        manualSubmitGeneration += 1
        manualSubmitTask?.cancel()
        manualSubmitTask = nil
        chaveMutationGeneration += 1
        chaveTask?.cancel()
        chaveTask = nil
        chaveMutationInFlightGeneration = nil
        chaveMutationRemoteHandledGeneration = nil
        settingsPersistenceGeneration += 1
        settingsPersistenceTask?.cancel()
        settingsPersistenceTask = nil
        settingsReconciliationTask?.cancel()
        settingsReconciliationTask = nil
        projectCatalogLoadGeneration += 1
        projectCatalogLoadTask?.cancel()
        projectCatalogLoadTask = nil
        localPreferenceMutationGeneration += 1
        localPreferenceMutationTask?.cancel()
        localPreferenceMutationTask = nil
        stopCheckStream()
        stopPendingApprovalPolling()
        resetProjectMembershipSync()
        uiState = CheckUiState(isInitializing: false)
        return DestructiveContextTasks(
            sessionInvalidation: sessionInvalidation,
            sessionCookieProducers: SessionCookieProducerTasks(
                passwordVerification: authenticationTask,
                accountMutation: accountTask,
                keyMutation: keyTask,
                activeRemoteRestore: remoteRestoreTask,
                approvalPolling: approvalTask
            ),
            manualSubmit: submitTask,
            settingsPersistence: persistenceTask,
            settingsReconciliation: reconciliationTask,
            projectMembershipSync: membershipTask,
            localPreferenceMutation: preferenceTask
        )
    }

    /// LGPD art. 18 — wipe local só em sucesso do servidor; 409 mantém a sessão.
    func deleteAccount() {
        guard !destructiveContextWipeInProgress,
              !accountDeletionInProgress else { return }
        accountDeletionInProgress = true
        let deletionChave = uiState.chave
        let deletionGeneration = chaveMutationGeneration
        Task {
            defer { accountDeletionInProgress = false }
            guard uiState.chave == deletionChave,
                  uiState.isAuthenticated else { return }
            let deletionRequest = enqueueSessionCookieOperation {
                await self.authSessionCoordinator.deleteAccount()
            }
            let result = await deletionRequest.value
            guard uiState.chave == deletionChave,
                  chaveMutationGeneration == deletionGeneration else { return }
            switch result {
            case .deleted(let deletionInvalidation):
                // O DELETE remoto ainda não é um wipe até ser aceito. Só então invalida producers locais
                // de forma síncrona, drena qualquer logout anterior e só então abre o barrier do wipe.
                // Assim uma falha do servidor preserva integralmente sessão, pausa, retry, fila e journal.
                let localTasks = prepareForDestructiveContextWipe(
                    invalidateSession: false
                )
                await awaitSessionMutationFence()
                await localTasks.waitForLocalWrites()
                let transition = await orchestrator.beginAutomationContextTransition()
                // O DELETE já limpou o cookie. Reabra a autoridade de sessão antes de aguardar o motor:
                // uma avaliação admitida pode estar suspensa em `useCurrentSession` e precisa acordar
                // com geração stale para conseguir publicar seu terminal antes do journal ser apagado.
                await authSessionCoordinator.completeInvalidatedTransition(
                    deletionInvalidation
                )
                // O terminal antigo precisa chegar ao journal antes de journal/fila serem apagados.
                await orchestrator.awaitAutomationQuiescence(transition)
                await significantLocationMonitor.stop()
                await geofenceRegionManager?.unregisterAll()
#if DEBUG
                await BackgroundValidationHarness.shared.stop()
                await BackgroundValidationRecorder.shared.clear()
#endif
                await evaluationJournal.clear()
                activityLog?.clear()
                securePasswordStore.clearAll()
                await appPreferences.clearAll()
                await offlineQueue.clear()
                EvaluationLog.shared.reset()
                await orchestrator.endAutomationContextTransition(transition)
                await localTasks.waitForBarrierParticipants()
                destructiveContextWipeInProgress = false
            case .failed(let error):
                guard uiState.chave == deletionChave else { return }
                let message = { if case .conflict = error { return t("settings.deleteAccountBlocked", lang: languageCode) }
                                return t("settings.deleteAccountFailed", lang: languageCode) }()
                uiState.notificationPrimary = message
                uiState.notificationTone = .error
            case .staleContext:
                return
            }
        }
    }

    /// LGPD art. 18 — equivalente ao `PrivacyViewModel.deleteLocalData` do Kotlin. Para o motor antes
    /// de apagar credenciais, preferências, fila GPS pendente, logs locais e sessão. Não toca nos dados
    /// já enviados ao servidor; essa solicitação continua sendo feita pelo canal de privacidade.
    func deleteLocalData() async {
        let localTasks = prepareForDestructiveContextWipe()
        await awaitSessionMutationFence()
        await localTasks.waitForLocalWrites()
        let transition = await orchestrator.beginAutomationContextTransition()
        if let invalidation = localTasks.sessionInvalidation {
            // Fecha a sessão remota antes do drain do motor. `begin...` já tornou o contexto automático
            // stale; liberar os waiters agora elimina o ciclo useCurrentSession ↔ quiescence.
            await authSessionCoordinator.completeInvalidatedLogout(invalidation)
        }
        await orchestrator.awaitAutomationQuiescence(transition)
        await significantLocationMonitor.stop()
        await geofenceRegionManager?.unregisterAll()
#if DEBUG
        await BackgroundValidationHarness.shared.stop()
        await BackgroundValidationRecorder.shared.clear()
#endif
        await evaluationJournal.clear()
        activityLog?.clear()
        await offlineQueue.clear()
        securePasswordStore.clearAll()
        await appPreferences.clearAll()
        EvaluationLog.shared.reset()
        languageCode = "pt"
        await orchestrator.endAutomationContextTransition(transition)
        await localTasks.waitForBarrierParticipants()
        destructiveContextWipeInProgress = false
    }

    // MARK: - dialogs / self-reg fields

    func openSettings() { uiState.dialogOpen = .settings }

    private func enqueueLocalPreferenceMutation(
        _ operation: @escaping () async -> Void
    ) {
        let generation = localPreferenceMutationGeneration
        let previous = localPreferenceMutationTask
        let task = Task {
            await previous?.value
            guard !Task.isCancelled,
                  generation == localPreferenceMutationGeneration else { return }
            await operation()
        }
        localPreferenceMutationTask = task
    }

    func selectLanguage(_ code: String) {
        let resolved = resolveLanguageCode(code)
        guard resolved != languageCode else { return }
        languageCode = resolved
        if let status = uiState.authStatus { uiState.prompt = resolvePrompt(status) }
        enqueueLocalPreferenceMutation {
            await self.appPreferences.setLanguage(resolved)
        }
    }

    func openAutoActivitiesDialog() {
        uiState.dialogOpen = .autoActivities
        uiState.showAutoActivitiesNudge = false
        Task { await refreshPermissionState(captureIfEligible: false) }
    }

    func dismissAutoActivitiesNudge() {
        let chave = uiState.chave
        uiState.showAutoActivitiesNudge = false
        enqueueLocalPreferenceMutation {
            await self.appPreferences.setFlag(self.nudgeFlag(chave), true)
        }
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
        enqueueLocalPreferenceMutation {
            await self.appPreferences.setBackgroundLocationConsentAt(
                ISOInstant.string(self.clock.now())
            )
            guard !Task.isCancelled else { return }
            self.activityLogger.logSystem("Background location consent granted by user.", .info)
            await self.reconcileAutomaticLocationServices()
        }
    }

    func finishPermissionReview() {
        if usesFixtureState { return }
        let remoteContext: ActiveRemoteContext?
        if uiLifecycleBehavior == .headlessGuarded {
            remoteContext = activeRemoteContext(for: uiState.chave)
            guard remoteContext != nil else { return }
        } else {
            remoteContext = nil
        }
        Task {
            await reviewPermissionsAfterActivation(
                captureIfEligible: true,
                remoteContext: remoteContext
            )
        }
    }

    /// Fonte única do ciclo dos gatilhos nativos. O fluxo normal agora arma as geofences depois do login,
    /// ao habilitar a automação, após mudanças de projeto/permissão e a cada restauração em foreground.
    /// Quando qualquer gate deixa de ser válido, ambos os serviços são removidos para evitar regiões
    /// obsoletas de outra conta/projeto.
    private func reconcileAutomaticLocationServices(
        forceGeofenceRefresh: Bool = false,
        remoteContext: ActiveRemoteContext? = nil
    ) async {
        guard isRemoteContextValid(remoteContext) else { return }
        let chave = uiState.chave
        let generation = nativeLocationServicesGeneration
        let persistedSettings = chave.count == 4
            ? await loadUserSettings(chave)
            : UserSettings(projects: [], activeProject: "", automaticActivitiesEnabled: false)
        guard isRemoteContextValid(remoteContext),
              generation == nativeLocationServicesGeneration,
              uiState.chave == chave else { return }
        let activeProject = uiState.userProjects?.activeProject ?? persistedSettings.activeProject
        guard chave.count == 4, uiState.isAuthenticated, uiState.automaticActivitiesEnabled,
              !activeProject.isEmpty else {
            await significantLocationMonitor.stop()
            guard generation == nativeLocationServicesGeneration else { return }
            await geofenceRegionManager?.unregisterAll()
            return
        }

        let storedConsent = !(await appPreferences.backgroundLocationConsentAt()).isEmpty
        guard isRemoteContextValid(remoteContext),
              generation == nativeLocationServicesGeneration,
              uiState.chave == chave,
              uiState.isAuthenticated else { return }
        let consentGranted = uiState.backgroundLocationConsentGranted || storedConsent
        let permissions = await permissionsInspector.inspect()
        guard isRemoteContextValid(remoteContext),
              generation == nativeLocationServicesGeneration,
              uiState.chave == chave,
              uiState.isAuthenticated else { return }
        uiState.permissionsStatus = permissions
        uiState.locationPermissionSufficient = permissions.preciseLocationGranted

        guard consentGranted, permissions.preciseLocationGranted else {
            await significantLocationMonitor.stop()
            guard generation == nativeLocationServicesGeneration else { return }
            await geofenceRegionManager?.unregisterAll()
            return
        }

        await significantLocationMonitor.start()
        guard isRemoteContextValid(remoteContext),
              generation == nativeLocationServicesGeneration,
              uiState.chave == chave,
              uiState.isAuthenticated,
              uiState.automaticActivitiesEnabled else { return }
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

    private func updatePersistedSettings(
        chave: String,
        generation: Int,
        _ update: (inout UserSettings) -> Void
    ) async {
        guard chave.count == 4, generation == settingsPersistenceGeneration,
              !Task.isCancelled else { return }
        let raw = await appPreferences.userSettingsJson()
        guard generation == settingsPersistenceGeneration, !Task.isCancelled else { return }
        var map = (try? JSONCoding.decoder.decode([String: UserSettings].self, from: Data(raw.utf8))) ?? [:]
        var settings = resolvePersistedUserSettings(map, chave)
        update(&settings)
        map = withPersistedUserSettings(map, chave, settings)
        guard let data = try? JSONCoding.encoder.encode(map),
              let json = String(data: data, encoding: .utf8) else { return }
        guard generation == settingsPersistenceGeneration, !Task.isCancelled else { return }
        await appPreferences.setUserSettingsJson(json)
    }

    @discardableResult
    private func enqueueSettingsUpdate(
        _ update: @escaping (inout UserSettings) -> Void
    ) -> Task<Void, Never> {
        let chave = uiState.chave
        let generation = settingsPersistenceGeneration
        let previous = settingsPersistenceTask
        let task = Task {
            await previous?.value
            guard !Task.isCancelled, generation == settingsPersistenceGeneration else { return }
            await updatePersistedSettings(
                chave: chave,
                generation: generation,
                update
            )
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
        // A edição do formulário não troca a identidade ativa nem invalida gerações parcialmente. A
        // adoção ocorre uma única vez em `submitSelfRegistration`, pela transição normal de chave.
        uiState.selfRegistrationFields.chave = sanitizeSettingsChave(value)
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
        guard !destructiveContextWipeInProgress,
              uiState.selfRegistrationFields.projectCatalog.isEmpty,
              !uiState.selfRegistrationFields.isLoadingProjects else { return }
        uiState.selfRegistrationFields.isLoadingProjects = true
        let generation = projectCatalogLoadGeneration
        projectCatalogLoadTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let result = await self.projectRepository.listProjects()
            guard !Task.isCancelled,
                  generation == self.projectCatalogLoadGeneration,
                  !self.destructiveContextWipeInProgress else { return }
            if case .success(let projects) = result {
                uiState.selfRegistrationFields.projectCatalog = projects
            }
            uiState.selfRegistrationFields.isLoadingProjects = false
            if generation == projectCatalogLoadGeneration {
                projectCatalogLoadTask = nil
            }
        }
    }

    // MARK: - SSE

    private func startCheckStream(
        _ chave: String,
        remoteContext: ActiveRemoteContext? = nil
    ) {
        if uiLifecycleBehavior == .headlessGuarded {
            guard let remoteContext,
                  isRemoteContextValid(remoteContext) else { return }
        }
        checkSseTask?.cancel()
        checkSseTask = Task { [weak self] in
            // stream obtido sem reter self além desta expressão — o loop não segura self entre eventos.
            guard !Task.isCancelled,
                  self?.isRemoteContextValid(remoteContext) == true,
                  self?.uiState.chave == chave,
                  let stream = self?.checkEventStream.events(chave: chave) else { return }
            for await _ in stream {
                guard !Task.isCancelled,
                      let self,
                      self.isRemoteContextValid(remoteContext) else { return }
                await self.refreshCheckState(
                    chave: chave,
                    remoteContext: remoteContext
                )
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
