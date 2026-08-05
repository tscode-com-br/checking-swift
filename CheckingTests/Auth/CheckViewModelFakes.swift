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
    private struct SimulatedCookieRequest: Sendable {
        let store: InMemorySessionCookieStore
        let snapshot: SessionCookieRequestSnapshot
        let value: String
    }

    private static let simulatedCookieURL =
        URL(string: "https://example.invalid/api/web/auth/login")!
    var statusResults: [String: AppResult<AuthStatus>] = [:]
    var statusGates: [String: AsyncGate] = [:]     // se setado p/ a chave, getStatus trava até release()
    var loginResults: [String: AppResult<AuthStatus>] = [:]
    var selfRegisterResult: AppResult<AuthStatus> = .failure(.unknown(description: nil))
    var registerPasswordResult: AppResult<AuthStatus> = .failure(.unknown(description: nil))
    var changePasswordResult: AppResult<AuthStatus> = .failure(.unknown(description: nil))
    var logoutResult: AppResult<Void> = .success(())
    var deleteResult: AppResult<Void> = .success(())
    var deleteGate: AsyncGate?
    var selfRegisterGate: AsyncGate?
    var registerPasswordGate: AsyncGate?
    var changePasswordGate: AsyncGate?
    var loginGates: [String: AsyncGate] = [:]
    var historyGate: AsyncGate?
    var historyResult: AppResult<HistoryState> = .failure(.unknown(description: nil))

    private let lock = NSLock()
    private var recordedStatusKeys: [String] = []
    private var recordedLogins: [(chave: String, password: String)] = []
    private var recordedSelfRegistrationKeys: [String] = []
    private var recordedLogoutCount = 0
    private var pendingLogoutGate: AsyncGate?
    private var getHistoryCount = 0
    private var deleteCount = 0
    private var authenticationResponseCookie: String?
    private var persistedSessionCookie: String?
    private var sessionCookieStore: InMemorySessionCookieStore?
    var statusCalls: [String] { lock.withLock { recordedStatusKeys } }
    var loginCalls: [(chave: String, password: String)] { lock.withLock { recordedLogins } }
    var selfRegistrationCalls: [String] {
        lock.withLock { recordedSelfRegistrationKeys }
    }
    var logoutCallCount: Int { lock.withLock { recordedLogoutCount } }
    var getHistoryCallCount: Int { lock.withLock { getHistoryCount } }
    var deleteCallCount: Int { lock.withLock { deleteCount } }
    var simulatedAuthenticationResponseCookie: String? {
        get { lock.withLock { authenticationResponseCookie } }
        set { lock.withLock { authenticationResponseCookie = newValue } }
    }
    var simulatedPersistedSessionCookie: String? {
        let values = lock.withLock { (sessionCookieStore, persistedSessionCookie) }
        return values.0?.cookieHeader(for: Self.simulatedCookieURL) ?? values.1
    }
    var nextLogoutGate: AsyncGate? {
        get { lock.withLock { pendingLogoutGate } }
        set { lock.withLock { pendingLogoutGate = newValue } }
    }

    func attachSessionCookieStore(_ store: InMemorySessionCookieStore) {
        lock.withLock { sessionCookieStore = store }
    }

    func getStatus(_ chave: String) async -> AppResult<AuthStatus> {
        lock.withLock { recordedStatusKeys.append(chave) }
        let result = statusResults[chave] ?? .failure(.unknown(description: nil))
        if let gate = statusGates[chave] { await gate.wait() }
        return result
    }
    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus> {
        lock.withLock { recordedLogins.append((chave, password)) }
        let result = loginResults[chave] ?? .failure(.unknown(description: nil))
        let cookieRequest = beginSimulatedAuthenticationRequest()
        await loginGates[chave]?.wait()
        finishSimulatedAuthenticationRequest(cookieRequest)
        return result
    }
    func logout() async -> AppResult<Void> {
        let gate = lock.withLock { () -> AsyncGate? in
            recordedLogoutCount += 1
            defer { pendingLogoutGate = nil }
            return pendingLogoutGate
        }
        await gate?.wait()
        let store = lock.withLock { () -> InMemorySessionCookieStore? in
            persistedSessionCookie = nil
            return sessionCookieStore
        }
        store?.clear()
        return logoutResult
    }
    func deleteAccount() async -> AppResult<Void> {
        lock.withLock { deleteCount += 1 }
        await deleteGate?.wait()
        if case .success = deleteResult {
            let store = lock.withLock { () -> InMemorySessionCookieStore? in
                persistedSessionCookie = nil
                return sessionCookieStore
            }
            store?.clear()
        }
        return deleteResult
    }
    func registerPassword(
        _ chave: String,
        _ project: String?,
        _ password: String
    ) async -> AppResult<AuthStatus> {
        let result = registerPasswordResult
        let cookieRequest = beginSimulatedAuthenticationRequest()
        await registerPasswordGate?.wait()
        finishSimulatedAuthenticationRequest(cookieRequest)
        return result
    }
    func changePassword(
        _ chave: String,
        _ oldPassword: String,
        _ newPassword: String
    ) async -> AppResult<AuthStatus> {
        let result = changePasswordResult
        let cookieRequest = beginSimulatedAuthenticationRequest()
        await changePasswordGate?.wait()
        finishSimulatedAuthenticationRequest(cookieRequest)
        return result
    }
    func selfRegister(_ chave: String, _ nome: String, _ projetos: [String], _ email: String?, _ password: String, _ confirmPassword: String) async -> AppResult<AuthStatus> {
        lock.withLock { recordedSelfRegistrationKeys.append(chave) }
        let cookieRequest = beginSimulatedAuthenticationRequest()
        await selfRegisterGate?.wait()
        finishSimulatedAuthenticationRequest(cookieRequest)
        return selfRegisterResult
    }
    func getHistory(_ chave: String) async -> AppResult<HistoryState> {
        lock.withLock { getHistoryCount += 1 }
        let result = historyResult
        await historyGate?.wait()
        return result
    }

    private func beginSimulatedAuthenticationRequest() -> SimulatedCookieRequest? {
        lock.withLock {
            guard let value = authenticationResponseCookie,
                  let store = sessionCookieStore else { return nil }
            return SimulatedCookieRequest(
                store: store,
                snapshot: store.requestSnapshot(for: Self.simulatedCookieURL),
                value: value
            )
        }
    }

    private func finishSimulatedAuthenticationRequest(
        _ request: SimulatedCookieRequest?
    ) {
        guard let request else {
            lock.withLock {
                if let authenticationResponseCookie {
                    persistedSessionCookie = authenticationResponseCookie
                }
            }
            return
        }
        request.store.saveFromResponse(
            Self.simulatedCookieURL,
            headerFields: [
                "Set-Cookie": "session=\(request.value); Path=/; Secure; HttpOnly",
            ],
            requestGeneration: request.snapshot.generation
        )
    }
}

