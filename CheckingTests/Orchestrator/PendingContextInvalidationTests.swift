import Foundation
import XCTest
@testable import Checking

/// Invalidação determinística do slot normal candidate.
///
/// Os portões mantêm o trabalho antigo vivo enquanto o teste invalida a geração. Assim as asserções não
/// dependem de rede, Core Location, tempo real ou da ordem oportunista do executor.
final class PendingContextInvalidationTests: XCTestCase {
    private final class EffectTrapActivities: RunningAutomaticActivities, @unchecked Sendable {
        private let repository: FakeCheckRepository
        private let queue: FakeOfflineQueue
        private let notifications: SpyNotifications
        private let lock = NSLock()
        private var calls = 0

        init(
            repository: FakeCheckRepository,
            queue: FakeOfflineQueue,
            notifications: SpyNotifications
        ) {
            self.repository = repository
            self.queue = queue
            self.notifications = notifications
        }

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

            // Qualquer execução indevida torna observáveis todos os efeitos que a invalidação deve barrar.
            _ = await repository.matchLocation(1, 1, 10)
            _ = await repository.submit(
                chave: chave,
                projeto: userProjects?.activeProject ?? "P80",
                action: .checkIn,
                local: "trap",
                informe: .normal,
                eventTime: Date(timeIntervalSince1970: 1),
                clientEventId: "trap-event",
                fillForms: true
            )
            await queue.enqueue(.raw(PendingCheckEvent.Raw(
                chave: chave,
                projeto: userProjects?.activeProject ?? "P80",
                capturedAtEpochMs: 1,
                clientEventId: "trap-event",
                latitude: 1,
                longitude: 1,
                accuracyMeters: 10
            )))
            notifications.postActivityNotification(
                action: .checkIn,
                local: "trap",
                lang: "pt"
            )

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

