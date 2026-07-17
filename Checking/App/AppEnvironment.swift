import SwiftUI

/// Raiz de composição de dependências (plano §6/§7). Não há singleton global mutável como fonte de
/// verdade. Repositórios/serviços são adicionados aqui à medida que cada port spec é implementada.
public struct AppEnvironment: Sendable {
    public let clock: any Clock
    public let apiConfig: ApiConfig
    // Tipos internos (single-module) → a init é internal. Ver port_spec_network_contracts.
    let sessionCookieStore: any SessionCookieStore
    let checkRepository: any CheckRepository
    let offlineQueue: OfflineCheckQueue           // durabilidade do exactly-once (§ offline/replay)
    let activityLogger: ActivityLogger            // log crash-proof sobre Core Data (§ persistência)
    let networkMonitor: any NetworkMonitoring     // NWPathMonitor (§ background)
    let checkEventStream: CheckEventStream        // SSE ao vivo compartilhado
    let offlineSyncCoordinator: OfflineSyncCoordinator  // drena a fila ao reconectar
    let authRepository: any AuthRepository        // login/status/self-register/delete (§ auth)
    let appPreferences: any AppPreferencesStore   // chave/settings/flags — fonte que o orquestrador lê
    let securePasswordStore: any SecurePasswordStore  // senha por-chave (Keychain real vem no slice de segurança)
    let accidentRepository: any AccidentRepository     // acidente+vídeo; também satisfaz o seam do orquestrador
    let projectRepository: any ProjectRepository        // catálogo + projetos do usuário; satisfaz o seam do CheckViewModel
    let orchestrator: BackgroundCheckOrchestrator       // actor — os 7 passos; localização real (CLLocationManager)
    let geofenceRegionManager: GeofenceRegionManager    // arma/reconcilia geofences (cap 20 + priorização)
    let permissionsInspector: any PermissionsInspecting // lê o estado vivo de permissões (escada + painel)
    let settingsOpener: any SettingsOpening             // abre a página de Ajustes do app (único destino iOS)

    // TODO (à medida que as camadas forem implementadas — ver docs/port_spec_*.md):
    //   transportRepository,
    //   checkViewModel/accidentViewModel (@MainActor — montagem fica na camada de UI, ainda não construída),
    //   tela SwiftUI do painel de integridade + fluxo de REQUISIÇÃO da escada (slice de UI — fidelidade ao
    //   AutoActivitiesDialog.kt); coletor async do HealthReport (assembla inspector+geofence+fila+prefs).

    init(clock: any Clock, apiConfig: ApiConfig, sessionCookieStore: any SessionCookieStore,
         checkRepository: any CheckRepository, offlineQueue: OfflineCheckQueue, activityLogger: ActivityLogger,
         networkMonitor: any NetworkMonitoring, checkEventStream: CheckEventStream,
         offlineSyncCoordinator: OfflineSyncCoordinator, authRepository: any AuthRepository,
         appPreferences: any AppPreferencesStore, securePasswordStore: any SecurePasswordStore,
         accidentRepository: any AccidentRepository, projectRepository: any ProjectRepository,
         orchestrator: BackgroundCheckOrchestrator, geofenceRegionManager: GeofenceRegionManager,
         permissionsInspector: any PermissionsInspecting, settingsOpener: any SettingsOpening) {
        self.clock = clock
        self.apiConfig = apiConfig
        self.sessionCookieStore = sessionCookieStore
        self.checkRepository = checkRepository
        self.offlineQueue = offlineQueue
        self.activityLogger = activityLogger
        self.networkMonitor = networkMonitor
        self.checkEventStream = checkEventStream
        self.offlineSyncCoordinator = offlineSyncCoordinator
        self.authRepository = authRepository
        self.appPreferences = appPreferences
        self.securePasswordStore = securePasswordStore
        self.accidentRepository = accidentRepository
        self.projectRepository = projectRepository
        self.orchestrator = orchestrator
        self.geofenceRegionManager = geofenceRegionManager
        self.permissionsInspector = permissionsInspector
        self.settingsOpener = settingsOpener
    }

