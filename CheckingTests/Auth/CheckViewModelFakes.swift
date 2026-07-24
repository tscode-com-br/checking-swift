import Foundation
import XCTest
@testable import Checking

/// Faz poll (na MainActor, cedendo entre checagens) até a condição ou timeout — equivale ao `runCurrent`
/// do Kotlin (roda o trabalho pronto, sem cruzar o `sleep(10s)` do poll).
@MainActor
func settle(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func status(found: Bool = false, hasPassword: Bool = false, authenticated: Bool = false,
            pendingApproval: Bool = false, queueFull: Bool = false, chave: String = "NEW1") -> AuthStatus {
    AuthStatus(found: found, chave: chave, hasPassword: hasPassword, authenticated: authenticated,
               message: "m", pendingApproval: pendingApproval, queueFull: queueFull)
}

final class FakeAuthRepository: AuthRepository, @unchecked Sendable {
    var statusResults: [String: AppResult<AuthStatus>] = [:]
    var statusGates: [String: AsyncGate] = [:]     // se setado p/ a chave, getStatus trava até release()
    var loginResults: [String: AppResult<AuthStatus>] = [:]
    var selfRegisterResult: AppResult<AuthStatus> = .failure(.unknown(description: nil))
    var registerPasswordResult: AppResult<AuthStatus> = .failure(.unknown(description: nil))
    var changePasswordResult: AppResult<AuthStatus> = .failure(.unknown(description: nil))
    var logoutResult: AppResult<Void> = .success(())
    var deleteResult: AppResult<Void> = .success(())
    var historyResult: AppResult<HistoryState> = .failure(.unknown(description: nil))

    private let lock = NSLock()
    private var recordedLogins: [(chave: String, password: String)] = []
    private var getHistoryCount = 0
    var loginCalls: [(chave: String, password: String)] { lock.withLock { recordedLogins } }
    var getHistoryCallCount: Int { lock.withLock { getHistoryCount } }

    func getStatus(_ chave: String) async -> AppResult<AuthStatus> {
        if let gate = statusGates[chave] { await gate.wait() }
        return statusResults[chave] ?? .failure(.unknown(description: nil))
    }
    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus> {
        lock.withLock { recordedLogins.append((chave, password)) }
        return loginResults[chave] ?? .failure(.unknown(description: nil))
    }
    func logout() async -> AppResult<Void> { logoutResult }
    func deleteAccount() async -> AppResult<Void> { deleteResult }
    func registerPassword(_ chave: String, _ project: String?, _ password: String) async -> AppResult<AuthStatus> { registerPasswordResult }
    func changePassword(_ chave: String, _ oldPassword: String, _ newPassword: String) async -> AppResult<AuthStatus> { changePasswordResult }
    func selfRegister(_ chave: String, _ nome: String, _ projetos: [String], _ email: String?, _ password: String, _ confirmPassword: String) async -> AppResult<AuthStatus> { selfRegisterResult }
    func getHistory(_ chave: String) async -> AppResult<HistoryState> { lock.withLock { getHistoryCount += 1 }; return historyResult }
}

final class FakeProjectRepository: ProjectRepository, @unchecked Sendable {
    var result: AppResult<[Project]> = .success([])
    var userProjectsResult: AppResult<UserProjects> = .success(UserProjects(projects: ["P80"], activeProject: "P80"))
    var updateUserProjectsResult: AppResult<UserProjects>?
    private(set) var updateUserProjectsCalls: [[String]] = []
    func listProjects() async -> AppResult<[Project]> { result }
    func getUserProjects() async -> AppResult<UserProjects> { userProjectsResult }
    func updateUserProjects(_ projectNames: [String]) async -> AppResult<UserProjects> {
        updateUserProjectsCalls.append(projectNames)
        return updateUserProjectsResult ?? .success(UserProjects(projects: projectNames, activeProject: projectNames.first ?? ""))
    }
    func updateActiveProject(_ projectName: String) async -> AppResult<UserProjects> {
        .success(UserProjects(projects: [projectName], activeProject: projectName))
    }
}

final class SpyOrchestrator: OrchestratorRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [OrchestratorTrigger] = []
    var runOnceCalls: [OrchestratorTrigger] { lock.withLock { calls } }
    func runOnce(_ trigger: OrchestratorTrigger) async { lock.withLock { calls.append(trigger) } }
}

