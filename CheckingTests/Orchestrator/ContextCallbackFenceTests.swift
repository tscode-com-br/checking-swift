import Foundation
import XCTest
@testable import Checking

final class ContextCallbackFenceTests: XCTestCase {
    private let now = Calendar.current.date(
        from: DateComponents(
            timeZone: Calendar.current.timeZone,
            year: 2026,
            month: 6,
            day: 18,
            hour: 12
        )
    )!

    func test_acceptedCheckStartedBeforeContextTransition_cannotRepopulatePauseStateAfterAwait() async {
        let harness = makeHarness()
        let state = checkoutState()
        let callback = Task {
            await harness.sut.acceptedCheck(
                chave: "HR70",
                project: "P80",
                action: .checkOut,
                newState: state
            )
        }
        await harness.readGate.waitUntilEntered()

        let baseline = await completeContextTransition(in: harness)
        await harness.readGate.release()
        await callback.value

        await assertOldCallbackDidNotRepopulateContext(harness, baseline: baseline)
    }

    func test_confirmedStateStartedBeforeContextTransition_cannotRepopulatePauseStateAfterAwait() async {
        let harness = makeHarness()
        let state = checkoutState()
        let callback = Task {
            await harness.sut.confirmedState(
                chave: "HR70",
                newState: state
            )
        }
        await harness.readGate.waitUntilEntered()

        let baseline = await completeContextTransition(in: harness)
        await harness.readGate.release()
        await callback.value

        await assertOldCallbackDidNotRepopulateContext(harness, baseline: baseline)
    }

    func test_scheduledPauseSettingsChangeStartedBeforeContextTransition_cannotRepopulateOrReconcileAfterAwait() async {
        let harness = makeHarness()
        let callback = Task {
            await harness.sut.scheduledPauseSettingsDidChange()
        }
        await harness.readGate.waitUntilEntered()

        let baseline = await completeContextTransition(in: harness)
        await harness.readGate.release()
        await callback.value

        await assertOldCallbackDidNotRepopulateContext(harness, baseline: baseline)
    }

    func test_entriesArrivingDuringContextTransitionReturnStaleWithoutWaitingForBarrierEnd() async {
        let harness = makeHarness()
        let token = await harness.sut.beginAutomationContextTransition()

        let ticket = await harness.sut.evaluationTicket(.geofence)
        let ticketCompletion = await ticket.completion()
        XCTAssertEqual(ticket.admission, .staleContext)
        XCTAssertEqual(ticketCompletion.outcome, .staleContext)

        let probe = ContextFenceCompletionProbe()
        let invalidation = Task {
            await harness.sut.invalidateAccuracyRetry()
            await probe.markFinished()
        }
        await waitUntil(timeout: 0.5) {
            await probe.isFinished
        }
        let invalidationFinishedBeforeBarrierEnd = await probe.isFinished
        XCTAssertTrue(
            invalidationFinishedBeforeBarrierEnd,
            "callback antigo não pode aguardar o barrier que o próprio wipe está drenando"
        )

        await harness.sut.endAutomationContextTransition(token)
        await invalidation.value
        let journalBeginCount = await harness.journal.beginCount
        XCTAssertEqual(journalBeginCount, 0)
    }

    private func checkoutState() -> HistoryState {
        HistoryState(
            found: true,
            chave: "HR70",
            projeto: "P80",
            currentAction: .checkOut,
            currentLocal: nil,
            hasCurrentDayCheckin: true,
            lastCheckinAt: now.addingTimeInterval(-3_600),
            lastCheckoutAt: now,
            transportEnabled: false
        )
    }

    private struct Harness: Sendable {
        let sut: BackgroundCheckOrchestrator
        let preferences: ContextFencePreferences
        let readGate: ContextFenceGate
        let alarms: ContextFenceAlarmScheduler
        let scheduler: ContextFenceRefreshScheduler
        let automaticActivities: ContextFenceAutomaticActivities
        let journal: ContextFenceJournal
    }

    private struct TransitionBaseline: Sendable {
        let alarms: ContextFenceAlarmScheduler.Snapshot
        let scheduler: ContextFenceRefreshScheduler.Snapshot
        let automaticActivityCalls: Int
        let journalBegins: Int
    }

