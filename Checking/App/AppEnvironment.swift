import SwiftUI

/// Raiz de composição de dependências (plano §6/§7). Não há singleton global mutável como fonte de
/// verdade. Repositórios/serviços são adicionados aqui à medida que cada port spec é implementada.
public struct AppEnvironment: Sendable {
    public let clock: any Clock
    public let apiConfig: ApiConfig
    public let backgroundReliabilityProfile: BackgroundReliabilityProfile
    let evaluationJournal: any EvaluationJournaling
    let evaluationApplicationStateStore: EvaluationApplicationStateStore
    // Tipos internos (single-module) → a init é internal. Ver port_spec_network_contracts.
    let sessionCookieStore: any SessionCookieStore
    let checkRepository: any CheckRepository
    let offlineQueue: OfflineCheckQueue           // durabilidade do exactly-once (§ offline/replay)
    let activityLog: ActivityLog                  // store paginável exibido em Ajustes › Atividades
    let activityLogger: ActivityLogger            // log crash-proof sobre Core Data (§ persistência)
    let networkMonitor: any NetworkMonitoring     // NWPathMonitor (§ background)
    let checkEventStream: CheckEventStream        // SSE ao vivo compartilhado
    let offlineSyncCoordinator: OfflineSyncCoordinator  // drena a fila ao reconectar
    let backgroundProcessingScheduler: BGTaskSyncScheduler // submit-only para o terminal do BGProcessing
    let authRepository: any AuthRepository        // login/status/self-register/delete (§ auth)
    let authSessionCoordinator: any AuthSessionCoordinating // autoridade serial compartilhada UI/background
    let appPreferences: any AppPreferencesStore   // chave/settings/flags — fonte que o orquestrador lê
    let securePasswordStore: any SecurePasswordStore  // senha por-chave (Keychain real vem no slice de segurança)
    let accidentRepository: any AccidentRepository     // acidente+vídeo; também satisfaz o seam do orquestrador
    let accidentVideoUploader: BackgroundAccidentVideoUploader?
    let projectRepository: any ProjectRepository        // catálogo + projetos do usuário; satisfaz o seam do CheckViewModel
    let captureLocationUseCase: any LocationCapturing   // captura+match compartilhados por UI e motor automático
    let orchestrator: BackgroundCheckOrchestrator       // actor — os 7 passos; localização real (CLLocationManager)
    let appRefreshScheduler: any AppRefreshScheduling   // único BGAppRefresh: regular + precisão + pausa
    let geofenceRegionManager: GeofenceRegionManager    // arma/reconcilia geofences (cap 20 + priorização)
    let significantLocationMonitor: any SignificantLocationMonitoring // fallback de movimento amplo (§9.3)
    let permissionsInspector: any PermissionsInspecting // lê o estado vivo de permissões (escada + painel)
    let settingsOpener: any SettingsOpening             // abre a página de Ajustes do app (único destino iOS)

    // TODO (à medida que as camadas forem implementadas — ver docs/port_spec_*.md):
    //   transportRepository,
    //   checkViewModel/accidentViewModel (@MainActor — montagem fica na camada de UI, ainda não construída),
    //   tela SwiftUI do painel de integridade + fluxo de REQUISIÇÃO da escada (slice de UI — fidelidade ao
    //   AutoActivitiesDialog.kt); coletor async do HealthReport (assembla inspector+geofence+fila+prefs).

