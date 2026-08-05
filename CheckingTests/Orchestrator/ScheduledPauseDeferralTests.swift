import Foundation
import XCTest
@testable import Checking

final class ScheduledPauseDeferralTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EvaluationLog.shared.reset()
    }

    private final class MutableClock: Clock, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        func now() -> Date { lock.withLock { value } }
        func advance(_ interval: TimeInterval) {
            lock.withLock { value = value.addingTimeInterval(interval) }
        }
    }

    private func preferences(
        chave: String = "HR70",
        project: String = "P80",
        pauseEnabled: Bool = true,
        from: String = "00:00",
        to: String = "23:59"
    ) -> FakeAppPreferences {
        let settings = UserSettings(
            projects: [project],
            activeProject: project,
            automaticActivitiesEnabled: true,
            scheduledPauseEnabled: pauseEnabled,
            scheduledPauseFrom: from,
            scheduledPauseTo: to,
            suspendSaturdays: false,
            suspendSundays: false)
        let prefs = FakeAppPreferences()
        prefs.chaveValue = chave
        prefs.languageValue = "pt"
        prefs.userSettingsJsonValue = String(
            data: try! JSONCoding.encoder.encode([chave: settings]),
            encoding: .utf8)!
        return prefs
    }

    private func state(
        _ action: CheckAction?,
        at date: Date? = nil
    ) -> HistoryState {
        HistoryState(
            found: action != nil,
            chave: "HR70",
            projeto: "P80",
            currentAction: action,
            currentLocal: action == .checkIn ? "Unidade P80" : nil,
            hasCurrentDayCheckin: action == .checkIn,
            lastCheckinAt: action == .checkIn ? date : nil,
            lastCheckoutAt: action == .checkOut ? date : nil,
            transportEnabled: false)
    }

    private func updateSettings(
        _ prefs: FakeAppPreferences,
        _ update: (inout UserSettings) -> Void
    ) {
        var map = try! JSONCoding.decoder.decode(
            [String: UserSettings].self,
            from: Data(prefs.userSettingsJsonValue.utf8))
        var settings = map["HR70"]!
        update(&settings)
        map["HR70"] = settings
        prefs.userSettingsJsonValue = String(
            data: try! JSONCoding.encoder.encode(map),
            encoding: .utf8)!
    }

    private func sundayAtNoon() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Calendar.current.timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 26,
            hour: 12))!
    }

    func test_togglingCurrentSundayOffThenOn_reconcilesAndNotifiesImmediately() async {
        let now = sundayAtNoon()
        let clock = MutableClock(now)
        let prefs = preferences(pauseEnabled: false, from: "00:00", to: "00:00")
        updateSettings(prefs) { $0.suspendSundays = true }
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(
            state(.checkOut, at: now.addingTimeInterval(-2 * 24 * 60 * 60)))
        let notifications = SpyNotifications()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            notifications: notifications,
            clock: clock)

        await sut.runOnce(.pauseTransition)
        var isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertTrue(isPaused)
        XCTAssertEqual(notifications.pausePosts.map(\.started), [true])

        updateSettings(prefs) { $0.suspendSundays = false }
        await sut.scheduledPauseSettingsDidChange()
        isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertFalse(isPaused)
        XCTAssertEqual(notifications.pausePosts.map(\.started), [true, false])

        clock.advance(10 * 60)
        updateSettings(prefs) { $0.suspendSundays = true }
        await sut.scheduledPauseSettingsDidChange()

        isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertTrue(isPaused)
        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"active\""))
        XCTAssertEqual(notifications.pausePosts.map(\.started), [true, false, true])
    }

    func test_sundaySettingChangeWhileAnotherRunIsInFlight_isDrainedWithoutForegroundEvent() async {
        let now = sundayAtNoon()
        let prefs = preferences(pauseEnabled: false, from: "00:00", to: "00:00")
        let chaveGate = AsyncGate()
        prefs.chaveGate = chaveGate
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(
            state(.checkOut, at: now.addingTimeInterval(-2 * 24 * 60 * 60)))
        let notifications = SpyNotifications()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            notifications: notifications,
            clock: FixedClock(now))

        let occupiedRun = Task { await sut.runOnce(.timer) }
        await waitUntil { await sut.isRunningForTest }

        updateSettings(prefs) { $0.suspendSundays = true }
        await sut.scheduledPauseSettingsDidChange()
        XCTAssertTrue(notifications.pausePosts.isEmpty)

        await chaveGate.release()
        _ = await occupiedRun.value
        await waitUntil { await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive) }

        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertTrue(isPaused)
        XCTAssertEqual(notifications.pausePosts.map(\.started), [true])
    }

    func test_pauseReconciliationSurvivesAccuracyInvalidationAcrossAwait() async {
        let now = sundayAtNoon()
        let prefs = preferences(pauseEnabled: false, from: "00:00", to: "00:00")
        updateSettings(prefs) { $0.suspendSundays = true }
        let chaveGate = AsyncGate()
        prefs.chaveGate = chaveGate
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(
            state(.checkOut, at: now.addingTimeInterval(-2 * 24 * 60 * 60)))
        let notifications = SpyNotifications()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            notifications: notifications,
            clock: FixedClock(now))

        let settingsChange = Task { await sut.scheduledPauseSettingsDidChange() }
        await waitUntil { await sut.isRunningForTest }
        await sut.invalidateAccuracyRetry()

        await chaveGate.release()
        await settingsChange.value
        await waitUntil { await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive) }

        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertTrue(isPaused)
        XCTAssertEqual(notifications.pausePosts.map(\.started), [true])
    }

    func test_initialStateFailure_retriesAndStartsPauseWithoutForegroundEvent() async {
        let now = iso("2026-06-18T09:09:09Z")
        let clock = MutableClock(now)
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.queuedGetStateResults = [
            .failure(.network),
            .success(state(.checkOut, at: now.addingTimeInterval(-24 * 60 * 60))),
        ]
        let notifications = SpyNotifications()
        let sleeper = ControlledAccuracyRetrySleeper()
        let scheduler = SpyAppRefreshScheduler()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            notifications: notifications,
            clock: clock,
            pauseActivationSleeper: sleeper,
            appRefreshScheduler: scheduler)

        await sut.runOnce(.pauseTransition)
        await waitUntil { await sleeper.waitingCount() == 1 }

        var isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        let firstActivationAt = await sut.scheduledPauseActivationAtForTest
        XCTAssertFalse(isPaused)
        XCTAssertEqual(
            firstActivationAt,
            now.addingTimeInterval(BackgroundCheckOrchestrator.scheduledPauseActivationDelay))
        XCTAssertEqual(
            scheduler.scheduledPauseDates.last,
            now.addingTimeInterval(BackgroundCheckOrchestrator.scheduledPauseActivationDelay))
        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"awaitingCheckout\""))
        XCTAssertTrue(notifications.pausePosts.isEmpty)

        clock.advance(BackgroundCheckOrchestrator.scheduledPauseActivationDelay)
        await sleeper.releaseNext()
        await waitUntil { await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive) }

        isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertTrue(isPaused)
        XCTAssertEqual(notifications.pausePosts.map(\.started), [true])
    }

    func test_repeatedConfirmationFailure_backsOffToThreeMinutes() async {
        let now = iso("2026-06-18T09:09:09Z")
        let clock = MutableClock(now)
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.queuedGetStateResults = [
            .failure(.network),
            .failure(.network),
        ]
        let sleeper = ControlledAccuracyRetrySleeper()
        let scheduler = SpyAppRefreshScheduler()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            clock: clock,
            pauseActivationSleeper: sleeper,
            appRefreshScheduler: scheduler)

        await sut.runOnce(.pauseTransition)
        await waitUntil { await sleeper.waitingCount() == 1 }
        clock.advance(BackgroundCheckOrchestrator.scheduledPauseActivationDelay)
        await sleeper.releaseNext()

        let expectedRetryAt = now.addingTimeInterval(
            BackgroundCheckOrchestrator.scheduledPauseActivationDelay
                + BackgroundCheckOrchestrator.scheduledPauseConfirmationBackoff)
        await waitUntil {
            let activationAt = await sut.scheduledPauseActivationAtForTest
            let waitingCount = await sleeper.waitingCount()
            return activationAt == expectedRetryAt && waitingCount == 1
        }

        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        let activationAt = await sut.scheduledPauseActivationAtForTest
        XCTAssertFalse(isPaused)
        XCTAssertEqual(activationAt, expectedRetryAt)
        XCTAssertEqual(scheduler.scheduledPauseDates.last, expectedRetryAt)
        await sut.invalidateAutomationContext()
        await waitUntil { await sleeper.waitingCount() == 0 }
    }

    func test_unauthorizedStateFailure_reliesOnReauthenticationWithoutTightRetryLoop() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .failure(.unauthorized)
        let notifications = SpyNotifications()
        let sleeper = ControlledAccuracyRetrySleeper()
        let scheduler = SpyAppRefreshScheduler()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            notifications: notifications,
            clock: FixedClock(now),
            pauseActivationSleeper: sleeper,
            appRefreshScheduler: scheduler)

        await sut.runOnce(.pauseTransition)

        let activationAt = await sut.scheduledPauseActivationAtForTest
        let waitingCount = await sleeper.waitingCount()
        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertNil(activationAt)
        XCTAssertEqual(waitingCount, 0)
        XCTAssertFalse(isPaused)
        XCTAssertTrue(scheduler.scheduledPauseDates.isEmpty)
        XCTAssertEqual(notifications.reauthPosts, ["pt"])
    }

    func test_confirmationRetry_reanchorsGraceToNewerCheckoutTimestamp() async {
        let now = iso("2026-06-18T09:09:09Z")
        let clock = MutableClock(now)
        let prefs = preferences()
        let repository = FakeCheckRepository()
        let recentCheckoutAt = now.addingTimeInterval(8)
        repository.queuedGetStateResults = [.failure(.network)]
        repository.getStateResult = .success(state(.checkOut, at: recentCheckoutAt))
        let notifications = SpyNotifications()
        let sleeper = ControlledAccuracyRetrySleeper()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            notifications: notifications,
            clock: clock,
            pauseActivationSleeper: sleeper)

        await sut.runOnce(.pauseTransition)
        await waitUntil { await sleeper.waitingCount() == 1 }
        clock.advance(BackgroundCheckOrchestrator.scheduledPauseActivationDelay)
        await sleeper.releaseNext()
        await waitUntil {
            let activationAt = await sut.scheduledPauseActivationAtForTest
            let waitingCount = await sleeper.waitingCount()
            return activationAt == recentCheckoutAt.addingTimeInterval(
                BackgroundCheckOrchestrator.scheduledPauseActivationDelay)
                && waitingCount == 1
        }

        var isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertFalse(isPaused)
        XCTAssertTrue(notifications.pausePosts.isEmpty)

        clock.advance(8)
        await sleeper.releaseNext()
        await waitUntil { await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive) }

        isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertTrue(isPaused)
        XCTAssertEqual(notifications.pausePosts.map(\.started), [true])
    }

    func test_checkoutThatPredatesWindow_startsPauseImmediately() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(state(.checkOut, at: now.addingTimeInterval(-24 * 60 * 60)))
        let auto = SpyAutoActivities()
        let notifications = SpyNotifications()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            autoActivities: auto,
            notifications: notifications,
            clock: FixedClock(now))

        await sut.runOnce(.pauseTransition)

        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertTrue(isPaused)
        XCTAssertEqual(auto.callCount, 0)
        XCTAssertEqual(notifications.pausePosts.map(\.started), [true])
        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"active\""))
    }

    func test_confirmedEmptyHistory_startsPauseImmediately() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(state(nil))
        let auto = SpyAutoActivities()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            autoActivities: auto,
            clock: FixedClock(now))

        await sut.runOnce(.pauseTransition)

        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertTrue(isPaused)
        XCTAssertEqual(auto.callCount, 0)
    }

    func test_confirmedCheckin_defersPause_runsEngine_andKeepsAccuracyRetryEligible() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(state(.checkIn, at: now))
        let auto = SpyAutoActivities()
        auto.result = .accuracyTooLow(expectedAction: .checkOut)
        let alarms = SpyPauseAlarmScheduler()
        let scheduler = SpyAppRefreshScheduler()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            autoActivities: auto,
            clock: FixedClock(now),
            pauseAlarms: alarms,
            appRefreshScheduler: scheduler)

        await sut.runOnce(.pauseTransition)

        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        let hasDeferral = await sut.hasScheduledPauseDeferralForTest
        let hasAccuracyRetry = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertFalse(isPaused)
        XCTAssertEqual(auto.callCount, 1)
        XCTAssertTrue(hasDeferral)
        XCTAssertTrue(hasAccuracyRetry)
        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"awaitingCheckout\""))
        XCTAssertGreaterThan(scheduler.clearPauseDeadlineCount, 0)
        XCTAssertNil(alarms.startCalls.last?.date)
        XCTAssertNil(alarms.resumeCalls.last?.date)
    }

    func test_checkoutInsideWindow_schedulesTenSecondGrace_withoutStartNotificationAlarm() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(state(.checkOut, at: now))
        let auto = SpyAutoActivities()
        let alarms = SpyPauseAlarmScheduler()
        let scheduler = SpyAppRefreshScheduler()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            autoActivities: auto,
            clock: FixedClock(now),
            pauseAlarms: alarms,
            appRefreshScheduler: scheduler)

        await sut.runOnce(.pauseTransition)

        let activationAt = await sut.scheduledPauseActivationAtForTest
        XCTAssertEqual(activationAt, now.addingTimeInterval(10))
        XCTAssertEqual(scheduler.scheduledPauseDates.last, now.addingTimeInterval(10))
        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertFalse(isPaused)
        XCTAssertEqual(auto.callCount, 0)
        XCTAssertTrue(alarms.startCalls.allSatisfy { $0.date == nil && !$0.notify })
    }

    func test_acceptedRetroactivePayload_usesAuthoritativeFinalCheckoutState() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = preferences()
        let sut = makeOrchestrator(prefs: prefs, clock: FixedClock(now))

        await sut.acceptedCheck(
            chave: "HR70",
            project: "P80",
            action: .checkIn,
            newState: state(.checkOut, at: now))

        let activationAt = await sut.scheduledPauseActivationAtForTest
        XCTAssertEqual(activationAt, now.addingTimeInterval(10))
        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"activationScheduled\""))
    }

    func test_confirmedCheckinDuringGrace_returnsToAwaiting_andCancelsActivation() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(state(.checkOut, at: now))
        let scheduler = SpyAppRefreshScheduler()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            clock: FixedClock(now),
            appRefreshScheduler: scheduler)
        await sut.runOnce(.pauseTransition)

        await sut.confirmedState(chave: "HR70", newState: state(.checkIn, at: now.addingTimeInterval(1)))

        let activationAt = await sut.scheduledPauseActivationAtForTest
        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertNil(activationAt)
        XCTAssertFalse(isPaused)
        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"awaitingCheckout\""))
        XCTAssertGreaterThan(scheduler.clearPauseDeadlineCount, 0)
    }

    func test_confirmedEmptyStateDuringGrace_doesNotActivateBeforeDeadline() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(state(.checkOut, at: now))
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            clock: FixedClock(now))
        await sut.runOnce(.pauseTransition)

        await sut.confirmedState(chave: "HR70", newState: state(nil))

        let activationAt = await sut.scheduledPauseActivationAtForTest
        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertEqual(activationAt, now.addingTimeInterval(10))
        XCTAssertFalse(isPaused)
        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"activationScheduled\""))
    }

    func test_graceTask_revalidatesFreshCheckout_thenActivatesPause() async {
        let now = iso("2026-06-18T09:09:09Z")
        let clock = MutableClock(now)
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(state(.checkOut, at: now))
        let sleeper = ControlledAccuracyRetrySleeper()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            clock: clock,
            pauseActivationSleeper: sleeper)
        await sut.runOnce(.pauseTransition)
        await waitUntil { await sleeper.waitingCount() == 1 }

        clock.advance(10)
        await sleeper.releaseNext()
        await waitUntil { await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive) }

        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertTrue(isPaused)
        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"active\""))
    }

    func test_graceVerificationFailures_useFastRetryThenThreeMinuteBackoff() async {
        let now = iso("2026-06-18T09:09:09Z")
        let clock = MutableClock(now)
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(state(.checkOut, at: now))
        let sleeper = ControlledAccuracyRetrySleeper()
        let scheduler = SpyAppRefreshScheduler()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            clock: clock,
            pauseActivationSleeper: sleeper,
            appRefreshScheduler: scheduler)
        await sut.runOnce(.pauseTransition)
        await waitUntil { await sleeper.waitingCount() == 1 }

        repository.queuedGetStateResults = [
            .failure(.network),
            .failure(.network),
        ]
        clock.advance(BackgroundCheckOrchestrator.scheduledPauseActivationDelay)
        await sleeper.releaseNext()
        let fastRetryAt = now.addingTimeInterval(
            2 * BackgroundCheckOrchestrator.scheduledPauseActivationDelay)
        await waitUntil {
            let activationAt = await sut.scheduledPauseActivationAtForTest
            let waitingCount = await sleeper.waitingCount()
            return activationAt == fastRetryAt && waitingCount == 1
        }

        clock.advance(BackgroundCheckOrchestrator.scheduledPauseActivationDelay)
        await sleeper.releaseNext()
        let backedOffRetryAt = fastRetryAt.addingTimeInterval(
            BackgroundCheckOrchestrator.scheduledPauseConfirmationBackoff)
        await waitUntil {
            let activationAt = await sut.scheduledPauseActivationAtForTest
            let waitingCount = await sleeper.waitingCount()
            return activationAt == backedOffRetryAt && waitingCount == 1
        }

        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertFalse(isPaused)
        XCTAssertEqual(scheduler.scheduledPauseDates.last, backedOffRetryAt)
        await sut.invalidateAutomationContext()
        await waitUntil { await sleeper.waitingCount() == 0 }
    }

    func test_graceUnauthorizedFailure_stopsWakeAndUsesReauthenticationFlow() async {
        let now = iso("2026-06-18T09:09:09Z")
        let clock = MutableClock(now)
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(state(.checkOut, at: now))
        let notifications = SpyNotifications()
        let sleeper = ControlledAccuracyRetrySleeper()
        let scheduler = SpyAppRefreshScheduler()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            notifications: notifications,
            clock: clock,
            pauseActivationSleeper: sleeper,
            appRefreshScheduler: scheduler)
        await sut.runOnce(.pauseTransition)
        await waitUntil { await sleeper.waitingCount() == 1 }

        repository.getStateResult = .failure(.unauthorized)
        clock.advance(BackgroundCheckOrchestrator.scheduledPauseActivationDelay)
        await sleeper.releaseNext()
        await waitUntil { notifications.reauthPosts == ["pt"] }
        await waitUntil {
            let activationAt = await sut.scheduledPauseActivationAtForTest
            let waitingCount = await sleeper.waitingCount()
            return activationAt == nil
                && waitingCount == 0
                && prefs.scheduledPauseDeferralJsonValue.contains(
                    "\"phase\":\"awaitingCheckout\"")
        }

        let activationAt = await sut.scheduledPauseActivationAtForTest
        let waitingCount = await sleeper.waitingCount()
        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertNil(activationAt)
        XCTAssertEqual(waitingCount, 0)
        XCTAssertFalse(isPaused)
        XCTAssertEqual(scheduler.scheduledPauseDates.count, 1)
        XCTAssertEqual(notifications.reauthPosts, ["pt"])
        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"awaitingCheckout\""))
    }

    func test_sessionInvalidatedWhilePauseStateIsInFlightCannotPersistActivateOrNotify() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(
            state(.checkOut, at: now.addingTimeInterval(-60)))
        let stateGate = AsyncGate()
        repository.getStateGate = stateGate
        let notifications = SpyNotifications()
        let scheduler = SpyAppRefreshScheduler()
        let coordinator = OrchestratorAuthSessionCoordinator(
            authRepository: NoopAuthRepository(),
            securePasswordStore: NoopSecurePasswordStore())
        let auto = SpyAutoActivities()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            autoActivities: auto,
            notifications: notifications,
            clock: FixedClock(now),
            authSessionCoordinator: coordinator,
            appRefreshScheduler: scheduler)

        let evaluation = Task { await sut.runOnce(.foreground) }
        await waitUntil { repository.getStateCallCount == 1 }

        _ = coordinator.invalidateCurrentIdentity()
        await stateGate.release()
        let completion = await evaluation.value
        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)

        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertEqual(auto.callCount, 0)
        XCTAssertFalse(isPaused)
        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.isEmpty)
        XCTAssertTrue(notifications.pausePosts.isEmpty)
        XCTAssertTrue(scheduler.scheduledPauseDates.isEmpty)
    }

    func test_coldRestart_restoresGrace_andBGTriggerRevalidatesBeforeActivation() async {
        let now = iso("2026-06-18T09:09:09Z")
        let clock = MutableClock(now)
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(state(.checkOut, at: now))
        let abandonedSleeper = ControlledAccuracyRetrySleeper()
        var first: BackgroundCheckOrchestrator? = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            clock: clock,
            pauseActivationSleeper: abandonedSleeper)
        await first?.runOnce(.pauseTransition)
        XCTAssertFalse(prefs.scheduledPauseDeferralJsonValue.isEmpty)
        first = nil

        clock.advance(10)
        let restored = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            clock: clock)
        await restored.runOnce(.pauseActivation)

        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertTrue(isPaused)
        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"active\""))
    }

    func test_getFailureAtBoundary_isNotTreatedAsEmptyHistory_andDoesNotRunEngine() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .failure(.network)
        let auto = SpyAutoActivities()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            autoActivities: auto,
            clock: FixedClock(now))

        await sut.runOnce(.pauseTransition)

        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertFalse(isPaused)
        XCTAssertEqual(auto.callCount, 0)
        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"awaitingCheckout\""))
        XCTAssertEqual(EvaluationLog.shared.snapshot().first?.outcome, .networkError)
    }

    func test_checkoutTooCloseToWindowEnd_becomesTerminal_andBlocksRepeatedRuns() async {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 18,
            hour: 23,
            minute: 58,
            second: 55))!
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(state(.checkOut, at: now))
        let auto = SpyAutoActivities()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            autoActivities: auto,
            clock: FixedClock(now))

        await sut.runOnce(.pauseTransition)
        await sut.runOnce(.foreground)

        XCTAssertEqual(auto.callCount, 0)
        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertFalse(isPaused)
        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"terminal\""))
    }

    func test_activePause_isNotReversedByLaterConfirmedCheckin() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(state(.checkOut, at: now.addingTimeInterval(-24 * 60 * 60)))
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            clock: FixedClock(now))
        await sut.runOnce(.pauseTransition)

        await sut.confirmedState(chave: "HR70", newState: state(.checkIn, at: now))

        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertTrue(isPaused)
        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"active\""))
    }

    func test_consumedResumeNotification_isPreservedByFullEndOfPauseCleanup() async {
        let now = iso("2026-06-18T09:09:09Z")
        let clock = MutableClock(now)
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(
            state(.checkOut, at: now.addingTimeInterval(-24 * 60 * 60)))
        let notifications = SpyNotifications()
        let alarms = SpyPauseAlarmScheduler()
        alarms.consumeResumeResult = true
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            notifications: notifications,
            clock: clock,
            pauseAlarms: alarms)

        await sut.runOnce(.pauseTransition)

        let settings = ScheduledPauseSettings(
            scheduledPauseEnabled: true,
            scheduledPauseFrom: "00:00",
            scheduledPauseTo: "23:59",
            suspendSaturdays: false,
            suspendSundays: false)
        let window = currentScheduledPauseWindow(now, Calendar.current, settings)!
        XCTAssertEqual(alarms.resumeCalls.last?.date, window.end)
        let resumeCallCountBeforeEnd = alarms.resumeCalls.count

        clock.advance(window.end.timeIntervalSince(now))
        await sut.runOnce(.pauseTransition)

        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertFalse(isPaused)
        XCTAssertEqual(
            alarms.resumeCalls.count,
            resumeCallCountBeforeEnd,
            "cleanup não deve cancelar a notificação de retomada já consumida")
        XCTAssertEqual(notifications.pausePosts.map(\.started), [true])

        await sut.runOnce(.foreground)

        XCTAssertEqual(
            alarms.resumeCalls.count,
            resumeCallCountBeforeEnd,
            "runs idempotentes sem runtime/flag não devem apagar a retomada entregue")
    }

    func test_contextInvalidation_clearsRuntimeFlagAndBothDeadlines() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = preferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(state(.checkIn, at: now))
        let scheduler = SpyAppRefreshScheduler()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            clock: FixedClock(now),
            appRefreshScheduler: scheduler)
        await sut.runOnce(.pauseTransition)

        await sut.invalidateAutomationContext()

        XCTAssertTrue(prefs.scheduledPauseDeferralJsonValue.isEmpty)
        let isPaused = await prefs.getFlag(BackgroundCheckOrchestrator.flagPauseActive)
        XCTAssertFalse(isPaused)
        XCTAssertGreaterThan(scheduler.clearPauseDeadlineCount, 0)
        XCTAssertGreaterThan(scheduler.clearTransitionDeadlineCount, 0)
    }

    func test_contextInvalidationBarrier_rejectsCallbackThatArrivedDuringTransition() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = preferences()
        let languageGate = AsyncGate()
        prefs.languageGate = languageGate
        let sut = makeOrchestrator(prefs: prefs, clock: FixedClock(now))
        let checkoutState = state(.checkOut, at: now)

        let invalidation = Task { await sut.invalidateAutomationContext() }
        await waitUntil { prefs.languageReadStarted }
        let accepted = Task {
            await sut.acceptedCheck(
                chave: "HR70",
                project: "P80",
                action: .checkOut,
                newState: checkoutState)
        }
        try? await Task.sleep(for: .milliseconds(20))
        let beforeRelease = await sut.scheduledPauseActivationAtForTest
        XCTAssertNil(beforeRelease)

        await languageGate.release()
        await invalidation.value
        await accepted.value

        let activationAt = await sut.scheduledPauseActivationAtForTest
        XCTAssertNil(activationAt)
        XCTAssertTrue(
            prefs.scheduledPauseDeferralJsonValue.isEmpty,
            "callback recebido dentro da transição não pode reidratar runtime do contexto anterior")
    }

    func test_replayFromOldChave_doesNotCancelCurrentAccuracyEpisode() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = preferences(pauseEnabled: false)
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(state(.checkOut, at: now.addingTimeInterval(-60)))
        let auto = SpyAutoActivities()
        auto.result = .accuracyTooLow(expectedAction: .checkIn)
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            autoActivities: auto,
            clock: FixedClock(now))
        await sut.runOnce(.foreground)
        let hadEpisode = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertTrue(hadEpisode)

        await sut.acceptedCheck(
            chave: "OLD",
            project: "P80",
            action: .checkOut,
            newState: state(.checkOut, at: now))

        let stillHasEpisode = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertTrue(stillHasEpisode)
    }
}