    private func makeHarness() -> Harness {
        let gate = ContextFenceGate()
        let preferences = ContextFencePreferences(
            scheduledPauseReadGate: gate,
            settingsJSON: encodedSettings()
        )
        let alarms = ContextFenceAlarmScheduler()
        let scheduler = ContextFenceRefreshScheduler()
        let automaticActivities = ContextFenceAutomaticActivities()
        let journal = ContextFenceJournal()
        let repository = ContextFenceCheckRepository(state: checkoutState())
        let sut = BackgroundCheckOrchestrator(
            appPrefs: preferences,
            checkRepository: repository,
            runAutomaticActivities: automaticActivities,
            locationProvider: ContextFenceLocationProvider(),
            clock: ContextFenceClock(now),
            authSessionCoordinator: OrchestratorAuthSessionCoordinator(
                authRepository: ContextFenceAuthRepository(),
                securePasswordStore: ContextFencePasswordStore()
            ),
            accidentRepository: ContextFenceAccidentRepository(),
            activityLogger: ContextFenceActivityLogger(),
            notifications: ContextFenceNotifications(),
            automaticEvaluationPipeline: .candidate,
            evaluationJournal: journal,
            pauseAlarms: alarms,
            appRefreshScheduler: scheduler
        )
        return Harness(
            sut: sut,
            preferences: preferences,
            readGate: gate,
            alarms: alarms,
            scheduler: scheduler,
            automaticActivities: automaticActivities,
            journal: journal
        )
    }

    private func encodedSettings() -> String {
        let settings = UserSettings(
            projects: ["P80"],
            activeProject: "P80",
            automaticActivitiesEnabled: true,
            scheduledPauseEnabled: true,
            scheduledPauseFrom: "00:00",
            scheduledPauseTo: "23:59",
            suspendSaturdays: false,
            suspendSundays: false
        )
        let data = try! JSONCoding.encoder.encode(["HR70": settings])
        return String(decoding: data, as: UTF8.self)
    }

    private func completeContextTransition(
        in harness: Harness
    ) async -> TransitionBaseline {
        let token = await harness.sut.beginAutomationContextTransition()
        await harness.sut.awaitAutomationQuiescence(token)
        await harness.sut.endAutomationContextTransition(token)

        let persistedPause = await harness.preferences.persistedScheduledPauseJSON()
        let pauseFlag = await harness.preferences.flag(
            BackgroundCheckOrchestrator.flagPauseActive
        )
        let hasRuntime = await harness.sut.hasScheduledPauseDeferralForTest
        XCTAssertTrue(persistedPause.isEmpty)
        XCTAssertFalse(pauseFlag)
        XCTAssertFalse(hasRuntime)

        return await TransitionBaseline(
            alarms: harness.alarms.snapshot(),
            scheduler: harness.scheduler.snapshot(),
            automaticActivityCalls: harness.automaticActivities.callCount,
            journalBegins: harness.journal.beginCount
        )
    }

    private func assertOldCallbackDidNotRepopulateContext(
        _ harness: Harness,
        baseline: TransitionBaseline,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let persistedPause = await harness.preferences.persistedScheduledPauseJSON()
        let pauseFlag = await harness.preferences.flag(
            BackgroundCheckOrchestrator.flagPauseActive
        )
        let hasRuntime = await harness.sut.hasScheduledPauseDeferralForTest
        let activationAt = await harness.sut.scheduledPauseActivationAtForTest
        let journalBegins = await harness.journal.beginCount

        XCTAssertTrue(persistedPause.isEmpty, file: file, line: line)
        XCTAssertFalse(pauseFlag, file: file, line: line)
        XCTAssertFalse(hasRuntime, file: file, line: line)
        XCTAssertNil(activationAt, file: file, line: line)
        XCTAssertEqual(harness.alarms.snapshot(), baseline.alarms, file: file, line: line)
        XCTAssertEqual(harness.scheduler.snapshot(), baseline.scheduler, file: file, line: line)
        XCTAssertEqual(
            harness.automaticActivities.callCount,
            baseline.automaticActivityCalls,
            file: file,
            line: line
        )
        XCTAssertEqual(journalBegins, baseline.journalBegins, file: file, line: line)
        XCTAssertEqual(journalBegins, 0, "callback antigo não pode admitir reconciliação", file: file, line: line)
    }
}

