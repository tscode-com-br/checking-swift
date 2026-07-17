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

final class FakeProjectRepository: ProjectListing, @unchecked Sendable {
    var result: AppResult<[Project]> = .success([])
    func listProjects() async -> AppResult<[Project]> { result }
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

/// Harness dos testes do ViewModel — configure os fakes/prefs, depois `build()`.
@MainActor
final class VMHarness {
    let suiteName = "vm_\(UUID().uuidString)"
    lazy var prefs = UserDefaultsPreferencesStore(defaults: UserDefaults(suiteName: suiteName)!)
    let auth = FakeAuthRepository()
    let projects = FakeProjectRepository()
    let orchestrator = SpyOrchestrator()
    let passwords = SpySecurePasswordStore()
    let checkRepository = FakeCheckRepository()

    func build() -> CheckViewModel {
        CheckViewModel(appPreferences: prefs, securePasswordStore: passwords, authRepository: auth,
                       projectRepository: projects, checkRepository: checkRepository, orchestrator: orchestrator,
                       checkEventStream: NoopCheckEventStream(), activityLogger: NoopActivityLogger(),
                       clock: FixedClock(Date(timeIntervalSince1970: 0)))
    }
    func teardown() { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
}