    private actor BlockingActivities: RunningAutomaticActivities {
        private let entered = AsyncGate()
        private let releaseGate = AsyncGate()
        private var calls = 0

        func execute(
            chave: String,
            userProjects: UserProjects?,
            currentState: HistoryState?,
            mixedZoneIntervalMinutes: Int,
            accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> AutomaticActivitiesExecution {
            calls += 1
            await entered.release()
            // Intencionalmente não encerra só por cancelamento: prova que quiescence aguarda o terminal
            // canônico, em vez de considerar o pedido de cancelamento como conclusão.
            await releaseGate.wait()
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

        func waitUntilEntered() async {
            await entered.wait()
        }

        func release() async {
            await releaseGate.release()
        }

        func callCount() -> Int {
            calls
        }
    }

    private actor OrderedJournal: EvaluationJournaling {
        enum Event: Equatable {
            case begin(EvaluationID, EvaluationStage)
            case coalesce(EvaluationID, EvaluationWakeKind)
            case advance(EvaluationID, EvaluationStage)
            case finish(EvaluationID, EvaluationTerminalOutcome, EvaluationStage?)
            case clear
        }

        private var events: [Event] = []

        func begin(_ start: EvaluationStart) async {
            events.append(.begin(start.id, start.stage))
        }

        func coalesce(_ event: EvaluationCoalescence) async {
            events.append(.coalesce(event.evaluationID, event.wake))
        }

        func advance(_ progress: EvaluationProgress) async {
            events.append(.advance(progress.evaluationID, progress.stage))
        }

        func finish(id: EvaluationID, terminal: EvaluationTerminal) async {
            events.append(.finish(id, terminal.outcome, terminal.stage))
        }

        func reconcileOrphans() async {}
        func recent(limit: Int) async -> [EvaluationRecord] { [] }

        func clear() async {
            events.append(.clear)
        }

        func snapshot() -> [Event] {
            events
        }

        func clearCount() -> Int {
            events.filter { $0 == .clear }.count
        }
    }

    private actor BooleanProbe {
        private var marked = false

        func mark() {
            marked = true
        }

        func value() -> Bool {
            marked
        }
    }

    private final class EvaluationIDProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var callCount: Int { lock.withLock { count } }

        func make() -> EvaluationID {
            lock.withLock {
                count += 1
                return EvaluationID()
            }
        }
    }

    override func setUp() {
        super.setUp()
        EvaluationLog.shared.reset()
    }

    func test_pendingNormalInvalidation_finishesExactlyOnceAtAdmissionWithoutEffects() async {
        let preferences = activePreferences()
        let keyGate = AsyncGate()
        preferences.chaveGate = keyGate
        preferences.chaveGateOnCall = 1

        let repository = FakeCheckRepository()
        repository.getStateResult = .success(ucHistory(.checkOut))
        let queue = FakeOfflineQueue()
        let notifications = SpyNotifications()
        let activities = EffectTrapActivities(
            repository: repository,
            queue: queue,
            notifications: notifications
        )
        let provider = FakeLocationProvider(.unavailable)
        let journal = RecordingEvaluationJournal()
        let orchestrator = makeOrchestrator(
            prefs: preferences,
            checkRepository: repository,
            autoActivities: activities,
            notifications: notifications,
            locationProvider: provider,
            automaticEvaluationPipeline: .candidate,
            evaluationJournal: journal
        )

        let running = await orchestrator.evaluationTicket(.geofence)
        await waitUntil { preferences.chaveReadStarted }
        XCTAssertEqual(running.admission, .admitted)

        let pending = await orchestrator.evaluationTicket(.significantLocation)
        XCTAssertEqual(pending.admission, .deferred)
        let hasPendingBeforeInvalidation = await orchestrator.hasPendingNormalWakeForTest
        XCTAssertTrue(hasPendingBeforeInvalidation)

        let transition = await orchestrator.beginAutomationContextTransition()
        let pendingCompletion = await pending.completion()

        XCTAssertEqual(pendingCompletion.evaluationID, pending.evaluationID)
        XCTAssertEqual(pendingCompletion.outcome, .staleContext)
        XCTAssertTrue(pendingCompletion.admitted)
        let hasPendingAfterInvalidation = await orchestrator.hasPendingNormalWakeForTest
        XCTAssertFalse(hasPendingAfterInvalidation)

        let pendingSnapshot = await journal.snapshot()
        XCTAssertEqual(
            pendingSnapshot.begins.filter { $0.id == pending.evaluationID }.map(\.stage),
            [.admitted]
        )
        let pendingFinishes = pendingSnapshot.finishes.filter {
            $0.id == pending.evaluationID
        }
        XCTAssertEqual(pendingFinishes.count, 1)
        XCTAssertEqual(pendingFinishes.first?.terminal.outcome, .staleContext)
        XCTAssertEqual(pendingFinishes.first?.terminal.stage, .admitted)
        XCTAssertFalse(pendingSnapshot.progresses.contains {
            $0.evaluationID == pending.evaluationID
        })

        XCTAssertEqual(activities.callCount, 0)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.getStateCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertTrue(notifications.activityPosts.isEmpty)

        await keyGate.release()
        let runningCompletion = await running.completion()
        XCTAssertEqual(runningCompletion.outcome, .staleContext)
        await orchestrator.awaitAutomationQuiescence(transition)
        await orchestrator.endAutomationContextTransition(transition)

        let finalSnapshot = await journal.snapshot()
        XCTAssertEqual(
            finalSnapshot.finishes.filter { $0.id == pending.evaluationID }.count,
            1
        )
        XCTAssertEqual(activities.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertTrue(notifications.activityPosts.isEmpty)
    }

    func test_wakeWaitingAtBarrier_isNotAdoptedByNewGeneration() async {
        let preferences = activePreferences()
        let repository = FakeCheckRepository()
        let queue = FakeOfflineQueue()
        let notifications = SpyNotifications()
        let activities = EffectTrapActivities(
            repository: repository,
            queue: queue,
            notifications: notifications
        )
        let provider = FakeLocationProvider(.unavailable)
        let journal = RecordingEvaluationJournal()
        let evaluationIDs = EvaluationIDProbe()
        let orchestrator = makeOrchestrator(
            prefs: preferences,
            checkRepository: repository,
            autoActivities: activities,
            notifications: notifications,
            locationProvider: provider,
            automaticEvaluationPipeline: .candidate,
            evaluationJournal: journal,
            makeEvaluationID: { evaluationIDs.make() }
        )

        let transition = await orchestrator.beginAutomationContextTransition()
        let waitingWake = Task {
            await orchestrator.evaluationTicket(.geofence)
        }
        await waitUntil { evaluationIDs.callCount == 1 }

        await orchestrator.endAutomationContextTransition(transition)
        let ticket = await waitingWake.value
        let completion = await ticket.completion()

        XCTAssertEqual(ticket.admission, .staleContext)
        XCTAssertEqual(completion.evaluationID, ticket.evaluationID)
        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertFalse(completion.admitted)
        let isRunning = await orchestrator.isRunningForTest
        let hasPending = await orchestrator.hasPendingNormalWakeForTest
        XCTAssertFalse(isRunning)
        XCTAssertFalse(hasPending)

        let journalSnapshot = await journal.snapshot()
        XCTAssertTrue(journalSnapshot.begins.isEmpty)
        XCTAssertTrue(journalSnapshot.coalescences.isEmpty)
        XCTAssertTrue(journalSnapshot.progresses.isEmpty)
        XCTAssertTrue(journalSnapshot.finishes.isEmpty)
        XCTAssertEqual(activities.callCount, 0)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.getStateCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertTrue(notifications.activityPosts.isEmpty)
    }

    func test_cancelledTransitionOwnerStillInvalidatesPendingOldContext() async {
        let preferences = activePreferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(ucHistory(.checkOut))
        let activities = BlockingActivities()
        let journal = RecordingEvaluationJournal()
        let orchestrator = makeOrchestrator(
            prefs: preferences,
            checkRepository: repository,
            autoActivities: activities,
            automaticEvaluationPipeline: .candidate,
            evaluationJournal: journal
        )

        let running = await orchestrator.evaluationTicket(.geofence)
        await activities.waitUntilEntered()
        let pending = await orchestrator.evaluationTicket(.geofence)
        XCTAssertEqual(pending.admission, .deferred)

        let transitionCallGate = AsyncGate()
        let transitionOwner = Task {
            await transitionCallGate.wait()
            return await orchestrator.beginAutomationContextTransition()
        }
        transitionOwner.cancel()
        await transitionCallGate.release()
        let transition = await transitionOwner.value

        let pendingCompletion = await pending.completion()
        XCTAssertEqual(pendingCompletion.outcome, .staleContext)
        let snapshot = await journal.snapshot()
        XCTAssertEqual(
            snapshot.finishes.filter { $0.id == pending.evaluationID }.count,
            1
        )

        await activities.release()
        let runningCompletion = await running.completion()
        XCTAssertEqual(runningCompletion.outcome, .staleContext)
        await orchestrator.awaitAutomationQuiescence(transition)
        await orchestrator.endAutomationContextTransition(transition)
    }

    func test_destructiveOwnerClearsOnlyAfterCapturedRunningWorkReachesTerminal() async {
        let preferences = activePreferences()
        let repository = FakeCheckRepository()
        repository.getStateResult = .success(ucHistory(.checkOut))
        let activities = BlockingActivities()
        let journal = OrderedJournal()
        let orchestrator = makeOrchestrator(
            prefs: preferences,
            checkRepository: repository,
            autoActivities: activities,
            automaticEvaluationPipeline: .candidate,
            evaluationJournal: journal
        )

        let running = await orchestrator.evaluationTicket(.geofence)
        await activities.waitUntilEntered()
        let activityCallCount = await activities.callCount()
        XCTAssertEqual(activityCallCount, 1)

        let transition = await orchestrator.beginAutomationContextTransition()
        let quiescenceRequested = BooleanProbe()
        let destructiveOwner = Task {
            await quiescenceRequested.mark()
            await orchestrator.awaitAutomationQuiescence(transition)
            await journal.clear()
        }
        await waitUntil { await quiescenceRequested.value() }
        for _ in 0 ..< 8 {
            await Task.yield()
        }

        let clearCountBeforeRelease = await journal.clearCount()
        XCTAssertEqual(
            clearCountBeforeRelease,
            0,
            "clear não pode ocorrer apenas porque o cancelamento foi solicitado"
        )

        await activities.release()
        await destructiveOwner.value
        let completion = await running.completion()
        XCTAssertEqual(completion.outcome, .staleContext)
        await orchestrator.endAutomationContextTransition(transition)

        let events = await journal.snapshot()
        let finishIndex = events.firstIndex { event in
            if case .finish(let id, let outcome, _) = event {
                return id == running.evaluationID && outcome == .staleContext
            }
            return false
        }
        let clearIndex = events.firstIndex(of: .clear)
        XCTAssertNotNil(finishIndex)
        XCTAssertNotNil(clearIndex)
        if let finishIndex, let clearIndex {
            XCTAssertLessThan(finishIndex, clearIndex)
        }
        XCTAssertEqual(events.filter { event in
            if case .finish(let id, _, _) = event {
                return id == running.evaluationID
            }
            return false
        }.count, 1)
        let finalClearCount = await journal.clearCount()
        XCTAssertEqual(finalClearCount, 1)
    }

    private func activePreferences() -> FakeAppPreferences {
        let preferences = FakeAppPreferences()
        preferences.chaveValue = "HR70"
        preferences.languageValue = "pt"
        preferences.userSettingsJsonValue = activeSettingsJSON()
        return preferences
    }

    private func activeSettingsJSON() -> String {
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
        return String(decoding: data, as: UTF8.self)
    }
}