    /// Composição viva do app em execução — monta a stack real (rede + persistência + gatilhos de background).
    public static func live() -> AppEnvironment {
        let clock = SystemClock()
        let apiConfig = ApiConfig.fromBundle()
        let cookieStore = InMemorySessionCookieStore()
        let http = URLSessionHTTPClient(baseURL: apiConfig.baseURL, xClient: apiConfig.xClient, cookieStore: cookieStore)
        let checkApi = CheckApiLive(http: http)
        let checkRepository = CheckRepositoryLive(api: checkApi, clock: clock)
        let activityLogger = ActivityLogger(clock: clock, activityLog: ActivityLog(dao: CoreDataActivityLogDao(stack: CoreDataStack())))
        // Fila offline durável, agendada por BGTask; drenada ao reconectar (NWPathMonitor) e no enqueue-online.
        let syncScheduler = BGTaskSyncScheduler()
        let offlineQueue = OfflineCheckQueue(store: InMemoryOfflineQueueStore(), scheduler: syncScheduler)
        let networkMonitor = NWPathMonitorNetworkMonitor()
        let replayer = PendingCheckReplayer(queue: offlineQueue, repository: checkRepository, logger: activityLogger)
        let offlineSyncCoordinator = OfflineSyncCoordinator(replayer: replayer, monitor: networkMonitor)
        syncScheduler.setDrainTrigger { [offlineSyncCoordinator] in Task { await offlineSyncCoordinator.triggerDrain() } }
        // SSE ao vivo compartilhado: reconexão sobre URLSession.bytes, re-chaveada por chave.
        let sseConnection = URLSessionSSEConnection(xClient: apiConfig.xClient, cookieStore: cookieStore)
        let checkEventStream = CheckEventStream(makeStream: { [apiConfig, sseConnection, networkMonitor] chave in
            var components = URLComponents(url: apiConfig.baseURL.appendingPathComponent("check/stream"), resolvingAgainstBaseURL: false)!
            components.percentEncodedQuery = percentEncodedQuery(["chave": chave])
            return reconnectingSSE(url: components.url!, source: sseConnection, networkMonitor: networkMonitor)
        })
        // Auth: repo real + prefs (UserDefaults) + senha (Keychain real vem no slice de segurança).
        let authApi = AuthApiLive(http: http)
        let authRepository = AuthRepositoryLive(api: authApi, checkRepository: checkRepository, cookieStore: cookieStore)
        let appPreferences = UserDefaultsPreferencesStore()
        let securePasswordStore = InMemorySecurePasswordStore()
        // Acidente+vídeo: mesma stack HTTP + a MESMA conexão SSE compartilhada (/check/stream) do módulo Check.
        let accidentApi = AccidentApiLive(http: http)
        let accidentRepository = AccidentRepositoryLive(api: accidentApi, checkEventStream: checkEventStream)
        // Catálogo de projetos + projetos do usuário — mesma stack HTTP.
        let projectsApi = ProjectsApiLive(http: http)
        let projectRepository = ProjectRepositoryLive(api: projectsApi)
        // Orquestrador de background: notificações reais (UNUserNotificationCenter); localização real
        // (CLLocationManager "15s melhor-fix"). Geofence region-monitoring segue no slice de localização/permissões.
        let notifications = AutoActivityNotificationsLive()
        let locationProvider = CLLocationManagerLocationProvider()
        let captureLocation = CaptureLocationUseCase(locationProvider: locationProvider,
                                                      checkRepository: checkRepository, activityLogger: activityLogger)
        let runAutomaticActivities = RunAutomaticActivitiesUseCase(captureLocationUseCase: captureLocation,
                                                                    checkRepository: checkRepository, offlineQueue: offlineQueue,
                                                                    clock: clock, activityLogger: activityLogger)
        // `backgroundTaskGuard`/`pauseAlarms` ficam nos defaults `Noop*` (não passados abaixo) — mesmo em
        // produção. Placeholder deliberado: `beginBackgroundTask` real (§9 "wake lock") e o alarme de
        // pausa ficam para quando houver um trigger real (.foreground/.geofence) que precise deles; hoje
        // só `.timer` roda, já dentro da janela do próprio BGTask.
        let orchestrator = BackgroundCheckOrchestrator(
            appPrefs: appPreferences, checkRepository: checkRepository, runAutomaticActivities: runAutomaticActivities,
            locationProvider: locationProvider, clock: clock, authRepository: authRepository,
            securePasswordStore: securePasswordStore, accidentRepository: accidentRepository,
            activityLogger: activityLogger, notifications: notifications)
        // Geofence region-monitoring: o monitor real acorda o orquestrador (`runOnce(.geofence)`) em cada
        // travessia; o manager busca/prioriza/arma (cap 20). Registro real dispara no foreground/login (Camada
        // D) quando a UI existir — o gatilho já está pronto para plugar.
        let geofenceMonitor = CLLocationManagerGeofenceMonitor(
            activityLogger: activityLogger,
            onGeofenceWake: { [orchestrator] in Task { await orchestrator.runOnce(.geofence) } })
        let geofenceRegionManager = GeofenceRegionManager(
            checkRepository: checkRepository, monitor: geofenceMonitor, activityLogger: activityLogger)
        return AppEnvironment(clock: clock, apiConfig: apiConfig, sessionCookieStore: cookieStore,
                              checkRepository: checkRepository, offlineQueue: offlineQueue, activityLogger: activityLogger,
                              networkMonitor: networkMonitor, checkEventStream: checkEventStream,
                              offlineSyncCoordinator: offlineSyncCoordinator, authRepository: authRepository,
                              appPreferences: appPreferences, securePasswordStore: securePasswordStore,
                              accidentRepository: accidentRepository, projectRepository: projectRepository,
                              orchestrator: orchestrator, geofenceRegionManager: geofenceRegionManager,
                              permissionsInspector: PermissionsInspectorLive(), settingsOpener: UIKitSettingsOpener())
    }