    init(clock: any Clock, apiConfig: ApiConfig, backgroundReliabilityProfile: BackgroundReliabilityProfile,
         evaluationJournal: any EvaluationJournaling,
         evaluationApplicationStateStore: EvaluationApplicationStateStore,
         sessionCookieStore: any SessionCookieStore,
         checkRepository: any CheckRepository, offlineQueue: OfflineCheckQueue, activityLog: ActivityLog,
         activityLogger: ActivityLogger,
         networkMonitor: any NetworkMonitoring, checkEventStream: CheckEventStream,
         offlineSyncCoordinator: OfflineSyncCoordinator,
         backgroundProcessingScheduler: BGTaskSyncScheduler,
         authRepository: any AuthRepository,
         authSessionCoordinator: any AuthSessionCoordinating,
         appPreferences: any AppPreferencesStore, securePasswordStore: any SecurePasswordStore,
         accidentRepository: any AccidentRepository, accidentVideoUploader: BackgroundAccidentVideoUploader? = nil,
         projectRepository: any ProjectRepository,
         captureLocationUseCase: any LocationCapturing,
         orchestrator: BackgroundCheckOrchestrator, appRefreshScheduler: any AppRefreshScheduling,
         geofenceRegionManager: GeofenceRegionManager,
         significantLocationMonitor: any SignificantLocationMonitoring,
         permissionsInspector: any PermissionsInspecting, settingsOpener: any SettingsOpening) {
        self.clock = clock
        self.apiConfig = apiConfig
        self.backgroundReliabilityProfile = backgroundReliabilityProfile
        self.evaluationJournal = evaluationJournal
        self.evaluationApplicationStateStore = evaluationApplicationStateStore
        self.sessionCookieStore = sessionCookieStore
        self.checkRepository = checkRepository
        self.offlineQueue = offlineQueue
        self.activityLog = activityLog
        self.activityLogger = activityLogger
        self.networkMonitor = networkMonitor
        self.checkEventStream = checkEventStream
        self.offlineSyncCoordinator = offlineSyncCoordinator
        self.backgroundProcessingScheduler = backgroundProcessingScheduler
        self.authRepository = authRepository
        self.authSessionCoordinator = authSessionCoordinator
        self.appPreferences = appPreferences
        self.securePasswordStore = securePasswordStore
        self.accidentRepository = accidentRepository
        self.accidentVideoUploader = accidentVideoUploader
        self.projectRepository = projectRepository
        self.captureLocationUseCase = captureLocationUseCase
        self.orchestrator = orchestrator
        self.appRefreshScheduler = appRefreshScheduler
        self.geofenceRegionManager = geofenceRegionManager
        self.significantLocationMonitor = significantLocationMonitor
        self.permissionsInspector = permissionsInspector
        self.settingsOpener = settingsOpener
    }

