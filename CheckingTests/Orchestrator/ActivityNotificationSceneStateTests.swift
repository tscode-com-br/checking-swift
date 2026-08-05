import Foundation
import XCTest
@testable import Checking

final class ActivityNotificationSceneStateTests: XCTestCase {
    private actor RecordingApplicationStateProvider:
        EvaluationApplicationStateProviding {
        private var state: EvaluationApplicationState
        private var readCountValue = 0

        init(_ state: EvaluationApplicationState) {
            self.state = state
        }

        func currentApplicationState() async -> EvaluationApplicationState {
            readCountValue += 1
            return state
        }

        func update(_ state: EvaluationApplicationState) {
            self.state = state
        }

        func readCount() -> Int {
            readCountValue
        }
    }

    private actor GatedSubmittedActivities: RunningAutomaticActivities {
        private let started = AsyncGate()
        private let release = AsyncGate()
        private let result: AutoActivitiesResult

        init(result: AutoActivitiesResult) {
            self.result = result
        }

        func execute(
            chave: String,
            userProjects: UserProjects?,
            currentState: HistoryState?,
            mixedZoneIntervalMinutes: Int,
            accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> AutomaticActivitiesExecution {
            await started.release()
            await release.wait()
            return Self.execution(for: result)
        }

        func waitUntilStarted() async {
            await started.wait()
        }

        func finish() async {
            await release.release()
        }

        private static func execution(
            for result: AutoActivitiesResult
        ) -> AutomaticActivitiesExecution {
            AutomaticActivitiesExecution(
                result: result,
                trace: AutomaticActivitiesTrace(
                    maximumStage: .submitted,
                    capture: nil,
                    failure: nil,
                    offlineDisposition: nil
                ),
                submissionContext: nil
            )
        }
    }

    private let now = iso("2026-07-31T08:00:00Z")

    func test_storeDefaultsToUnknownAndSerializesUpdates() async {
        let store = EvaluationApplicationStateStore()

        let initial = await store.currentApplicationState()
        XCTAssertEqual(initial, .unknown)
        await store.update(.inactive)
        let inactive = await store.currentApplicationState()
        XCTAssertEqual(inactive, .inactive)
        await store.update(.active)
        let active = await store.currentApplicationState()
        XCTAssertEqual(active, .active)
    }

    func test_storeRejectsAnOlderSceneTaskThatResumesAfterNewerUpdate() async {
        let store = EvaluationApplicationStateStore()
        let older = await store.reserveUpdateRevision()
        let newer = await store.reserveUpdateRevision()

        let acceptedNewer = await store.update(.background, revision: newer)
        let acceptedOlder = await store.update(.active, revision: older)
        let final = await store.currentApplicationState()

        XCTAssertTrue(acceptedNewer)
        XCTAssertFalse(acceptedOlder)
        XCTAssertEqual(final, .background)
    }

    func test_storeReservationContinuesAfterAnExplicitHigherRevision() async {
        let store = EvaluationApplicationStateStore()

        let acceptedExplicit = await store.update(.background, revision: 40)
        let next = await store.reserveUpdateRevision()
        let acceptedNext = await store.update(.active, revision: next)
        let final = await store.currentApplicationState()

        XCTAssertTrue(acceptedExplicit)
        XCTAssertEqual(next, 41)
        XCTAssertTrue(acceptedNext)
        XCTAssertEqual(final, .active)
    }

    func test_candidateStampsReceiptStateButRereadsActiveAtNotificationAndSuppressesPost() async {
        let appState = RecordingApplicationStateProvider(.background)
        let journal = RecordingEvaluationJournal()
        let notifications = SpyNotifications()
        let activities = GatedSubmittedActivities(result: submittedResult())
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            checkRepository: repository(),
            autoActivities: activities,
            notifications: notifications,
            automaticEvaluationPipeline: .candidate,
            applicationStateProvider: appState,
            clock: FixedClock(now),
            evaluationJournal: journal
        )

        let evaluation = Task { await sut.runOnce(.significantLocation) }
        await activities.waitUntilStarted()
        await appState.update(.active)
        await activities.finish()
        let completion = await evaluation.value

        XCTAssertEqual(completion.outcome, .submittedCheckIn)
        XCTAssertTrue(notifications.activityPosts.isEmpty)
        let stateReadCount = await appState.readCount()
        XCTAssertEqual(stateReadCount, 2)
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.begins.first?.appState, .background)
        XCTAssertEqual(
            snapshot.finishes.first?.terminal.notificationScheduled,
            false
        )
        XCTAssertEqual(snapshot.finishes.first?.terminal.stage, .submit)
    }

    func test_candidateRereadsBackgroundAndPostsEvenForForegroundTrigger() async {
        let appState = RecordingApplicationStateProvider(.active)
        let journal = RecordingEvaluationJournal()
        let notifications = SpyNotifications()
        let activities = GatedSubmittedActivities(result: submittedResult())
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            checkRepository: repository(),
            autoActivities: activities,
            notifications: notifications,
            automaticEvaluationPipeline: .candidate,
            applicationStateProvider: appState,
            clock: FixedClock(now),
            evaluationJournal: journal
        )

        let evaluation = Task { await sut.runOnce(.foreground) }
        await activities.waitUntilStarted()
        await appState.update(.background)
        await activities.finish()
        let completion = await evaluation.value

        XCTAssertEqual(completion.outcome, .submittedCheckIn)
        XCTAssertEqual(notifications.activityPosts.count, 1)
        XCTAssertEqual(notifications.activityPosts.first?.action, .checkIn)
        XCTAssertEqual(notifications.activityPosts.first?.local, "Unidade P80")
        let stateReadCount = await appState.readCount()
        XCTAssertEqual(stateReadCount, 2)
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.begins.first?.appState, .active)
        XCTAssertNil(
            snapshot.finishes.first?.terminal.notificationScheduled
        )
        XCTAssertEqual(snapshot.finishes.first?.terminal.stage, .notification)
    }

    func test_candidateInactiveBackgroundAndUnknownPreserveConservativeNotification() async {
        for state in [
            EvaluationApplicationState.inactive,
            .background,
            .unknown,
        ] {
            let appState = RecordingApplicationStateProvider(state)
            let notifications = SpyNotifications()
            let automatic = SpyAutoActivities()
            automatic.result = submittedResult()
            let sut = makeOrchestrator(
                prefs: activePreferences(),
                checkRepository: repository(),
                autoActivities: automatic,
                notifications: notifications,
                automaticEvaluationPipeline: .candidate,
                applicationStateProvider: appState,
                clock: FixedClock(now)
            )

            let completion = await sut.runOnce(.geofence)

            XCTAssertEqual(completion.outcome, .submittedCheckIn, "\(state)")
            XCTAssertEqual(notifications.activityPosts.count, 1, "\(state)")
            let stateReadCount = await appState.readCount()
            XCTAssertEqual(stateReadCount, 2, "\(state)")
        }
    }

    func test_candidateForegroundTriggerSuppressesWhileSceneRemainsActive() async {
        let appState = RecordingApplicationStateProvider(.active)
        let notifications = SpyNotifications()
        let automatic = SpyAutoActivities()
        automatic.result = submittedResult()
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            checkRepository: repository(),
            autoActivities: automatic,
            notifications: notifications,
            automaticEvaluationPipeline: .candidate,
            applicationStateProvider: appState,
            clock: FixedClock(now)
        )

        let completion = await sut.runOnce(.foreground)

        XCTAssertEqual(completion.outcome, .submittedCheckIn)
        XCTAssertTrue(notifications.activityPosts.isEmpty)
        let stateReadCount = await appState.readCount()
        XCTAssertEqual(stateReadCount, 2)
    }

    func test_legacyKeepsTriggerOnlyRuleAndNeverConsultsApplicationState() async {
        for testCase in [
            (trigger: OrchestratorTrigger.geofence, expectedPosts: 1),
            (trigger: OrchestratorTrigger.foreground, expectedPosts: 0),
        ] {
            let appState = RecordingApplicationStateProvider(.active)
            let notifications = SpyNotifications()
            let automatic = SpyAutoActivities()
            automatic.result = submittedResult()
            let sut = makeOrchestrator(
                prefs: activePreferences(),
                checkRepository: repository(),
                autoActivities: automatic,
                notifications: notifications,
                automaticEvaluationPipeline: .legacy,
                applicationStateProvider: appState,
                clock: FixedClock(now)
            )

            let completion = await sut.runOnce(testCase.trigger)

            XCTAssertEqual(completion.outcome, .submittedCheckIn)
            XCTAssertEqual(
                notifications.activityPosts.count,
                testCase.expectedPosts
            )
            let stateReadCount = await appState.readCount()
            XCTAssertEqual(stateReadCount, 0)
        }
    }

    private func activePreferences() -> FakeAppPreferences {
        let settings = UserSettings(
            projects: ["P80"],
            activeProject: "P80",
            automaticActivitiesEnabled: true,
            scheduledPauseEnabled: false,
            scheduledPauseFrom: "20:00",
            scheduledPauseTo: "07:00",
            suspendSaturdays: false,
            suspendSundays: false,
            notifyActivities: true,
            notifyScheduledPause: false,
            notifyAccident: false
        )
        let data = try! JSONCoding.encoder.encode(["HR70": settings])
        let preferences = FakeAppPreferences()
        preferences.chaveValue = "HR70"
        preferences.languageValue = "pt"
        preferences.userSettingsJsonValue =
            String(decoding: data, as: UTF8.self)
        return preferences
    }

    private func repository() -> FakeCheckRepository {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(
            LocationOptions(
                items: ["Unidade P80"],
                accuracyThresholdMeters: 50,
                mixedZoneIntervalMinutes: 15
            )
        )
        repository.getStateResult = .success(
            HistoryState(
                found: true,
                chave: "HR70",
                projeto: "P80",
                currentAction: .checkOut,
                currentLocal: nil,
                hasCurrentDayCheckin: false,
                lastCheckinAt: nil,
                lastCheckoutAt: now.addingTimeInterval(-600),
                transportEnabled: false
            )
        )
        return repository
    }

    private func submittedResult() -> AutoActivitiesResult {
        .submitted(
            action: .checkIn,
            local: "Unidade P80",
            newState: HistoryState(
                found: true,
                chave: "HR70",
                projeto: "P80",
                currentAction: .checkIn,
                currentLocal: "Unidade P80",
                hasCurrentDayCheckin: true,
                lastCheckinAt: now,
                lastCheckoutAt: nil,
                transportEnabled: false
            )
        )
    }
}