    /// Composição inerte para previews e testes (repositório stub, Core Data in-memory, sem rede/gatilhos).
    public static let preview: AppEnvironment = {
        let cookieStore = InMemorySessionCookieStore()
        let checkRepository = PreviewCheckRepository()
        let offlineQueue = OfflineCheckQueue(store: InMemoryOfflineQueueStore(), scheduler: NoopSyncScheduler())
        let activityLogger = ActivityLogger(clock: SystemClock(),
                                            activityLog: ActivityLog(dao: CoreDataActivityLogDao(stack: CoreDataStack(inMemory: true))))
        let monitor = StaticNetworkMonitor(online: true)
        let replayer = PendingCheckReplayer(queue: offlineQueue, repository: checkRepository, logger: activityLogger)
        let previewPrefsSuite = "br.com.tscode.checking.preview.\(UUID().uuidString)"
        let previewPrefs = UserDefaultsPreferencesStore(defaults: UserDefaults(suiteName: previewPrefsSuite) ?? .standard)
        let previewSecurePasswordStore = InMemorySecurePasswordStore()
        let previewAuthRepository = PreviewAuthRepository()
        let previewAccidentRepository = PreviewAccidentRepository()
        let previewClock = SystemClock()
        let locationProvider = UnavailableLocationProvider()
        let captureLocation = CaptureLocationUseCase(locationProvider: locationProvider,
                                                      checkRepository: checkRepository, activityLogger: activityLogger)
        let runAutomaticActivities = RunAutomaticActivitiesUseCase(captureLocationUseCase: captureLocation,
                                                                    checkRepository: checkRepository, offlineQueue: offlineQueue,
                                                                    clock: previewClock, activityLogger: activityLogger)
        let orchestrator = BackgroundCheckOrchestrator(
            appPrefs: previewPrefs, checkRepository: checkRepository, runAutomaticActivities: runAutomaticActivities,
            locationProvider: locationProvider, clock: previewClock, authRepository: previewAuthRepository,
            securePasswordStore: previewSecurePasswordStore, accidentRepository: previewAccidentRepository,
            activityLogger: activityLogger, notifications: PreviewAutoActivityNotifications())
        let geofenceRegionManager = GeofenceRegionManager(
            checkRepository: checkRepository, monitor: NoopGeofenceRegionMonitor(), activityLogger: activityLogger)
        return AppEnvironment(
            clock: previewClock, apiConfig: .preview, sessionCookieStore: cookieStore,
            checkRepository: checkRepository, offlineQueue: offlineQueue, activityLogger: activityLogger,
            networkMonitor: monitor,
            checkEventStream: CheckEventStream(makeStream: { _ in AsyncStream { $0.finish() } }),
            offlineSyncCoordinator: OfflineSyncCoordinator(replayer: replayer, monitor: monitor),
            authRepository: previewAuthRepository,
            appPreferences: previewPrefs,
            securePasswordStore: previewSecurePasswordStore,
            accidentRepository: previewAccidentRepository,
            projectRepository: PreviewProjectRepository(),
            orchestrator: orchestrator, geofenceRegionManager: geofenceRegionManager,
            permissionsInspector: PreviewPermissionsInspector(), settingsOpener: PreviewSettingsOpener())
    }()
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
