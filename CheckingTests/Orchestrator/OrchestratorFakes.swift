import Foundation
@testable import Checking

// Fakes do orquestrador (reusa FakeCheckRepository/FakeLocationProvider/NoopActivityLogger de UseCaseFakes,
// AsyncGate/waitUntil de PlatformFakes, iso/FixedClock do suporte).

final class FakeAppPreferences: AppPreferencesReading, @unchecked Sendable {
    var chaveValue = ""
    var languageValue = "pt"
    var userSettingsJsonValue = ""
    var accuracyRetryEpisodeJsonValue = ""
    var scheduledPauseDeferralJsonValue = ""
    var seenAccidentIdsValue: Set<Int> = []
    var chaveGate: AsyncGate?                       // se setado, chave() trava até release() (single-flight)
    var languageGate: AsyncGate?
    var accuracyRetryEpisodeGate: AsyncGate?

    private let lock = NSLock()
    private var setSeenRecorded: [Set<Int>] = []
    private var flagsStore: [String: Bool] = [:]
    private var languageReadStartedValue = false
    var setSeenCalls: [Set<Int>] { lock.withLock { setSeenRecorded } }
    var languageReadStarted: Bool { lock.withLock { languageReadStartedValue } }

    func chave() async -> String {
        if let chaveGate { await chaveGate.wait() }
        return chaveValue
    }
    func language() async -> String {
        lock.withLock { languageReadStartedValue = true }
        await languageGate?.wait()
        return languageValue
    }
    func userSettingsJson() async -> String { userSettingsJsonValue }
    func seenAccidentIds() async -> Set<Int> { seenAccidentIdsValue }
    func setSeenAccidentIds(_ ids: Set<Int>) async { lock.withLock { setSeenRecorded.append(ids) } }
    func getFlag(_ name: String) async -> Bool { lock.withLock { flagsStore[name] ?? false } }
    func setFlag(_ name: String, _ value: Bool) async { lock.withLock { flagsStore[name] = value } }
    func accuracyRetryEpisodeJson() async -> String {
        await accuracyRetryEpisodeGate?.wait()
        return lock.withLock { accuracyRetryEpisodeJsonValue }
    }
    func setAccuracyRetryEpisodeJson(_ json: String) async {
        lock.withLock { accuracyRetryEpisodeJsonValue = json }
    }
    func scheduledPauseDeferralJson() async -> String {
        lock.withLock { scheduledPauseDeferralJsonValue }
    }
    func setScheduledPauseDeferralJson(_ json: String) async {
        lock.withLock { scheduledPauseDeferralJsonValue = json }
    }
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
    private var lowAccuracies: [(expectedAction: CheckAction?, lang: String)] = []
    private var lowAccuracyClearCount = 0
    var accidentPosts: [String] { lock.withLock { accidents } }
    var activityPosts: [(action: CheckAction, local: String?, lang: String)] { lock.withLock { activities } }
    var reauthPosts: [String] { lock.withLock { reauths } }
    var pausePosts: [(started: Bool, lang: String)] { lock.withLock { pauses } }
    var lowAccuracyPosts: [(expectedAction: CheckAction?, lang: String)] { lock.withLock { lowAccuracies } }
    var clearLowAccuracyCount: Int { lock.withLock { lowAccuracyClearCount } }

    func postAccidentNotification(lang: String) { lock.withLock { accidents.append(lang) } }
    func postActivityNotification(action: CheckAction, local: String?, lang: String) { lock.withLock { activities.append((action, local, lang)) } }
    func postReauthNotification(lang: String) { lock.withLock { reauths.append(lang) } }
    func postScheduledPauseTransition(started: Bool, lang: String) { lock.withLock { pauses.append((started, lang)) } }
    func postLowAccuracyNotification(expectedAction: CheckAction?, lang: String) async {
        lock.withLock { lowAccuracies.append((expectedAction, lang)) }
    }
    func clearLowAccuracyNotification() async { lock.withLock { lowAccuracyClearCount += 1 } }
}

final class SpyPauseAlarmScheduler: PauseAlarmScheduling, @unchecked Sendable {
    struct ScheduleCall: Equatable {
        let date: Date?
        let notify: Bool
        let lang: String
    }
    private let lock = NSLock()
    private var starts: [ScheduleCall] = []
    private var resumes: [ScheduleCall] = []
    var consumeStartResult = false
    var consumeResumeResult = false
    var startCalls: [ScheduleCall] { lock.withLock { starts } }
    var resumeCalls: [ScheduleCall] { lock.withLock { resumes } }