    /// Composição viva do app em execução — monta a stack real (rede + persistência + gatilhos de background).
    @MainActor
    public static func live() -> AppEnvironment {
        let backgroundReliabilityProfile = BackgroundReliabilityProfile.fromBundle()
        let clock = SystemClock()
        let evaluationApplicationStateStore = EvaluationApplicationStateStore()
        let evaluationJournal: any EvaluationJournaling
        if let fileURL = DurableEvaluationJournal.liveFileURL() {
            evaluationJournal = DurableEvaluationJournal(
                fileURL: fileURL,
                clock: clock,
                processID: EvaluationProcessID()
            )
        } else {
            AppLog.background.error("Evaluation journal disabled: Application Support unavailable.")
            evaluationJournal = NoopEvaluationJournal()
        }
        let apiConfig = ApiConfig.fromBundle()
        let cookieStore = KeychainSessionCookieStore()
        let http = URLSessionHTTPClient(baseURL: apiConfig.baseURL, xClient: apiConfig.xClient, cookieStore: cookieStore)
        let checkApi = CheckApiLive(http: http)
        let checkRepository = CheckRepositoryLive(api: checkApi, clock: clock)
        let activityLog = ActivityLog(dao: CoreDataActivityLogDao(stack: CoreDataStack()))
        let activityLogger = ActivityLogger(clock: clock, activityLog: activityLog)
        // Fila offline durável, agendada por BGTask; drenada ao reconectar (NWPathMonitor) e no enqueue-online.
        let syncScheduler = BGTaskSyncScheduler()
        let offlineQueue = OfflineCheckQueue(store: EncryptedOfflineQueueStore(), scheduler: syncScheduler)
        let networkMonitor = NWPathMonitorNetworkMonitor()
        // SSE ao vivo compartilhado: reconexão sobre URLSession.bytes, re-chaveada por chave.
        let sseConnection = URLSessionSSEConnection(xClient: apiConfig.xClient, cookieStore: cookieStore)
        let checkEventStream = CheckEventStream(makeStream: { [apiConfig, sseConnection, networkMonitor] chave in
            var components = URLComponents(url: apiConfig.baseURL.appendingPathComponent("check/stream"), resolvingAgainstBaseURL: false)!
            components.percentEncodedQuery = percentEncodedQuery(["chave": chave])
            return reconnectingSSE(url: components.url!, source: sseConnection, networkMonitor: networkMonitor)
        })
        // Auth: repo real + prefs (UserDefaults) + senha/cookie no Keychain, legíveis após 1º desbloqueio.
        let authApi = AuthApiLive(http: http)
        let authRepository = AuthRepositoryLive(api: authApi, checkRepository: checkRepository, cookieStore: cookieStore)
        let appPreferences = UserDefaultsPreferencesStore()
        let securePasswordStore = KeychainSecurePasswordStore()
        let authSessionCoordinator = AuthSessionCoordinator(
            authRepository: authRepository,
            securePasswordStore: securePasswordStore,
            cookieStore: cookieStore)
        // Acidente+vídeo: mesma stack HTTP + a MESMA conexão SSE compartilhada (/check/stream) do módulo Check.
        let accidentApi = AccidentApiLive(http: http)
        let accidentVideoUploader = BackgroundAccidentVideoUploader(
            baseURL: apiConfig.baseURL,
            xClient: apiConfig.xClient,
            cookieStore: cookieStore)
        accidentVideoUploader.activate()
        let accidentRepository = AccidentRepositoryLive(
            api: accidentApi,
            checkEventStream: checkEventStream,
            videoUploader: accidentVideoUploader)
        // Catálogo de projetos + projetos do usuário — mesma stack HTTP.
        let projectsApi = ProjectsApiLive(http: http)
        let projectRepository = ProjectRepositoryLive(api: projectsApi)
        // Orquestrador de background: notificações reais (UNUserNotificationCenter); localização real
        // (CLLocationManager "15s melhor-fix"). Geofence region-monitoring segue no slice de localização/permissões.
        let notifications = AutoActivityNotificationsLive()
        let pauseAlarms = LocalNotificationPauseAlarmScheduler()
        let appRefreshScheduler = BGTaskAppRefreshScheduler()
        let locationProvider = CLLocationManagerLocationProvider(
            behavior: backgroundReliabilityProfile.locationCaptureBehavior
        )
        let captureLocationBase = CaptureLocationUseCase(
            locationProvider: locationProvider,
            checkRepository: checkRepository,
            activityLogger: activityLogger,
            clock: clock,
            captureBehavior: backgroundReliabilityProfile.locationCaptureBehavior)
        let captureLocation = CoalescingLocationCapture(base: captureLocationBase)
        let runAutomaticActivities = RunAutomaticActivitiesUseCase(captureLocationUseCase: captureLocation,
                                                                    checkRepository: checkRepository, offlineQueue: offlineQueue,
                                                                    clock: clock, activityLogger: activityLogger)
        let backgroundTaskProtection = UIKitBackgroundTaskGuard()
        // Um prazo UIKit protege a conclusão de avaliações que começaram enquanto o app ainda estava ativo.
        // Ele não promete execução contínua e não substitui geofence/BGTask/APNs.
        let orchestrator = BackgroundCheckOrchestrator(
            appPrefs: appPreferences, checkRepository: checkRepository, runAutomaticActivities: runAutomaticActivities,
            locationProvider: locationProvider, clock: clock,
            authSessionCoordinator: authSessionCoordinator,
            accidentRepository: accidentRepository,
            activityLogger: activityLogger, notifications: notifications,
            automaticEvaluationPipeline: backgroundReliabilityProfile.operationalPipeline,
            applicationStateProvider: evaluationApplicationStateStore,
            evaluationJournal: evaluationJournal,
            backgroundTaskGuard: backgroundTaskProtection,
            backgroundExecutionLeasing: backgroundTaskProtection,
            pauseAlarms: pauseAlarms,
            appRefreshScheduler: appRefreshScheduler)
        let replayer = PendingCheckReplayer(
            queue: offlineQueue,
            repository: checkRepository,
            logger: activityLogger,
            acceptedCheckObserver: orchestrator)
        let offlineSyncCoordinator = OfflineSyncCoordinator(replayer: replayer, monitor: networkMonitor)
        syncScheduler.setDrainTrigger {
            [offlineSyncCoordinator] in Task { await offlineSyncCoordinator.triggerDrain() }
        }
        // O perfil publicado mantém o handler legado. Só o candidato usa o adapter geracional, que troca
        // IDs físicos opacos por geração e separa requested de confirmed; os dois nunca coexistem sobre o
        // mesmo `CLLocationManager`/conjunto nativo.
        let geofenceWake: @Sendable () -> Void = { [orchestrator] in
            Task { _ = await orchestrator.evaluationTicket(.geofence) }
        }
        let geofenceMonitor: any GeofenceRegionMonitoring
        switch backgroundReliabilityProfile.operationalPipeline {
        case .legacy:
            geofenceMonitor = CLLocationManagerGeofenceMonitor(
                activityLogger: activityLogger,
                onGeofenceWake: geofenceWake
            )
        case .candidate:
            geofenceMonitor = GenerationAwareCLLocationManagerGeofenceMonitor(
                activityLogger: activityLogger,
                onGeofenceWake: geofenceWake
            )
        }
        let geofenceRegionManager = GeofenceRegionManager(
            checkRepository: checkRepository, monitor: geofenceMonitor, activityLogger: activityLogger)
        // Mudanças significativas: restaura imediatamente quando o usuário já consentiu e o automático está
        // elegível. O manager/delegate existe mesmo com o serviço parado, evitando perder o primeiro callback
        // no relançamento frio (a mesma classe de falha corrigida no monitor de geofence).
        let significantLocationMonitor = CLLocationManagerSignificantChangeMonitor(
            activityLogger: activityLogger,
            startsImmediately: appPreferences.shouldStartSignificantLocationMonitoringAtLaunch(),
            clock: clock,
            onSignificantLocationWake: { [orchestrator] seedCandidate in
                Task {
                    _ = await orchestrator.evaluationTicket(
                        .significantLocation,
                        seedCandidate: seedCandidate
                    )
                }
            })
        return AppEnvironment(clock: clock, apiConfig: apiConfig,
                              backgroundReliabilityProfile: backgroundReliabilityProfile,
                              evaluationJournal: evaluationJournal,
                              evaluationApplicationStateStore: evaluationApplicationStateStore,
                              sessionCookieStore: cookieStore,
                              checkRepository: checkRepository, offlineQueue: offlineQueue, activityLog: activityLog,
                              activityLogger: activityLogger,
                              networkMonitor: networkMonitor, checkEventStream: checkEventStream,
                              offlineSyncCoordinator: offlineSyncCoordinator,
                              backgroundProcessingScheduler: syncScheduler,
                              authRepository: authRepository,
                              authSessionCoordinator: authSessionCoordinator,
                              appPreferences: appPreferences, securePasswordStore: securePasswordStore,
                              accidentRepository: accidentRepository, accidentVideoUploader: accidentVideoUploader,
                              projectRepository: projectRepository,
                              captureLocationUseCase: captureLocation,
                              orchestrator: orchestrator, appRefreshScheduler: appRefreshScheduler,
                              geofenceRegionManager: geofenceRegionManager,
                              significantLocationMonitor: significantLocationMonitor,
                              permissionsInspector: PermissionsInspectorLive(), settingsOpener: UIKitSettingsOpener())
    }