final class SpySecurePasswordStore: SecurePasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]
    private var recordedSets: [(chave: String, password: String)] = []
    var setPasswordCalls: [(chave: String, password: String)] { lock.withLock { recordedSets } }

    func seed(_ chave: String, _ password: String) { lock.withLock { stored[sanitizeSettingsChave(chave)] = password } }
    func getPassword(_ chave: String) -> String { lock.withLock { stored[sanitizeSettingsChave(chave)] ?? "" } }
    func setPassword(_ chave: String, _ password: String) {
        lock.withLock { recordedSets.append((chave, password)); stored[sanitizeSettingsChave(chave)] = password }
    }
    func removePassword(_ chave: String) { lock.withLock { stored.removeValue(forKey: sanitizeSettingsChave(chave)) } }
    func getAllPasswords() -> [String: String] { lock.withLock { stored } }
    func clearAll() { lock.withLock { stored.removeAll() } }
}

struct NoopCheckEventStream: CheckEventStreaming {
    func events(chave: String) -> AsyncStream<String> { AsyncStream { $0.finish() } }
}

actor SpySignificantLocationMonitor: SignificantLocationMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var active = false
    func start() { startCount += 1; active = true }
    func stop() { stopCount += 1; active = false }
    func isActive() -> Bool { active }
}

actor SpyGeofenceRegionManager: GeofenceRegionManaging {
    private(set) var registrations: [(chave: String, hints: GeofencePriorityHints, forceRefresh: Bool)] = []
    private(set) var unregisterCount = 0

    func register(chave: String, hints: GeofencePriorityHints, forceRefresh: Bool) {
        registrations.append((chave, hints, forceRefresh))
    }

    func unregisterAll() {
        unregisterCount += 1
    }
}

/// Harness dos testes do ViewModel — configure os fakes/prefs, depois `build()`.
@MainActor
final class VMHarness {
    let suiteName = "vm_\(UUID().uuidString)"
    lazy var prefs = UserDefaultsPreferencesStore(defaults: UserDefaults(suiteName: suiteName)!)
    let auth = FakeAuthRepository()
    let projects = FakeProjectRepository()
    let orchestrator = SpyOrchestrator()
    let significantLocationMonitor = SpySignificantLocationMonitor()
    let geofenceRegionManager = SpyGeofenceRegionManager()
    let passwords = SpySecurePasswordStore()
    let checkRepository = FakeCheckRepository()
    let captureLocation = FakeCaptureLocation(.noPermission)
    let offlineQueue = FakeOfflineQueue()
    let activityLog = ActivityLog(dao: CoreDataActivityLogDao(stack: CoreDataStack(inMemory: true)))
    var permissions = PermissionsStatus(
        locationAuthorization: .always, preciseAccuracy: true, cameraMicGranted: true,
        notificationAuthorization: .authorized, lowPowerMode: false, backgroundRefresh: .available)

    func build() -> CheckViewModel {
        CheckViewModel(appPreferences: prefs, securePasswordStore: passwords, authRepository: auth,
                       projectRepository: projects, checkRepository: checkRepository,
                       captureLocationUseCase: captureLocation, offlineQueue: offlineQueue,
                       permissionsInspector: StaticPermissionsInspector(status: permissions), orchestrator: orchestrator,
                       significantLocationMonitor: significantLocationMonitor,
                       checkEventStream: NoopCheckEventStream(), activityLogger: NoopActivityLogger(),
                       clock: FixedClock(Date(timeIntervalSince1970: 0)), activityLog: activityLog,
                       geofenceRegionManager: geofenceRegionManager)
    }
    func teardown() { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
}

struct StaticPermissionsInspector: PermissionsInspecting {
    let status: PermissionsStatus
    func inspect() async -> PermissionsStatus { status }
}