    func scheduleResume(at: Date?, notify: Bool, lang: String) async {
        lock.withLock { resumes.append(ScheduleCall(date: at, notify: notify, lang: lang)) }
    }
    func scheduleStart(at: Date?, notify: Bool, lang: String) async {
        lock.withLock { starts.append(ScheduleCall(date: at, notify: notify, lang: lang)) }
    }
    func consumeScheduledTransition(started: Bool, dueAtOrBefore now: Date) async -> Bool {
        started ? consumeStartResult : consumeResumeResult
    }
}

final class SpyAppRefreshScheduler: AppRefreshScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var scheduledDates: [Date] = []
    private var regularSchedules = 0
    private var clearedRetryDeadlines = 0
    private var pauseDates: [Date] = []
    private var clearedPauseDeadlines = 0
    private var transitionDates: [Date] = []
    private var clearedTransitionDeadlines = 0
    private var trigger: OrchestratorTrigger = .timer
    var pendingTrigger: OrchestratorTrigger {
        get { lock.withLock { trigger } }
        set { lock.withLock { trigger = newValue } }
    }
    var dates: [Date] { lock.withLock { scheduledDates } }
    var regularScheduleCount: Int { lock.withLock { regularSchedules } }
    var clearRetryDeadlineCount: Int { lock.withLock { clearedRetryDeadlines } }
    var scheduledPauseDates: [Date] { lock.withLock { pauseDates } }
    var clearPauseDeadlineCount: Int { lock.withLock { clearedPauseDeadlines } }
    var scheduledTransitionDates: [Date] { lock.withLock { transitionDates } }
    var clearTransitionDeadlineCount: Int { lock.withLock { clearedTransitionDeadlines } }
    func scheduleRegularRefresh() -> String? {
        lock.withLock { regularSchedules += 1 }
        return nil
    }
    func scheduleAccuracyRetry(at deadline: Date) -> String? {
        lock.withLock { scheduledDates.append(deadline) }
        return nil
    }
    func clearAccuracyRetryDeadlineAndScheduleRegular() -> String? {
        lock.withLock {
            clearedRetryDeadlines += 1
            regularSchedules += 1
        }
        return nil
    }
    func schedulePauseActivation(at deadline: Date) -> String? {
        lock.withLock { pauseDates.append(deadline) }
        return nil
    }
    func clearPauseActivationDeadlineAndScheduleRegular() -> String? {
        lock.withLock {
            clearedPauseDeadlines += 1
            regularSchedules += 1
        }
        return nil
    }
    func schedulePauseTransition(at deadline: Date) -> String? {
        lock.withLock { transitionDates.append(deadline) }
        return nil
    }
    func clearPauseTransitionDeadlineAndScheduleRegular() -> String? {
        lock.withLock {
            clearedTransitionDeadlines += 1
            regularSchedules += 1
        }
        return nil
    }
    func triggerForPendingRefresh() -> OrchestratorTrigger {
        lock.withLock { trigger }
    }
}

actor ControlledAccuracyRetrySleeper: Sleeping {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }
    private var recordedDelays: [Int] = []
    private var waiters: [Waiter] = []
    private var cancelledBeforeRegistration: Set<UUID> = []

    func sleep(milliseconds: Int) async {
        let id = UUID()
        recordedDelays.append(milliseconds)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledBeforeRegistration.remove(id) != nil || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func releaseNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func delays() -> [Int] { recordedDelays }
    func waitingCount() -> Int { waiters.count }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            cancelledBeforeRegistration.insert(id)
            return
        }
        waiters.remove(at: index).continuation.resume()
    }
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
    clock: any Clock = FixedClock(iso("2026-06-18T09:09:09Z")),
    pauseAlarms: any PauseAlarmScheduling = NoopPauseAlarmScheduling(),
    accuracyRetrySleeper: any Sleeping = TaskSleeper(),
    pauseActivationSleeper: any Sleeping = TaskSleeper(),
    pauseTransitionSleeper: any Sleeping = TaskSleeper(),
    appRefreshScheduler: any AppRefreshScheduling = NoopAppRefreshScheduler()
) -> BackgroundCheckOrchestrator {
    BackgroundCheckOrchestrator(
        appPrefs: prefs, checkRepository: checkRepository, runAutomaticActivities: autoActivities,
        locationProvider: locationProvider, clock: clock, authRepository: NoopAuthRepository(),
        securePasswordStore: NoopSecurePasswordStore(), accidentRepository: accidentRepository,
        activityLogger: NoopActivityLogger(), notifications: notifications,
        pauseAlarms: pauseAlarms,
        accuracyRetrySleeper: accuracyRetrySleeper,
        pauseActivationSleeper: pauseActivationSleeper,
        pauseTransitionSleeper: pauseTransitionSleeper,
        appRefreshScheduler: appRefreshScheduler)
}