final class FakeProjectRepository: ProjectRepository, @unchecked Sendable {
    var result: AppResult<[Project]> = .success([])
    var userProjectsResult: AppResult<UserProjects> = .success(UserProjects(projects: ["P80"], activeProject: "P80"))
    var updateUserProjectsResult: AppResult<UserProjects>?
    var updateUserProjectsResults: [AppResult<UserProjects>] = []
    var firstUpdateUserProjectsGate: AsyncGate?
    var getUserProjectsGate: AsyncGate?
    var listProjectsGate: AsyncGate?
    private let lock = NSLock()
    private var recordedListProjectsCalls = 0
    private var recordedGetUserProjectsCalls = 0
    private var recordedUpdateUserProjectsCalls: [[String]] = []
    var listProjectsCallCount: Int { lock.withLock { recordedListProjectsCalls } }
    var getUserProjectsCallCount: Int { lock.withLock { recordedGetUserProjectsCalls } }
    var updateUserProjectsCalls: [[String]] { lock.withLock { recordedUpdateUserProjectsCalls } }
    func listProjects() async -> AppResult<[Project]> {
        lock.withLock { recordedListProjectsCalls += 1 }
        let captured = result
        await listProjectsGate?.wait()
        return captured
    }
    func getUserProjects() async -> AppResult<UserProjects> {
        lock.withLock { recordedGetUserProjectsCalls += 1 }
        let captured = userProjectsResult
        await getUserProjectsGate?.wait()
        return captured
    }
    func updateUserProjects(_ projectNames: [String]) async -> AppResult<UserProjects> {
        let callIndex = lock.withLock { () -> Int in
            recordedUpdateUserProjectsCalls.append(projectNames)
            return recordedUpdateUserProjectsCalls.count - 1
        }
        if callIndex == 0 { await firstUpdateUserProjectsGate?.wait() }
        if updateUserProjectsResults.indices.contains(callIndex) {
            return updateUserProjectsResults[callIndex]
        }
        return updateUserProjectsResult ?? .success(UserProjects(projects: projectNames, activeProject: projectNames.first ?? ""))
    }
    func updateActiveProject(_ projectName: String) async -> AppResult<UserProjects> {
        .success(UserProjects(projects: [projectName], activeProject: projectName))
    }
}