private actor ContextFenceCompletionProbe {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}

private actor ContextFenceGate {
    private var entered = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        waitingForEntry.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }
}

private actor ContextFencePreferences: AppPreferencesReading {
    private let scheduledPauseReadGate: ContextFenceGate
    private let settingsJSON: String
    private var scheduledPauseJSON = ""
    private var accuracyRetryJSON = ""
    private var flags: [String: Bool] = [:]
    private var seenAccidentIDs: Set<Int> = []

    init(
        scheduledPauseReadGate: ContextFenceGate,
        settingsJSON: String
    ) {
        self.scheduledPauseReadGate = scheduledPauseReadGate
        self.settingsJSON = settingsJSON
    }

    func chave() async -> String { "HR70" }
    func language() async -> String { "pt" }
    func userSettingsJson() async -> String { settingsJSON }
    func backgroundLocationConsentAt() async -> String { "2026-01-01T00:00:00Z" }
    func seenAccidentIds() async -> Set<Int> { seenAccidentIDs }
    func setSeenAccidentIds(_ ids: Set<Int>) async { seenAccidentIDs = ids }
    func getFlag(_ name: String) async -> Bool { flags[name] ?? false }
    func setFlag(_ name: String, _ value: Bool) async { flags[name] = value }
    func accuracyRetryEpisodeJson() async -> String { accuracyRetryJSON }
    func setAccuracyRetryEpisodeJson(_ json: String) async { accuracyRetryJSON = json }

    func scheduledPauseDeferralJson() async -> String {
        await scheduledPauseReadGate.wait()
        return scheduledPauseJSON
    }

    func setScheduledPauseDeferralJson(_ json: String) async {
        scheduledPauseJSON = json
    }

    func persistedScheduledPauseJSON() -> String { scheduledPauseJSON }
    func flag(_ name: String) -> Bool { flags[name] ?? false }
}

private final class ContextFenceAlarmScheduler: PauseAlarmScheduling, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let date: Date?
        let notify: Bool
        let language: String
    }

    struct Snapshot: Sendable, Equatable {
        let starts: [Call]
        let resumes: [Call]
    }

    private let lock = NSLock()
    private var starts: [Call] = []
    private var resumes: [Call] = []

    func scheduleResume(at: Date?, notify: Bool, lang: String) async {
        lock.withLock {
            resumes.append(Call(date: at, notify: notify, language: lang))
        }
    }

    func scheduleStart(at: Date?, notify: Bool, lang: String) async {
        lock.withLock {
            starts.append(Call(date: at, notify: notify, language: lang))
        }
    }

    func consumeScheduledTransition(
        started: Bool,
        dueAtOrBefore now: Date
    ) async -> Bool {
        false
    }

    func snapshot() -> Snapshot {
        lock.withLock { Snapshot(starts: starts, resumes: resumes) }
    }
}

private final class ContextFenceRefreshScheduler: AppRefreshScheduling, @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        let regularSchedules: Int
        let retryDeadlines: [Date]
        let retryClears: Int
        let pauseActivationDeadlines: [Date]
        let pauseActivationClears: Int
        let pauseTransitionDeadlines: [Date]
        let pauseTransitionClears: Int
    }

    private let lock = NSLock()
    private var regularSchedules = 0
    private var retryDeadlines: [Date] = []
    private var retryClears = 0
    private var pauseActivationDeadlines: [Date] = []
    private var pauseActivationClears = 0
    private var pauseTransitionDeadlines: [Date] = []
    private var pauseTransitionClears = 0

    func scheduleRegularRefresh() -> String? {
        lock.withLock { regularSchedules += 1 }
        return nil
    }

    func scheduleAccuracyRetry(at deadline: Date) -> String? {
        lock.withLock { retryDeadlines.append(deadline) }
        return nil
    }

    func clearAccuracyRetryDeadlineAndScheduleRegular() -> String? {
        lock.withLock { retryClears += 1 }
        return nil
    }

    func schedulePauseActivation(at deadline: Date) -> String? {
        lock.withLock { pauseActivationDeadlines.append(deadline) }
        return nil
    }

    func clearPauseActivationDeadlineAndScheduleRegular() -> String? {
        lock.withLock { pauseActivationClears += 1 }
        return nil
    }

    func schedulePauseTransition(at deadline: Date) -> String? {
        lock.withLock { pauseTransitionDeadlines.append(deadline) }
        return nil
    }

    func clearPauseTransitionDeadlineAndScheduleRegular() -> String? {
        lock.withLock { pauseTransitionClears += 1 }
        return nil
    }

    func triggerForPendingRefresh() -> OrchestratorTrigger { .timer }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                regularSchedules: regularSchedules,
                retryDeadlines: retryDeadlines,
                retryClears: retryClears,
                pauseActivationDeadlines: pauseActivationDeadlines,
                pauseActivationClears: pauseActivationClears,
                pauseTransitionDeadlines: pauseTransitionDeadlines,
                pauseTransitionClears: pauseTransitionClears
            )
        }
    }
}