    /// Composição inerte para previews e testes (repositório stub, Core Data in-memory, sem rede/gatilhos).
    public static let preview = makePreview()

    static func makePreview(
        backgroundReliabilityProfile: BackgroundReliabilityProfile = .legacyWithDiagnostics,
        evaluationJournal: any EvaluationJournaling = NoopEvaluationJournal()
    ) -> AppEnvironment {
        let cookieStore = InMemorySessionCookieStore()
        let checkRepository = PreviewCheckRepository()
        let offlineQueue = OfflineCheckQueue(store: InMemoryOfflineQueueStore(), scheduler: NoopSyncScheduler())
        let activityLog = ActivityLog(dao: CoreDataActivityLogDao(stack: CoreDataStack(inMemory: true)))
        let activityLogger = ActivityLogger(clock: SystemClock(), activityLog: activityLog)
        let monitor = StaticNetworkMonitor(online: true)
        let previewPrefsSuite = "br.com.tscode.checking.preview.\(UUID().uuidString)"
        let previewPrefs = UserDefaultsPreferencesStore(defaults: UserDefaults(suiteName: previewPrefsSuite) ?? .standard)
        let previewSecurePasswordStore = InMemorySecurePasswordStore()
        let previewAuthRepository = PreviewAuthRepository()
        let previewAccidentRepository = PreviewAccidentRepository()
        let previewClock = SystemClock()
        let authSessionCoordinator = AuthSessionCoordinator(
            authRepository: previewAuthRepository,
            securePasswordStore: previewSecurePasswordStore,
            cookieStore: cookieStore)
        let evaluationApplicationStateStore = EvaluationApplicationStateStore()
        let locationProvider = UnavailableLocationProvider()
        let captureLocation = CaptureLocationUseCase(
            locationProvider: locationProvider,
            checkRepository: checkRepository,
            activityLogger: activityLogger,
            clock: previewClock,
            captureBehavior: backgroundReliabilityProfile.locationCaptureBehavior)
        let runAutomaticActivities = RunAutomaticActivitiesUseCase(captureLocationUseCase: captureLocation,
                                                                    checkRepository: checkRepository, offlineQueue: offlineQueue,
                                                                    clock: previewClock, activityLogger: activityLogger)
        let orchestrator = BackgroundCheckOrchestrator(
            appPrefs: previewPrefs, checkRepository: checkRepository, runAutomaticActivities: runAutomaticActivities,
            locationProvider: locationProvider, clock: previewClock,
            authSessionCoordinator: authSessionCoordinator,
            accidentRepository: previewAccidentRepository,
            activityLogger: activityLogger, notifications: PreviewAutoActivityNotifications(),
            automaticEvaluationPipeline: backgroundReliabilityProfile.operationalPipeline,
            applicationStateProvider: evaluationApplicationStateStore,
            evaluationJournal: evaluationJournal)
        let replayer = PendingCheckReplayer(
            queue: offlineQueue,
            repository: checkRepository,
            logger: activityLogger,
            acceptedCheckObserver: orchestrator)
        let previewSyncScheduler = BGTaskSyncScheduler()
        let geofenceRegionManager = GeofenceRegionManager(
            checkRepository: checkRepository, monitor: NoopGeofenceRegionMonitor(), activityLogger: activityLogger)
        return AppEnvironment(
            clock: previewClock, apiConfig: .preview,
            backgroundReliabilityProfile: backgroundReliabilityProfile,
            evaluationJournal: evaluationJournal,
            evaluationApplicationStateStore: evaluationApplicationStateStore,
            sessionCookieStore: cookieStore,
            checkRepository: checkRepository, offlineQueue: offlineQueue, activityLog: activityLog,
            activityLogger: activityLogger,
            networkMonitor: monitor,
            checkEventStream: CheckEventStream(makeStream: { _ in AsyncStream { $0.finish() } }),
            offlineSyncCoordinator: OfflineSyncCoordinator(replayer: replayer, monitor: monitor),
            backgroundProcessingScheduler: previewSyncScheduler,
            authRepository: previewAuthRepository,
            authSessionCoordinator: authSessionCoordinator,
            appPreferences: previewPrefs,
            securePasswordStore: previewSecurePasswordStore,
            accidentRepository: previewAccidentRepository,
            projectRepository: PreviewProjectRepository(),
            captureLocationUseCase: captureLocation,
            orchestrator: orchestrator, appRefreshScheduler: NoopAppRefreshScheduler(),
            geofenceRegionManager: geofenceRegionManager,
            significantLocationMonitor: NoopSignificantLocationMonitor(),
            permissionsInspector: PreviewPermissionsInspector(), settingsOpener: PreviewSettingsOpener())
    }
}