final class SpyOrchestrator: OrchestratorRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [OrchestratorTrigger] = []
    private var accuracyRetryInvalidations = 0
    private var contextTransitionBegins = 0
    private var contextTransitionQuiescences = 0
    private var contextTransitionEnds = 0
    private var scheduledPauseChanges = 0
    private var accepted: [(String, String, CheckAction, HistoryState)] = []
    private var confirmed: [(String, HistoryState)] = []
    private var pendingRunGate: AsyncGate?
    var runOnceCalls: [OrchestratorTrigger] { lock.withLock { calls } }
    var invalidateAccuracyRetryCount: Int { lock.withLock { accuracyRetryInvalidations } }
    var beginAutomationContextTransitionCount: Int { lock.withLock { contextTransitionBegins } }
    var awaitAutomationQuiescenceCount: Int { lock.withLock { contextTransitionQuiescences } }
    var endAutomationContextTransitionCount: Int { lock.withLock { contextTransitionEnds } }
    var scheduledPauseSettingsChangeCount: Int { lock.withLock { scheduledPauseChanges } }
    var acceptedChecks: [(String, String, CheckAction, HistoryState)] { lock.withLock { accepted } }
    var confirmedStates: [(String, HistoryState)] { lock.withLock { confirmed } }
    var nextRunGate: AsyncGate? {
        get { lock.withLock { pendingRunGate } }
        set { lock.withLock { pendingRunGate = newValue } }
    }
    @discardableResult
    func runOnce(_ trigger: OrchestratorTrigger) async -> EvaluationCompletion {
        let gate = lock.withLock { () -> AsyncGate? in
            calls.append(trigger)
            defer { pendingRunGate = nil }
            return pendingRunGate
        }
        await gate?.wait()
        return EvaluationCompletion(
            evaluationID: EvaluationID(),
            outcome: .noAction,
            completedBeforeExpiration: true)
    }
    func invalidateAccuracyRetry() async {
        lock.withLock { accuracyRetryInvalidations += 1 }
    }
    func beginAutomationContextTransition() async -> AutomationContextTransitionToken {
        lock.withLock {
            contextTransitionBegins += 1
        }
        return AutomationContextTransitionToken()
    }
    func awaitAutomationQuiescence(_ token: AutomationContextTransitionToken) async {
        lock.withLock { contextTransitionQuiescences += 1 }
    }
    func endAutomationContextTransition(_ token: AutomationContextTransitionToken) async {
        lock.withLock { contextTransitionEnds += 1 }
    }
    func scheduledPauseSettingsDidChange() async {
        lock.withLock { scheduledPauseChanges += 1 }
        await runOnce(.foreground)
    }
    func acceptedCheck(
        chave: String,
        project: String,
        action: CheckAction,
        newState: HistoryState
    ) async {
        lock.withLock {
            accuracyRetryInvalidations += 1
            accepted.append((chave, project, action, newState))
        }
    }
    func confirmedState(chave: String, newState: HistoryState) async {
        lock.withLock { confirmed.append((chave, newState)) }
    }
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

final class SpyCheckEventStream: CheckEventStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedKeys: [String] = []

    var calls: [String] { lock.withLock { recordedKeys } }

    func events(chave: String) -> AsyncStream<String> {
        lock.withLock { recordedKeys.append(chave) }
        return AsyncStream { $0.finish() }
    }
}