private final class ContextFenceAutomaticActivities: RunningAutomaticActivities, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func execute(
        chave: String,
        userProjects: UserProjects?,
        currentState: HistoryState?,
        mixedZoneIntervalMinutes: Int,
        accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput
    ) async -> AutomaticActivitiesExecution {
        lock.withLock { calls += 1 }
        return AutomaticActivitiesExecution(
            result: .noAction,
            trace: AutomaticActivitiesTrace(
                maximumStage: .decisionCompleted,
                capture: nil,
                failure: nil,
                offlineDisposition: nil
            ),
            submissionContext: nil
        )
    }
}

private actor ContextFenceJournal: EvaluationJournaling {
    private var begins = 0

    var beginCount: Int { begins }

    func begin(_ start: EvaluationStart) async { begins += 1 }
    func coalesce(_ event: EvaluationCoalescence) async {}
    func advance(_ progress: EvaluationProgress) async {}
    func finish(id: EvaluationID, terminal: EvaluationTerminal) async {}
    func reconcileOrphans() async {}
    func recent(limit: Int) async -> [EvaluationRecord] { [] }
    func clear() async {}
}

private final class ContextFenceCheckRepository: CheckRepository, @unchecked Sendable {
    private let state: HistoryState

    init(state: HistoryState) {
        self.state = state
    }

    func matchLocation(
        _ lat: Double,
        _ lon: Double,
        _ accuracyMeters: Double?
    ) async -> AppResult<LocationMatch> {
        .failure(.network)
    }

    func getState(_ chave: String) async -> AppResult<HistoryState> { .success(state) }
    func getHistory(_ chave: String) async -> AppResult<[CheckHistoryEntry]> { .success([]) }
    func getLocations() async -> AppResult<LocationOptions> {
        .success(
            LocationOptions(
                items: ["registered"],
                accuracyThresholdMeters: 50,
                mixedZoneIntervalMinutes: 15
            )
        )
    }
    func getGeofences(_ chave: String) async -> AppResult<[GeofenceCircle]> { .success([]) }
    func submit(
        chave: String,
        projeto: String,
        action: CheckAction,
        local: String?,
        informe: InformeType,
        eventTime: Date,
        clientEventId: String,
        fillForms: Bool
    ) async -> AppResult<HistoryState> {
        .success(state)
    }
}

private struct ContextFenceClock: Clock {
    let date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { date }
}

private struct ContextFenceLocationProvider: LocationProvider {
    func capture(
        _ accuracyThresholdMeters: Int,
        seed: LocationSample?
    ) async -> LocationCapture {
        .failure(.unavailable)
    }
}

private struct ContextFenceAuthRepository: AuthRepositoring {
    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus> {
        .failure(.network)
    }
}

private struct ContextFencePasswordStore: SecurePasswordReading {
    func getPassword(_ chave: String) -> String { "" }
}

private struct ContextFenceAccidentRepository: AccidentStateReading {
    func getState(_ chave: String) async -> AppResult<AccidentState> {
        .failure(.network)
    }
}

private struct ContextFenceActivityLogger: ActivityLogging {}

private struct ContextFenceNotifications: AutoActivityNotifying {
    func postAccidentNotification(lang: String) {}
    func postActivityNotification(action: CheckAction, local: String?, lang: String) {}
    func postReauthNotification(lang: String) {}
    func postScheduledPauseTransition(started: Bool, lang: String) {}
    func postLowAccuracyNotification(expectedAction: CheckAction?, lang: String) async {}
    func clearLowAccuracyNotification() async {}
}