/// Config do backend lida do Info.plist (populado pelos .xcconfig). Ver port_spec_network_contracts §1.
public struct ApiConfig: Sendable {
    public let host: String
    public let prefix: String
    public let xClient: String

    /// `https://{host}{prefix}/` — ex.: https://tscode.com.br/api/web/
    public var baseURL: URL {
        URL(string: "https://\(host)\(prefix)/")!
    }

    public init(host: String, prefix: String, xClient: String) {
        self.host = host
        self.prefix = prefix
        self.xClient = xClient
    }

    public static func fromBundle() -> ApiConfig {
        func value(_ key: String, _ fallback: String) -> String {
            (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? fallback
        }
        return ApiConfig(
            host: value("CHECKINGApiHost", "tscode.com.br"),
            prefix: value("CHECKINGApiPrefix", "/api/web"),
            xClient: value("CHECKINGXClient", "checking-ios")
        )
    }

    public static let preview = ApiConfig(host: "tscode.com.br", prefix: "/api/web", xClient: "checking-ios")
}

/// Repositório inerte para SwiftUI previews (nenhuma chamada de rede real). Não é usado em produção.
private struct PreviewCheckRepository: CheckRepository {
    func matchLocation(_ lat: Double, _ lon: Double, _ accuracyMeters: Double?) async -> AppResult<LocationMatch> { .failure(.network) }
    func getState(_ chave: String) async -> AppResult<HistoryState> { .failure(.network) }
    func getHistory(_ chave: String) async -> AppResult<[CheckHistoryEntry]> { .success([]) }
    func getLocations() async -> AppResult<LocationOptions> { .failure(.network) }
    func getGeofences(_ chave: String) async -> AppResult<[GeofenceCircle]> { .success([]) }
    func submit(chave: String, projeto: String, action: CheckAction, local: String?, informe: InformeType,
                eventTime: Date, clientEventId: String, fillForms: Bool) async -> AppResult<HistoryState> { .failure(.network) }
}

/// Repositório de auth inerte para SwiftUI previews (nenhuma chamada de rede real). Não é usado em produção.
private struct PreviewAuthRepository: AuthRepository {
    func getStatus(_ chave: String) async -> AppResult<AuthStatus> { .failure(.network) }
    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus> { .failure(.network) }
    func logout() async -> AppResult<Void> { .success(()) }
    func deleteAccount() async -> AppResult<Void> { .failure(.network) }
    func registerPassword(_ chave: String, _ project: String?, _ password: String) async -> AppResult<AuthStatus> { .failure(.network) }
    func changePassword(_ chave: String, _ oldPassword: String, _ newPassword: String) async -> AppResult<AuthStatus> { .failure(.network) }
    func selfRegister(_ chave: String, _ nome: String, _ projetos: [String], _ email: String?, _ password: String, _ confirmPassword: String) async -> AppResult<AuthStatus> { .failure(.network) }
    func getHistory(_ chave: String) async -> AppResult<HistoryState> { .failure(.network) }
}

/// Repositório de acidente inerte para SwiftUI previews (nenhuma chamada de rede real). Não é usado em produção.
private struct PreviewAccidentRepository: AccidentRepository {
    func getState(_ chave: String) async -> AppResult<AccidentState> { .failure(.network) }
    func open(chave: String, projectId: Int, locationId: Int?, customLocationName: String?,
             zone: AccidentZone, status: AccidentSafetyStatus, description: String?) async -> AppResult<AccidentState> { .failure(.network) }
    func report(chave: String, zone: AccidentZone, status: AccidentSafetyStatus) async -> AppResult<AccidentState> { .failure(.network) }
    func acknowledge(chave: String, accidentId: Int?) async -> AppResult<AccidentState> { .failure(.network) }
    func emergencyCall(chave: String) async -> AppResult<EmergencyCallResult> { .failure(.network) }
    func uploadVideo(chave: String, idempotencyKey: String, videoFile: URL, contentType: String,
                     onProgress: @escaping @Sendable (Double) -> Void) async -> AppResult<VideoUploadResult> { .failure(.network) }
    func wizardProjects(chave: String) async -> AppResult<[WizardProject]> { .success([]) }
    func wizardLocations(chave: String, projectId: Int) async -> AppResult<[WizardLocation]> { .success([]) }
    func streamCheckEvents(chave: String) -> AsyncStream<String> { AsyncStream { $0.finish() } }
}

/// Notificações inertes para SwiftUI previews (não toca o `UNUserNotificationCenter` real). Não é usado em produção.
private struct PreviewAutoActivityNotifications: AutoActivityNotifying {
    func postAccidentNotification(lang: String) {}
    func postActivityNotification(action: CheckAction, local: String?, lang: String) {}
    func postReauthNotification(lang: String) {}
    func postScheduledPauseTransition(started: Bool, lang: String) {}
    func postLowAccuracyNotification(expectedAction: CheckAction?, lang: String) async {}
    func clearLowAccuracyNotification() async {}
}

/// Inspector de permissões inerte para SwiftUI previews (não lê o estado real do sistema). Reporta um cenário
/// "tudo concedido" — não é usado em produção.
private struct PreviewPermissionsInspector: PermissionsInspecting {
    func inspect() async -> PermissionsStatus {
        PermissionsStatus(locationAuthorization: .always, preciseAccuracy: true, cameraMicGranted: true,
                          notificationAuthorization: .authorized, lowPowerMode: false, backgroundRefresh: .available)
    }
}

/// Abridor de Ajustes inerte para previews (no-op). Não é usado em produção.
private struct PreviewSettingsOpener: SettingsOpening {
    func openAppSettings() {}
}

/// Repositório de projetos inerte para SwiftUI previews (nenhuma chamada de rede real). Não é usado em produção.
private struct PreviewProjectRepository: ProjectRepository {
    func listProjects() async -> AppResult<[Project]> { .success([]) }
    func getUserProjects() async -> AppResult<UserProjects> { .failure(.network) }
    func updateUserProjects(_ projectNames: [String]) async -> AppResult<UserProjects> { .failure(.network) }
    func updateActiveProject(_ projectName: String) async -> AppResult<UserProjects> { .failure(.network) }
}

// MARK: - SwiftUI Environment

private struct AppEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppEnvironment.preview
}

public extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
