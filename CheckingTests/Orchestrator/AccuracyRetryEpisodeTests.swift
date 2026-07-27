import XCTest
@testable import Checking

final class AccuracyRetryEpisodeTests: XCTestCase {
    private final class MutableClock: Clock, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) { self.value = value }
        func now() -> Date { lock.withLock { value } }
        func advance(_ interval: TimeInterval) {
            lock.withLock { value = value.addingTimeInterval(interval) }
        }
    }

    private final class ScriptedAutoActivities: RunningAutomaticActivities, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [AutoActivitiesResult]
        private var fallback: AutoActivitiesResult
        private var gates: [Int: AsyncGate]
        private var calls = 0

        init(
            _ results: [AutoActivitiesResult],
            fallback: AutoActivitiesResult = .noAction,
            gates: [Int: AsyncGate] = [:]
        ) {
            self.results = results
            self.fallback = fallback
            self.gates = gates
        }

        var callCount: Int { lock.withLock { calls } }

        func setFallback(_ result: AutoActivitiesResult) {
            lock.withLock { fallback = result }
        }

        func callAsFunction(
            chave: String,
            userProjects: UserProjects?,
            currentState: HistoryState?,
            mixedZoneIntervalMinutes: Int,
            accuracyThresholdMeters: Int
        ) async -> AutoActivitiesResult {
            let snapshot: (result: AutoActivitiesResult, gate: AsyncGate?) = lock.withLock {
                let index = calls
                calls += 1
                let result = index < results.count ? results[index] : fallback
                return (result, gates[index])
            }
            if let gate = snapshot.gate { await gate.wait() }
            return snapshot.result
        }
    }

    private final class CountingLocationProvider: LocationProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var result: LocationCapture

        init(_ result: LocationCapture) { self.result = result }
        var callCount: Int { lock.withLock { calls } }

        func capture(_ accuracyThresholdMeters: Int) async -> LocationCapture {
            lock.withLock { calls += 1 }
            return result
        }
    }

    private final class BlockingLowAccuracyNotifications: AutoActivityNotifying, @unchecked Sendable {
        let postGate = AsyncGate()
        private let lock = NSLock()
        private var postStartedValue = false
        private var clears = 0

        var postStarted: Bool { lock.withLock { postStartedValue } }
        var clearCount: Int { lock.withLock { clears } }

        func postAccidentNotification(lang: String) {}
        func postActivityNotification(action: CheckAction, local: String?, lang: String) {}
        func postReauthNotification(lang: String) {}
        func postScheduledPauseTransition(started: Bool, lang: String) {}
        func postLowAccuracyNotification(expectedAction: CheckAction?, lang: String) async {
            lock.withLock { postStartedValue = true }
            await postGate.wait()
        }
        func clearLowAccuracyNotification() async {
            lock.withLock { clears += 1 }
        }
    }

    private func activePreferences(
        chave: String = "HR70",
        project: String = "P80",
        automaticActivitiesEnabled: Bool = true,
        scheduledPauseEnabled: Bool = false
    ) -> FakeAppPreferences {
        let settings = UserSettings(
            projects: project.isEmpty ? [] : [project],
            activeProject: project,
            automaticActivitiesEnabled: automaticActivitiesEnabled,
            scheduledPauseEnabled: scheduledPauseEnabled,
            scheduledPauseFrom: scheduledPauseEnabled ? "00:00" : "20:00",
            scheduledPauseTo: scheduledPauseEnabled ? "23:59" : "07:00",
            suspendSaturdays: false,
            suspendSundays: false)
        let data = try! JSONCoding.encoder.encode([chave: settings])
        let prefs = FakeAppPreferences()
        prefs.chaveValue = chave
        prefs.languageValue = "pt"
        prefs.userSettingsJsonValue = String(data: data, encoding: .utf8)!
        return prefs
    }

    func test_firstLowStartsOne180SecondEpisode_andAdditionalLowDoesNotResetIt() async {
        let now = iso("2026-06-18T12:00:00Z")
        let clock = MutableClock(now)
        let sleeper = ControlledAccuracyRetrySleeper()
        let backstop = SpyAppRefreshScheduler()
        let notifications = SpyNotifications()
        let auto = ScriptedAutoActivities(
            [.accuracyTooLow(expectedAction: .checkIn), .accuracyTooLow(expectedAction: .checkIn)],
            fallback: .noAction)
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            autoActivities: auto,
            notifications: notifications,
            clock: clock,
            accuracyRetrySleeper: sleeper,
            appRefreshScheduler: backstop)

        await sut.runOnce(.foreground)
        await waitUntil { (await sleeper.delays()).count == 1 }
        let originalDue = await sut.nextAccuracyRetryAtForTest

        await sut.runOnce(.foreground)

        let dueAfterAdditionalLow = await sut.nextAccuracyRetryAtForTest
        let delaysAfterAdditionalLow = await sleeper.delays()
        XCTAssertEqual(originalDue, now.addingTimeInterval(180))
        XCTAssertEqual(dueAfterAdditionalLow, originalDue)
        XCTAssertEqual(delaysAfterAdditionalLow, [180_000])
        XCTAssertEqual(backstop.dates, [now.addingTimeInterval(180)])
        XCTAssertEqual(notifications.lowAccuracyPosts.count, 1)
        XCTAssertEqual(notifications.lowAccuracyPosts.first?.expectedAction, .checkIn)

        auto.setFallback(.noAction)
        await sut.runOnce(.foreground)
        let hasEpisodeAfterResolution = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertFalse(hasEpisodeAfterResolution)
    }

    func test_dueRetryRepeatsEvery180SecondsWhileAccuracyRemainsLow_withoutRepeatingNotification() async {
        let now = iso("2026-06-18T12:00:00Z")
        let clock = MutableClock(now)
        let sleeper = ControlledAccuracyRetrySleeper()
        let backstop = SpyAppRefreshScheduler()
        let notifications = SpyNotifications()
        let auto = ScriptedAutoActivities([
            .accuracyTooLow(expectedAction: nil),
            .accuracyTooLow(expectedAction: nil),
            .noAction,
        ])
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            autoActivities: auto,
            notifications: notifications,
            clock: clock,
            accuracyRetrySleeper: sleeper,
            appRefreshScheduler: backstop)

        await sut.runOnce(.foreground)
        await waitUntil { await sleeper.waitingCount() == 1 }
        clock.advance(180)
        await sleeper.releaseNext()
        await waitUntil { auto.callCount == 2 && backstop.dates.count == 2 }
        await waitUntil { await sleeper.waitingCount() == 1 }

        let delays = await sleeper.delays()
        XCTAssertEqual(delays, [180_000, 180_000])
        XCTAssertEqual(
            backstop.dates,
            [now.addingTimeInterval(180), now.addingTimeInterval(360)])
        XCTAssertEqual(notifications.lowAccuracyPosts.count, 1)

        clock.advance(180)
        await sleeper.releaseNext()
        await waitUntil { auto.callCount == 3 }

        let hasEpisodeAfterResolution = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertFalse(hasEpisodeAfterResolution)
        XCTAssertEqual(notifications.clearLowAccuracyCount, 1)
        XCTAssertEqual(backstop.clearRetryDeadlineCount, 1)
    }

    func test_dueRetryIsPreservedWhileAnotherEvaluationRuns_andDrainedAfterItFinishes() async {
        let now = iso("2026-06-18T12:00:00Z")
        let clock = MutableClock(now)
        let sleeper = ControlledAccuracyRetrySleeper()
        let backstop = SpyAppRefreshScheduler()
        let secondCallGate = AsyncGate()
        let auto = ScriptedAutoActivities(
            [
                .accuracyTooLow(expectedAction: .checkIn),
                .locationTimeout,
                .noAction,
            ],
            gates: [1: secondCallGate])
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            autoActivities: auto,
            clock: clock,
            accuracyRetrySleeper: sleeper,
            appRefreshScheduler: backstop)

        await sut.runOnce(.foreground)
        await waitUntil { await sleeper.waitingCount() == 1 }
        let concurrentEvaluation = Task { await sut.runOnce(.foreground) }
        await waitUntil { auto.callCount == 2 }

        clock.advance(180)
        await sleeper.releaseNext()
        await waitUntil { await sut.hasPendingAccuracyRetryForTest }
        XCTAssertEqual(auto.callCount, 2)

        await secondCallGate.release()
        await concurrentEvaluation.value
        await waitUntil { auto.callCount == 3 }

        let hasPendingRetry = await sut.hasPendingAccuracyRetryForTest
        let hasEpisode = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertFalse(hasPendingRetry)
        XCTAssertFalse(hasEpisode)
    }

    func test_timeoutDoesNotOpenEpisode_andDoesNotResetExistingEpisode() async {
        let now = iso("2026-06-18T12:00:00Z")
        let clock = MutableClock(now)
        let sleeper = ControlledAccuracyRetrySleeper()
        let backstop = SpyAppRefreshScheduler()
        let auto = ScriptedAutoActivities([
            .locationTimeout,
            .accuracyTooLow(expectedAction: .checkIn),
            .locationTimeout,
            .noPermission,
        ])
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            autoActivities: auto,
            clock: clock,
            accuracyRetrySleeper: sleeper,
            appRefreshScheduler: backstop)

        await sut.runOnce(.foreground)
        let timeoutOpenedEpisode = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertFalse(timeoutOpenedEpisode)
        XCTAssertTrue(backstop.dates.isEmpty)

        await sut.runOnce(.foreground)
        let dueAt = await sut.nextAccuracyRetryAtForTest
        await sut.runOnce(.foreground)

        let dueAfterTimeout = await sut.nextAccuracyRetryAtForTest
        XCTAssertEqual(dueAfterTimeout, dueAt)
        XCTAssertEqual(backstop.dates.count, 1)

        await sut.runOnce(.foreground)
        let hasEpisodeAfterPermissionLoss = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertFalse(hasEpisodeAfterPermissionLoss)
    }

    func test_definitiveResultsCancelEpisodeAndBackstop() async {
        let terminalResults: [AutoActivitiesResult] = [
            .noAction,
            .submitted(action: .checkIn, local: "P80", newState: ucHistory(.checkIn)),
            .networkError,
            .notConfigured,
            .noPermission,
        ]

        for terminal in terminalResults {
            let sleeper = ControlledAccuracyRetrySleeper()
            let backstop = SpyAppRefreshScheduler()
            let notifications = SpyNotifications()
            let auto = ScriptedAutoActivities(
                [.accuracyTooLow(expectedAction: .checkIn), terminal])
            let sut = makeOrchestrator(
                prefs: activePreferences(),
                autoActivities: auto,
                notifications: notifications,
                accuracyRetrySleeper: sleeper,
                appRefreshScheduler: backstop)

            await sut.runOnce(.foreground)
            await sut.runOnce(.foreground)

            let hasEpisode = await sut.hasAccuracyRetryEpisodeForTest
            XCTAssertFalse(hasEpisode, "\(terminal)")
            XCTAssertEqual(backstop.clearRetryDeadlineCount, 1, "\(terminal)")
            XCTAssertEqual(notifications.clearLowAccuracyCount, 1, "\(terminal)")
        }
    }

    func test_autoOffPauseAndAccountOrProjectChangeCancelEpisode() async {
        // Toggle OFF.
        do {
            let prefs = activePreferences()
            let auto = ScriptedAutoActivities([.accuracyTooLow(expectedAction: .checkIn)])
            let sut = makeOrchestrator(prefs: prefs, autoActivities: auto)
            await sut.runOnce(.foreground)
            let off = activePreferences(automaticActivitiesEnabled: false)
            prefs.userSettingsJsonValue = off.userSettingsJsonValue
            await sut.runOnce(.foreground)
            let hasEpisode = await sut.hasAccuracyRetryEpisodeForTest
            XCTAssertFalse(hasEpisode)
        }

        // Pausa programada.
        do {
            let now = iso("2026-06-18T09:09:09Z")
            let prefs = activePreferences()
            let repository = FakeCheckRepository()
            repository.getStateResult = .success(
                ucHistory(.checkOut, lastCheckoutAt: now))
            let auto = ScriptedAutoActivities([.accuracyTooLow(expectedAction: .checkIn)])
            let sut = makeOrchestrator(
                prefs: prefs,
                checkRepository: repository,
                autoActivities: auto,
                clock: FixedClock(now))
            await sut.runOnce(.foreground)
            let paused = activePreferences(scheduledPauseEnabled: true)
            prefs.userSettingsJsonValue = paused.userSettingsJsonValue
            await sut.runOnce(.foreground)
            let hasEpisode = await sut.hasAccuracyRetryEpisodeForTest
            XCTAssertFalse(hasEpisode)
        }

        // Projeto diferente.
        do {
            let prefs = activePreferences()
            let auto = ScriptedAutoActivities([.accuracyTooLow(expectedAction: .checkIn)])
            let sut = makeOrchestrator(prefs: prefs, autoActivities: auto)
            await sut.runOnce(.foreground)
            let changed = activePreferences(project: "P81")
            prefs.userSettingsJsonValue = changed.userSettingsJsonValue
            await sut.runOnce(.foreground)
            let hasEpisode = await sut.hasAccuracyRetryEpisodeForTest
            XCTAssertFalse(hasEpisode)
        }

        // Chave vazia.
        do {
            let prefs = activePreferences()
            let auto = ScriptedAutoActivities([.accuracyTooLow(expectedAction: .checkIn)])
            let sut = makeOrchestrator(prefs: prefs, autoActivities: auto)
            await sut.runOnce(.foreground)
            prefs.chaveValue = ""
            await sut.runOnce(.foreground)
            let hasEpisode = await sut.hasAccuracyRetryEpisodeForTest
            XCTAssertFalse(hasEpisode)
        }
    }

    func test_scheduledPauseAwaitingCheckoutPreservesEpisodeUntilAutomationCanCheckout() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = activePreferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(
            ucHistory(.checkIn, currentLocal: "Unidade P80", lastCheckinAt: now))
        let auto = ScriptedAutoActivities([
            .accuracyTooLow(expectedAction: .checkOut),
            .accuracyTooLow(expectedAction: .checkOut),
        ])
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            autoActivities: auto,
            clock: FixedClock(now))

        await sut.runOnce(.foreground)
        prefs.userSettingsJsonValue =
            activePreferences(scheduledPauseEnabled: true).userSettingsJsonValue
        await sut.runOnce(.foreground)

        let hasEpisode = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertTrue(hasEpisode)
        XCTAssertEqual(auto.callCount, 2)
        XCTAssertTrue(
            prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"awaitingCheckout\""))
    }

    func test_scheduledPauseStateFailurePreservesEpisodeAndDoesNotRunEngineBlindly() async {
        let now = iso("2026-06-18T09:09:09Z")
        let prefs = activePreferences()
        let repository = FakeCheckRepository()
        let scheduler = SpyAppRefreshScheduler()
        let auto = ScriptedAutoActivities([.accuracyTooLow(expectedAction: .checkIn)])
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            autoActivities: auto,
            clock: FixedClock(now),
            appRefreshScheduler: scheduler)

        await sut.runOnce(.foreground)
        repository.getStateResult = .failure(.network)
        prefs.userSettingsJsonValue =
            activePreferences(scheduledPauseEnabled: true).userSettingsJsonValue
        await sut.runOnce(.foreground)

        let hasEpisode = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertTrue(hasEpisode)
        XCTAssertEqual(auto.callCount, 1)
        XCTAssertEqual(
            scheduler.scheduledPauseDates.last,
            now.addingTimeInterval(
                BackgroundCheckOrchestrator.scheduledPauseActivationDelay))
        XCTAssertTrue(
            prefs.scheduledPauseDeferralJsonValue.contains("\"phase\":\"awaitingCheckout\""))
    }

    func test_timerBypassesMovementSkipDuringEpisode() async {
        let provider = CountingLocationProvider(.success(lat: 1.0, lon: 1.0, accuracyMeters: 5))
        let auto = ScriptedAutoActivities(
            [.accuracyTooLow(expectedAction: .checkIn), .locationTimeout, .noPermission])
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            autoActivities: auto,
            locationProvider: provider)

        await sut.runOnce(.foreground)
        await sut.runOnce(.timer)

        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(auto.callCount, 2)

        await sut.runOnce(.foreground)
    }

    func test_lowAccuracyPreflightNeverCreatesBaselineOrSkip() async {
        let provider = CountingLocationProvider(.success(lat: 1.0, lon: 1.0, accuracyMeters: 80))
        let auto = ScriptedAutoActivities([], fallback: .locationTimeout)
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            autoActivities: auto,
            locationProvider: provider)

        await sut.runOnce(.timer)
        await sut.runOnce(.timer)

        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(auto.callCount, 2)
    }

    func test_invalidationDuringInFlightLowResultPreventsEpisodeRecreation() async {
        let resultGate = AsyncGate()
        let auto = ScriptedAutoActivities(
            [.accuracyTooLow(expectedAction: .checkIn)],
            gates: [0: resultGate])
        let notifications = SpyNotifications()
        let scheduler = SpyAppRefreshScheduler()
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            autoActivities: auto,
            notifications: notifications,
            appRefreshScheduler: scheduler)

        let evaluation = Task { await sut.runOnce(.foreground) }
        await waitUntil { auto.callCount == 1 }

        await sut.invalidateAccuracyRetry()
        await resultGate.release()
        await evaluation.value

        let hasEpisode = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertFalse(hasEpisode)
        XCTAssertTrue(scheduler.dates.isEmpty)
        XCTAssertEqual(scheduler.clearRetryDeadlineCount, 1)
        XCTAssertEqual(notifications.lowAccuracyPosts.count, 0)
    }

    func test_invalidationDuringColdRestoreCannotBecomeRunBaseline() async {
        let prefs = activePreferences()
        let restoreGate = AsyncGate()
        prefs.accuracyRetryEpisodeGate = restoreGate
        let auto = ScriptedAutoActivities([
            .accuracyTooLow(expectedAction: .checkIn),
        ])
        let sut = makeOrchestrator(prefs: prefs, autoActivities: auto)

        let evaluation = Task { await sut.runOnce(.foreground) }
        await waitUntil { await sut.isRunningForTest }

        await sut.invalidateAccuracyRetry()
        await restoreGate.release()
        await evaluation.value

        XCTAssertEqual(auto.callCount, 0)
        let hasEpisode = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertFalse(hasEpisode)
    }

    func test_lowEpisodePersistsNotificationPendingBeforePost_thenMarksPosted() async throws {
        let prefs = activePreferences()
        let notifications = BlockingLowAccuracyNotifications()
        let sut = makeOrchestrator(
            prefs: prefs,
            autoActivities: ScriptedAutoActivities([
                .accuracyTooLow(expectedAction: .checkIn),
            ]),
            notifications: notifications,
            appRefreshScheduler: SpyAppRefreshScheduler())

        let evaluation = Task { await sut.runOnce(.foreground) }
        await waitUntil { notifications.postStarted }

        let pendingData = try XCTUnwrap(prefs.accuracyRetryEpisodeJsonValue.data(using: .utf8))
        let pendingJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: pendingData) as? [String: Any])
        XCTAssertEqual(pendingJSON["notificationPosted"] as? Bool, false)

        await notifications.postGate.release()
        await evaluation.value

        let postedData = try XCTUnwrap(prefs.accuracyRetryEpisodeJsonValue.data(using: .utf8))
        let postedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: postedData) as? [String: Any])
        XCTAssertEqual(postedJSON["notificationPosted"] as? Bool, true)

        await sut.invalidateAccuracyRetry()
    }

    func test_invalidationWhileNotificationIsPostingLeavesNoEpisodeOrNotification() async {
        let prefs = activePreferences()
        let notifications = BlockingLowAccuracyNotifications()
        let scheduler = SpyAppRefreshScheduler()
        let sut = makeOrchestrator(
            prefs: prefs,
            autoActivities: ScriptedAutoActivities([
                .accuracyTooLow(expectedAction: .checkIn),
            ]),
            notifications: notifications,
            appRefreshScheduler: scheduler)

        let evaluation = Task { await sut.runOnce(.foreground) }
        await waitUntil { notifications.postStarted }

        await sut.invalidateAccuracyRetry()
        await notifications.postGate.release()
        await evaluation.value

        let hasEpisode = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertFalse(hasEpisode)
        XCTAssertTrue(prefs.accuracyRetryEpisodeJsonValue.isEmpty)
        XCTAssertGreaterThanOrEqual(scheduler.clearRetryDeadlineCount, 1)
        XCTAssertGreaterThanOrEqual(notifications.clearCount, 1)
    }

    func test_lowResultRereadsPersistedContextBeforeCreatingEpisode() async {
        let prefs = activePreferences()
        let resultGate = AsyncGate()
        let auto = ScriptedAutoActivities(
            [.accuracyTooLow(expectedAction: .checkIn)],
            gates: [0: resultGate])
        let scheduler = SpyAppRefreshScheduler()
        let sut = makeOrchestrator(
            prefs: prefs,
            autoActivities: auto,
            appRefreshScheduler: scheduler)

        let evaluation = Task { await sut.runOnce(.foreground) }
        await waitUntil { auto.callCount == 1 }
        let disabled = activePreferences(automaticActivitiesEnabled: false)
        prefs.userSettingsJsonValue = disabled.userSettingsJsonValue
        await resultGate.release()
        await evaluation.value

        let hasEpisode = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertFalse(hasEpisode)
        XCTAssertTrue(scheduler.dates.isEmpty)
    }

    func test_publicInvalidationClearsColdPersistedEpisodeWithoutRestoringIt() async {
        let prefs = activePreferences()
        let first = makeOrchestrator(
            prefs: prefs,
            autoActivities: ScriptedAutoActivities([
                .accuracyTooLow(expectedAction: .checkIn),
            ]),
            accuracyRetrySleeper: ControlledAccuracyRetrySleeper(),
            appRefreshScheduler: SpyAppRefreshScheduler())
        await first.runOnce(.foreground)
        XCTAssertFalse(prefs.accuracyRetryEpisodeJsonValue.isEmpty)

        let scheduler = SpyAppRefreshScheduler()
        let notifications = SpyNotifications()
        let cold = makeOrchestrator(
            prefs: prefs,
            notifications: notifications,
            accuracyRetrySleeper: ControlledAccuracyRetrySleeper(),
            appRefreshScheduler: scheduler)

        await cold.invalidateAccuracyRetry()

        XCTAssertTrue(prefs.accuracyRetryEpisodeJsonValue.isEmpty)
        XCTAssertEqual(scheduler.clearRetryDeadlineCount, 1)
        XCTAssertEqual(notifications.lowAccuracyPosts.count, 0)
        XCTAssertEqual(notifications.clearLowAccuracyCount, 1)

        await first.invalidateAccuracyRetry()
    }

    func test_persistedEpisodeLetsSharedBackgroundHandlerRetryAfterProcessRecreation() async {
        let now = iso("2026-06-18T12:00:00Z")
        let clock = MutableClock(now)
        let prefs = activePreferences()
        let firstAuto = ScriptedAutoActivities([.accuracyTooLow(expectedAction: .checkIn)])
        let first = makeOrchestrator(
            prefs: prefs,
            autoActivities: firstAuto,
            clock: clock,
            accuracyRetrySleeper: ControlledAccuracyRetrySleeper(),
            appRefreshScheduler: SpyAppRefreshScheduler())

        await first.runOnce(.foreground)
        XCTAssertFalse(prefs.accuracyRetryEpisodeJsonValue.isEmpty)

        clock.advance(180)
        let restoredAuto = ScriptedAutoActivities([.noAction])
        let restoredBackstop = SpyAppRefreshScheduler()
        let restoredNotifications = SpyNotifications()
        let restored = makeOrchestrator(
            prefs: prefs,
            autoActivities: restoredAuto,
            notifications: restoredNotifications,
            clock: clock,
            accuracyRetrySleeper: ControlledAccuracyRetrySleeper(),
            appRefreshScheduler: restoredBackstop)

        await restored.runOnce(.accuracyRetry)

        XCTAssertEqual(restoredAuto.callCount, 1)
        XCTAssertTrue(prefs.accuracyRetryEpisodeJsonValue.isEmpty)
        XCTAssertEqual(restoredBackstop.clearRetryDeadlineCount, 1)
        XCTAssertEqual(restoredNotifications.lowAccuracyPosts.count, 0)
        XCTAssertEqual(restoredNotifications.clearLowAccuracyCount, 1)

        // Encerra também a instância que simulou o processo anterior, evitando deixar seu sleeper pendente.
        await first.runOnce(.foreground)
    }
}
