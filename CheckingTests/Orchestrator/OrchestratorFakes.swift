import Foundation
@testable import Checking

// Fakes do orquestrador (reusa FakeCheckRepository/FakeLocationProvider/NoopActivityLogger de UseCaseFakes,
// AsyncGate/waitUntil de PlatformFakes, iso/FixedClock do suporte).

final class FakeAppPreferences: AppPreferencesReading, @unchecked Sendable {
    var chaveValue = ""
    var languageValue = "pt"
    var userSettingsJsonValue = ""
    var seenAccidentIdsValue: Set<Int> = []
    var chaveGate: AsyncGate?                       // se setado, chave() trava até release() (single-flight)

    private let lock = NSLock()
    private var setSeenRecorded: [Set<Int>] = []
    private var flagsStore: [String: Bool] = [:]
    var setSeenCalls: [Set<Int>] { lock.withLock { setSeenRecorded } }

    func chave() async -> String {
        if let chaveGate { await chaveGate.wait() }
        return chaveValue
    }
    func language() async -> String { languageValue }
    func userSettingsJson() async -> String { userSettingsJsonValue }
    func seenAccidentIds() async -> Set<Int> { seenAccidentIdsValue }
    func setSeenAccidentIds(_ ids: Set<Int>) async { lock.withLock { setSeenRecorded.append(ids) } }
    func getFlag(_ name: String) async -> Bool { lock.withLock { flagsStore[name] ?? false } }
    func setFlag(_ name: String, _ value: Bool) async { lock.withLock { flagsStore[name] = value } }
}

final class FakeAccidentStateRepository: AccidentStateReading, @unchecked Sendable {
    var result: AppResult<AccidentState> = .failure(.network)
    private let lock = NSLock()
    private var count = 0
    var getStateCount: Int { lock.withLock { count } }
    func getState(_ chave: String) async -> AppResult<AccidentState> {
        lock.withLock { count += 1 }
        return result
    }
}

final class SpyNotifications: AutoActivityNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var accidents: [String] = []
    private var activities: [(action: CheckAction, local: String?, lang: String)] = []
    private var reauths: [String] = []
    private var pauses: [(started: Bool, lang: String)] = []
    var accidentPosts: [String] { lock.withLock { accidents } }
    var activityPosts: [(action: CheckAction, local: String?, lang: String)] { lock.withLock { activities } }
    var reauthPosts: [String] { lock.withLock { reauths } }
    var pausePosts: [(started: Bool, lang: String)] { lock.withLock { pauses } }

    func postAccidentNotification(lang: String) { lock.withLock { accidents.append(lang) } }
    func postActivityNotification(action: CheckAction, local: String?, lang: String) { lock.withLock { activities.append((action, local, lang)) } }
    func postReauthNotification(lang: String) { lock.withLock { reauths.append(lang) } }
    func postScheduledPauseTransition(started: Bool, lang: String) { lock.withLock { pauses.append((started, lang)) } }
}

final class SpyAutoActivities: RunningAutomaticActivities, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }
    var result: AutoActivitiesResult = .noAction
    func callAsFunction(chave: String, userProjects: UserProjects?, currentState: HistoryState?,
                        mixedZoneIntervalMinutes: Int, accuracyThresholdMeters: Int) async -> AutoActivitiesResult {
        lock.withLock { calls += 1 }
        return result
    }
}

struct NoopAuthRepository: AuthRepositoring {
    var result: AppResult<AuthStatus> = .failure(.unknown(description: nil))
    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus> { result }
}
struct NoopSecurePasswordStore: SecurePasswordReading {
    var password = ""
    func getPassword(_ chave: String) -> String { password }
}

func makeOrchestrator(
    prefs: FakeAppPreferences = FakeAppPreferences(),
    checkRepository: FakeCheckRepository = FakeCheckRepository(),
    autoActivities: any RunningAutomaticActivities = SpyAutoActivities(),
    accidentRepository: FakeAccidentStateRepository = FakeAccidentStateRepository(),
    notifications: any AutoActivityNotifying = SpyNotifications(),
    locationProvider: any LocationProvider = FakeLocationProvider(.unavailable),
    clock: any Clock = FixedClock(iso("2026-06-18T09:09:09Z"))
) -> BackgroundCheckOrchestrator {
    BackgroundCheckOrchestrator(
        appPrefs: prefs, checkRepository: checkRepository, runAutomaticActivities: autoActivities,
        locationProvider: locationProvider, clock: clock, authRepository: NoopAuthRepository(),
        securePasswordStore: NoopSecurePasswordStore(), accidentRepository: accidentRepository,
        activityLogger: NoopActivityLogger(), notifications: notifications)
}