actor ControlledPermissionsInspector: PermissionsInspecting {
    private var status: PermissionsStatus
    private let gate: AsyncGate?
    private(set) var callCount = 0

    init(status: PermissionsStatus, gate: AsyncGate? = nil) {
        self.status = status
        self.gate = gate
    }

    func inspect() async -> PermissionsStatus {
        callCount += 1
        await gate?.wait()
        return status
    }

    func update(_ status: PermissionsStatus) {
        self.status = status
    }
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

actor SpyEvaluationJournal: EvaluationJournaling {
    private(set) var clearCount = 0
    private(set) var finishedOutcomes: [EvaluationTerminalOutcome] = []
    private(set) var eventTrace: [String] = []

    func begin(_ start: EvaluationStart) async {}
    func coalesce(_ event: EvaluationCoalescence) async {}
    func finish(id: EvaluationID, terminal: EvaluationTerminal) async {
        finishedOutcomes.append(terminal.outcome)
        eventTrace.append("finish:\(terminal.outcome.rawValue)")
    }
    func reconcileOrphans() async {}
    func recent(limit: Int) async -> [EvaluationRecord] { [] }
    func clear() async {
        clearCount += 1
        eventTrace.append("clear")
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
    let evaluationJournal = SpyEvaluationJournal()
    let passwords = SpySecurePasswordStore()
    let sessionCookies = InMemorySessionCookieStore()
    let checkRepository = FakeCheckRepository()
    let captureLocation = FakeCaptureLocation(.noPermission)
    let offlineQueue = FakeOfflineQueue()
    let activityLog = ActivityLog(dao: CoreDataActivityLogDao(stack: CoreDataStack(inMemory: true)))
    var permissions = PermissionsStatus(
        locationAuthorization: .always, preciseAccuracy: true, cameraMicGranted: true,
        notificationAuthorization: .authorized, lowPowerMode: false, backgroundRefresh: .available)

    func build(
        backgroundReliabilityProfile: BackgroundReliabilityProfile = .legacyWithDiagnostics,
        appPreferences: (any AppPreferencesStore)? = nil,
        securePasswordStore: (any SecurePasswordStore)? = nil,
        authRepository: (any AuthRepository)? = nil,
        authSessionCoordinator: (any AuthSessionCoordinating)? = nil,
        orchestrator: (any OrchestratorRunning)? = nil,
        evaluationJournal: (any EvaluationJournaling)? = nil,
        permissionsInspector: (any PermissionsInspecting)? = nil,
        checkEventStream: (any CheckEventStreaming)? = nil,
        approvalPollingSleeper: any Sleeping = TaskSleeper(),
        initialState: CheckUiState? = nil
    ) -> CheckViewModel {
        let resolvedPasswords = securePasswordStore ?? passwords
        let resolvedAuthRepository = authRepository ?? auth
        if authRepository == nil {
            auth.attachSessionCookieStore(sessionCookies)
        }
        let resolvedSessionCoordinator = authSessionCoordinator
            ?? AuthSessionCoordinator(
                authRepository: resolvedAuthRepository,
                securePasswordStore: resolvedPasswords,
                cookieStore: sessionCookies)
        return CheckViewModel(
                       appPreferences: appPreferences ?? prefs,
                       securePasswordStore: resolvedPasswords,
                       authRepository: resolvedAuthRepository,
                       authSessionCoordinator: resolvedSessionCoordinator,
                       projectRepository: projects, checkRepository: checkRepository,
                       captureLocationUseCase: captureLocation, offlineQueue: offlineQueue,
                       permissionsInspector: permissionsInspector
                           ?? StaticPermissionsInspector(status: permissions),
                       orchestrator: orchestrator ?? self.orchestrator,
                       significantLocationMonitor: significantLocationMonitor,
                       checkEventStream: checkEventStream ?? NoopCheckEventStream(),
                       activityLogger: NoopActivityLogger(),
                       clock: FixedClock(Date(timeIntervalSince1970: 0)),
                       evaluationJournal: evaluationJournal ?? self.evaluationJournal,
                       activityLog: activityLog,
                       geofenceRegionManager: geofenceRegionManager,
                       backgroundReliabilityProfile: backgroundReliabilityProfile,
                       approvalPollingSleeper: approvalPollingSleeper,
                       initialState: initialState)
    }
    func teardown() {
        sessionCookies.clear()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

struct StaticPermissionsInspector: PermissionsInspecting {
    let status: PermissionsStatus
    func inspect() async -> PermissionsStatus { status }
}
