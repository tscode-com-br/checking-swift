import Foundation
import XCTest
@testable import Checking

/// Provas do slot normal bounded introduzido pelo pipeline candidato.
///
/// Os testes mantêm a primeira avaliação suspensa em seams controlados e observam tickets, journal e
/// concorrência. Nenhum deles depende de sleep real, Core Location ou rede.
final class PendingNormalWakeTests: XCTestCase {
    private actor FirstTimerKeyPreferences: AppPreferencesReading {
        private let settingsJSON: String
        private let firstReadStarted = AsyncGate()
        private let firstReadRelease = AsyncGate()
        private var keyReadCount = 0
        private var seenAccidents: Set<Int> = []
        private var flags: [String: Bool] = [:]
        private var retryEpisodeJSON = ""
        private var pauseDeferralJSON = ""

        init(settingsJSON: String) {
            self.settingsJSON = settingsJSON
        }

        func chave() async -> String {
            keyReadCount += 1
            guard keyReadCount == 1 else { return "HR70" }
            await firstReadStarted.release()
            await firstReadRelease.wait()
            return ""
        }

        func language() async -> String { "pt" }
        func userSettingsJson() async -> String { settingsJSON }
        func backgroundLocationConsentAt() async -> String { "2026-01-01T00:00:00Z" }
        func seenAccidentIds() async -> Set<Int> { seenAccidents }
        func setSeenAccidentIds(_ ids: Set<Int>) async { seenAccidents = ids }
        func getFlag(_ name: String) async -> Bool { flags[name] ?? false }
        func setFlag(_ name: String, _ value: Bool) async { flags[name] = value }
        func accuracyRetryEpisodeJson() async -> String { retryEpisodeJSON }
        func setAccuracyRetryEpisodeJson(_ json: String) async { retryEpisodeJSON = json }
        func scheduledPauseDeferralJson() async -> String { pauseDeferralJSON }
        func setScheduledPauseDeferralJson(_ json: String) async { pauseDeferralJSON = json }

        func waitUntilFirstKeyRead() async {
            await firstReadStarted.wait()
        }

        func releaseFirstKeyRead() async {
            await firstReadRelease.release()
        }
    }

    private actor ScriptedAutoActivities: RunningAutomaticActivities {
        struct Step: Sendable {
            let result: AutoActivitiesResult
            let gate: AsyncGate?

            init(_ result: AutoActivitiesResult, gate: AsyncGate? = nil) {
                self.result = result
                self.gate = gate
            }
        }

        struct Snapshot: Sendable {
            let callCount: Int
            let activeCount: Int
            let maximumActiveCount: Int
        }

        private let steps: [Step]
        private var callCount = 0
        private var activeCount = 0
        private var maximumActiveCount = 0

        init(_ steps: [Step]) {
            self.steps = steps
        }

        func execute(
            chave: String,
            userProjects: UserProjects?,
            currentState: HistoryState?,
            mixedZoneIntervalMinutes: Int,
            accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> AutomaticActivitiesExecution {
            let index = callCount
            callCount += 1
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)

            let step = index < steps.count ? steps[index] : Step(.noAction)
            await step.gate?.wait()
            activeCount -= 1

            let maximumStage: AutomaticActivitiesStage
            switch step.result {
            case .submitted:
                maximumStage = .submitted
            case .noAction:
                maximumStage = .decisionCompleted
            case .accuracyTooLow, .networkError:
                maximumStage = .matched
            case .locationTimeout, .noPermission:
                maximumStage = .captureStarted
            case .notConfigured:
                maximumStage = .started
            }
            return AutomaticActivitiesExecution(
                result: step.result,
                trace: AutomaticActivitiesTrace(
                    maximumStage: maximumStage,
                    capture: nil,
                    failure: nil,
                    offlineDisposition: nil
                ),
                submissionContext: nil
            )
        }

        func snapshot() -> Snapshot {
            Snapshot(
                callCount: callCount,
                activeCount: activeCount,
                maximumActiveCount: maximumActiveCount
            )
        }
    }

    private final class ConcurrencyBackgroundTaskGuard:
        BackgroundTaskGuard,
        BackgroundExecutionLeasing,
        @unchecked Sendable
    {
        struct Snapshot: Sendable {
            let beginCount: Int
            let endCount: Int
            let activeCount: Int
            let maximumActiveCount: Int
        }

        private let lock = NSLock()
        private var nextToken = 1
        private var beginCount = 0
        private var endedTokens: Set<Int> = []
        private var activeCount = 0
        private var maximumActiveCount = 0

        func begin() async -> Int {
            lock.withLock {
                let token = nextToken
                nextToken += 1
                beginCount += 1
                activeCount += 1
                maximumActiveCount = max(maximumActiveCount, activeCount)
                return token
            }
        }

        func end(_ token: Int) {
            lock.withLock {
                guard endedTokens.insert(token).inserted else { return }
                activeCount -= 1
            }
        }

        func begin(
            name: String,
            onExpiration: @escaping @Sendable () -> Void
        ) async -> BackgroundExecutionLease {
            let token = await begin()
            let lease = BackgroundExecutionLease(onExpiration: onExpiration)
            lease.installEndHandler { [weak self] in
                self?.end(token)
            }
            return lease
        }

        func snapshot() -> Snapshot {
            lock.withLock {
                Snapshot(
                    beginCount: beginCount,
                    endCount: endedTokens.count,
                    activeCount: activeCount,
                    maximumActiveCount: maximumActiveCount
                )
            }
        }
    }

    private actor CompletionProbe {
        private var value: EvaluationCompletion?

        func record(_ completion: EvaluationCompletion) {
            value = completion
        }

        func snapshot() -> EvaluationCompletion? {
            value
        }
    }

    private actor PendingExpirationJournal: EvaluationJournaling {
        struct Progress: Sendable, Equatable {
            let evaluationID: EvaluationID
            let stage: EvaluationStage
        }

        struct Finish: Sendable, Equatable {
            let evaluationID: EvaluationID
            let outcome: EvaluationTerminalOutcome
            let stage: EvaluationStage?
        }

        struct OwnerExpiration: Sendable, Equatable {
            let evaluationID: EvaluationID
            let owner: EvaluationJournalOwnerKind
            let cancelledCanonicalWork: Bool
        }

        struct Snapshot: Sendable {
            let progresses: [Progress]
            let finishes: [Finish]
            let ownerExpirations: [OwnerExpiration]
        }

        private var progresses: [Progress] = []
        private var finishes: [Finish] = []
        private var ownerExpirations: [OwnerExpiration] = []

        func begin(_ start: EvaluationStart) async {}
        func coalesce(_ event: EvaluationCoalescence) async {}

        func advance(_ progress: EvaluationProgress) async {
            progresses.append(Progress(
                evaluationID: progress.evaluationID,
                stage: progress.stage
            ))
        }

        func recordOwnerExpiration(
            evaluationID: EvaluationID,
            owner: EvaluationJournalOwnerKind,
            cancelledCanonicalWork: Bool
        ) async {
            ownerExpirations.append(OwnerExpiration(
                evaluationID: evaluationID,
                owner: owner,
                cancelledCanonicalWork: cancelledCanonicalWork
            ))
        }

        func finish(id: EvaluationID, terminal: EvaluationTerminal) async {
            finishes.append(Finish(
                evaluationID: id,
                outcome: terminal.outcome,
                stage: terminal.stage
            ))
        }

        func reconcileOrphans() async {}
        func recent(limit: Int) async -> [EvaluationRecord] { [] }
        func clear() async {}

        func snapshot() -> Snapshot {
            Snapshot(
                progresses: progresses,
                finishes: finishes,
                ownerExpirations: ownerExpirations
            )
        }
    }

    private let now = iso("2026-07-31T08:00:00Z")

    override func setUp() {
        super.setUp()
        EvaluationLog.shared.reset()
    }

    func test_candidateTimerRunning_defersGeofenceAndRunsItAsFollowUp() async {
        let firstTimerPreferences = FirstTimerKeyPreferences(
            settingsJSON: activeSettingsJSON()
        )
        let followUpGate = AsyncGate()
        let activities = ScriptedAutoActivities([
            .init(.noAction, gate: followUpGate),
        ])
        let journal = RecordingEvaluationJournal()
        let backgroundGuard = ConcurrencyBackgroundTaskGuard()
        let orchestrator = makeCandidateOrchestrator(
            preferences: firstTimerPreferences,
            activities: activities,
            journal: journal,
            backgroundGuard: backgroundGuard,
            backgroundExecutionLeasing: backgroundGuard
        )

        let timerTicket = await orchestrator.evaluationTicket(.timer)
        XCTAssertEqual(timerTicket.admission, .admitted)
        await firstTimerPreferences.waitUntilFirstKeyRead()

        let geofenceTicket = await orchestrator.evaluationTicket(.geofence)
        XCTAssertEqual(geofenceTicket.admission, .deferred)
        XCTAssertNotEqual(geofenceTicket.evaluationID, timerTicket.evaluationID)
        let hasPendingBeforeRelease = await orchestrator.hasPendingNormalWakeForTest
        XCTAssertTrue(hasPendingBeforeRelease)

        await firstTimerPreferences.releaseFirstKeyRead()
        let timerCompletion = await timerTicket.completion()
        XCTAssertEqual(timerCompletion.outcome, .noKey)

        await waitUntil {
            await activities.snapshot().callCount == 1
        }
        let pendingWhileFollowUpRuns = await orchestrator.hasPendingNormalWakeForTest
        XCTAssertFalse(pendingWhileFollowUpRuns)
        await followUpGate.release()

        let geofenceCompletion = await geofenceTicket.completion()
        XCTAssertEqual(geofenceCompletion.evaluationID, geofenceTicket.evaluationID)
        XCTAssertEqual(geofenceCompletion.outcome, .noAction)

        let activitySnapshot = await activities.snapshot()
        XCTAssertEqual(activitySnapshot.callCount, 1)
        XCTAssertEqual(activitySnapshot.maximumActiveCount, 1)
        XCTAssertEqual(activitySnapshot.activeCount, 0)

        let guardSnapshot = backgroundGuard.snapshot()
        XCTAssertEqual(guardSnapshot.beginCount, 2)
        XCTAssertEqual(guardSnapshot.endCount, 2)
        XCTAssertEqual(guardSnapshot.maximumActiveCount, 1)
        XCTAssertEqual(guardSnapshot.activeCount, 0)

        let journalSnapshot = await journal.snapshot()
        XCTAssertEqual(journalSnapshot.finishes.map(\.id), [
            timerTicket.evaluationID,
            geofenceTicket.evaluationID,
        ])
    }

    func test_candidateRunningEvaluation_keepsOrdinaryForegroundOutsidePendingQueues() async {
        let preferences = FirstTimerKeyPreferences(
            settingsJSON: activeSettingsJSON()
        )
        let activities = ScriptedAutoActivities([])
        let journal = RecordingEvaluationJournal()
        let orchestrator = makeCandidateOrchestrator(
            preferences: preferences,
            activities: activities,
            journal: journal
        )

        let running = await orchestrator.evaluationTicket(.timer)
        await preferences.waitUntilFirstKeyRead()

        let foreground = await orchestrator.evaluationTicket(.foreground)
        let foregroundCompletion = await foreground.completion()

        XCTAssertEqual(foreground.admission, .legacyDropped)
        XCTAssertEqual(foregroundCompletion.outcome, .notAdmitted)
        XCTAssertFalse(foregroundCompletion.admitted)
        let hasPendingNormal = await orchestrator.hasPendingNormalWakeForTest
        XCTAssertFalse(hasPendingNormal)

        await preferences.releaseFirstKeyRead()
        let runningCompletion = await running.completion()
        let journalSnapshot = await journal.snapshot()
        XCTAssertEqual(runningCompletion.outcome, .noKey)
        XCTAssertTrue(journalSnapshot.begins.allSatisfy {
            $0.trigger != .foreground
        })
    }

    func test_manyNormalWakes_shareOnePendingSlotOneFollowUpAndOneTerminal() async {
        let firstGate = AsyncGate()
        let followUpGate = AsyncGate()
        let activities = ScriptedAutoActivities([
            .init(.noAction, gate: firstGate),
            .init(.noAction, gate: followUpGate),
        ])
        let journal = RecordingEvaluationJournal()
        let backgroundGuard = ConcurrencyBackgroundTaskGuard()
        let orchestrator = makeCandidateOrchestrator(
            preferences: activePreferences(),
            activities: activities,
            journal: journal,
            backgroundGuard: backgroundGuard,
            backgroundExecutionLeasing: backgroundGuard
        )

        let running = await orchestrator.evaluationTicket(.geofence)
        await waitForCalls(1, activities: activities)

        let pending = await orchestrator.evaluationTicket(.geofence)
        let timer = await orchestrator.evaluationTicket(.timer)
        let significant = await orchestrator.evaluationTicket(.significantLocation)
        let secondGeofence = await orchestrator.evaluationTicket(.geofence)

        XCTAssertEqual(pending.admission, .deferred)
        for ticket in [timer, significant, secondGeofence] {
            XCTAssertEqual(ticket.admission, .coalesced)
            XCTAssertEqual(ticket.evaluationID, pending.evaluationID)
        }
        let hasSinglePendingSlot = await orchestrator.hasPendingNormalWakeForTest
        XCTAssertTrue(hasSinglePendingSlot)

        // Coalescência é durável antes do drain: uma morte do processo neste ponto ainda deixa os wakes
        // agregados no record órfão, sem coordenadas nem metadados de região.
        let beforeDrainJournal = await journal.snapshot()
        assertCoalescence(
            .timer,
            count: 1,
            evaluationID: pending.evaluationID,
            in: beforeDrainJournal
        )
        assertCoalescence(
            .significantLocation,
            count: 1,
            evaluationID: pending.evaluationID,
            in: beforeDrainJournal
        )
        assertCoalescence(
            .geofence,
            count: 1,
            evaluationID: pending.evaluationID,
            in: beforeDrainJournal
        )
        XCTAssertFalse(beforeDrainJournal.progresses.contains {
            $0.evaluationID == pending.evaluationID && $0.stage == .drained
        })

        await firstGate.release()
        let runningCompletion = await running.completion()
        XCTAssertEqual(runningCompletion.outcome, .noAction)
        await waitForCalls(2, activities: activities)

        let beforeFollowUpRelease = await activities.snapshot()
        XCTAssertEqual(beforeFollowUpRelease.callCount, 2)
        XCTAssertEqual(beforeFollowUpRelease.maximumActiveCount, 1)
        await followUpGate.release()

        let pendingCompletion = await pending.completion()
        let timerCompletion = await timer.completion()
        let significantCompletion = await significant.completion()
        let secondGeofenceCompletion = await secondGeofence.completion()
        for completion in [
            timerCompletion,
            significantCompletion,
            secondGeofenceCompletion,
        ] {
            XCTAssertEqual(completion, pendingCompletion)
            XCTAssertEqual(completion.evaluationID, pending.evaluationID)
            XCTAssertEqual(completion.outcome, .noAction)
        }

        let finalActivitySnapshot = await activities.snapshot()
        XCTAssertEqual(finalActivitySnapshot.callCount, 2)
        XCTAssertEqual(finalActivitySnapshot.maximumActiveCount, 1)
        XCTAssertEqual(finalActivitySnapshot.activeCount, 0)

        let guardSnapshot = backgroundGuard.snapshot()
        XCTAssertEqual(guardSnapshot.beginCount, 2)
        XCTAssertEqual(guardSnapshot.endCount, 2)
        XCTAssertEqual(guardSnapshot.maximumActiveCount, 1)
        XCTAssertEqual(guardSnapshot.activeCount, 0)

        let journalSnapshot = await journal.snapshot()
        XCTAssertEqual(Set(journalSnapshot.finishes.map(\.id)), Set([
            running.evaluationID,
            pending.evaluationID,
        ]))
        XCTAssertEqual(
            journalSnapshot.finishes.filter { $0.id == pending.evaluationID }.count,
            1
        )
        XCTAssertTrue(
            journalSnapshot.begins.contains {
                $0.id == pending.evaluationID && $0.stage == .admitted
            }
        )
        XCTAssertTrue(
            journalSnapshot.progresses.contains {
                $0.evaluationID == pending.evaluationID && $0.stage == .drained
            }
        )
        assertCoalescence(
            .timer,
            count: 1,
            evaluationID: pending.evaluationID,
            in: journalSnapshot
        )
        assertCoalescence(
            .significantLocation,
            count: 1,
            evaluationID: pending.evaluationID,
            in: journalSnapshot
        )
        assertCoalescence(
            .geofence,
            count: 1,
            evaluationID: pending.evaluationID,
            in: journalSnapshot
        )
    }

    func test_failedFirstEvaluation_doesNotPreventPendingEvaluationFromRunning() async {
        let firstGate = AsyncGate()
        let activities = ScriptedAutoActivities([
            .init(.locationTimeout, gate: firstGate),
            .init(.noAction),
        ])
        let journal = RecordingEvaluationJournal()
        let orchestrator = makeCandidateOrchestrator(
            preferences: activePreferences(),
            activities: activities,
            journal: journal
        )

        let first = await orchestrator.evaluationTicket(.geofence)
        await waitForCalls(1, activities: activities)
        let pending = await orchestrator.evaluationTicket(.geofence)
        XCTAssertEqual(pending.admission, .deferred)

        await firstGate.release()
        let firstCompletion = await first.completion()
        XCTAssertEqual(firstCompletion.outcome, .locationTimeout)

        let pendingCompletion = await pending.completion()
        XCTAssertEqual(pendingCompletion.outcome, .noAction)
        XCTAssertEqual(pendingCompletion.evaluationID, pending.evaluationID)

        let activitySnapshot = await activities.snapshot()
        XCTAssertEqual(activitySnapshot.callCount, 2)
        XCTAssertEqual(activitySnapshot.maximumActiveCount, 1)
        let journalSnapshot = await journal.snapshot()
        XCTAssertEqual(journalSnapshot.finishes.map(\.id), [
            first.evaluationID,
            pending.evaluationID,
        ])
    }

    func test_pendingTicketCompletesOnlyAfterFollowUpReachesItsTerminal() async {
        let firstGate = AsyncGate()
        let followUpGate = AsyncGate()
        let activities = ScriptedAutoActivities([
            .init(.noAction, gate: firstGate),
            .init(.noAction, gate: followUpGate),
        ])
        let orchestrator = makeCandidateOrchestrator(
            preferences: activePreferences(),
            activities: activities
        )

        let first = await orchestrator.evaluationTicket(.geofence)
        await waitForCalls(1, activities: activities)
        let pending = await orchestrator.evaluationTicket(.geofence)
        let probe = CompletionProbe()
        let waiter = Task {
            let completion = await pending.completion()
            await probe.record(completion)
            return completion
        }

        await firstGate.release()
        _ = await first.completion()
        await waitForCalls(2, activities: activities)

        let prematureCompletion = await probe.snapshot()
        XCTAssertNil(
            prematureCompletion,
            "Preencher o slot pending não pode ser confundido com alcançar o terminal."
        )

        await followUpGate.release()
        let completion = await waiter.value
        XCTAssertEqual(completion.evaluationID, pending.evaluationID)
        XCTAssertEqual(completion.outcome, .noAction)
        let recordedCompletion = await probe.snapshot()
        XCTAssertEqual(recordedCompletion, completion)
    }

    func test_pendingExpirationBeforeDrain_finishesExpiredWithoutDrainedOrActivity() async {
        let preferences = FirstTimerKeyPreferences(settingsJSON: activeSettingsJSON())
        let activities = ScriptedAutoActivities([])
        let journal = PendingExpirationJournal()
        let orchestrator = makeCandidateOrchestrator(
            preferences: preferences,
            activities: activities,
            journal: journal
        )

        let running = await orchestrator.evaluationTicket(.timer)
        await preferences.waitUntilFirstKeyRead()

        let registration = BackgroundWorkOwnerRegistration(kind: .bgAppRefresh)
        let pending = await orchestrator.evaluationTicket(
            .geofence,
            ownerRegistration: registration
        )
        XCTAssertEqual(pending.admission, .deferred)
        XCTAssertEqual(
            registration.expire(reason: .bgTaskExpired),
            .applied(.workCancelled)
        )

        await preferences.releaseFirstKeyRead()
        let runningCompletion = await running.completion()
        XCTAssertEqual(runningCompletion.outcome, .noKey)

        let pendingCompletion = await pending.completion()
        XCTAssertEqual(pendingCompletion.evaluationID, pending.evaluationID)
        XCTAssertEqual(pendingCompletion.outcome, .expired)
        XCTAssertFalse(pendingCompletion.completedBeforeExpiration)

        let activitySnapshot = await activities.snapshot()
        XCTAssertEqual(activitySnapshot.callCount, 0)

        let journalSnapshot = await journal.snapshot()
        XCTAssertFalse(journalSnapshot.progresses.contains {
            $0.evaluationID == pending.evaluationID && $0.stage == .drained
        })
        XCTAssertEqual(
            journalSnapshot.finishes.filter {
                $0.evaluationID == pending.evaluationID
            },
            [.init(
                evaluationID: pending.evaluationID,
                outcome: .expired,
                stage: .admitted
            )]
        )
        XCTAssertEqual(
            journalSnapshot.ownerExpirations.filter {
                $0.evaluationID == pending.evaluationID
            },
            [.init(
                evaluationID: pending.evaluationID,
                owner: .bgAppRefresh,
                cancelledCanonicalWork: true
            )]
        )
    }

    func test_pendingExpirationWinsWhenContextTransitionFinishesDeferredWork() async {
        let preferences = FirstTimerKeyPreferences(settingsJSON: activeSettingsJSON())
        let activities = ScriptedAutoActivities([])
        let journal = PendingExpirationJournal()
        let orchestrator = makeCandidateOrchestrator(
            preferences: preferences,
            activities: activities,
            journal: journal
        )

        let running = await orchestrator.evaluationTicket(.timer)
        await preferences.waitUntilFirstKeyRead()

        let registration = BackgroundWorkOwnerRegistration(kind: .bgAppRefresh)
        let pending = await orchestrator.evaluationTicket(
            .geofence,
            ownerRegistration: registration
        )
        XCTAssertEqual(pending.admission, .deferred)

        // A expiração já venceu quando a transição remove o slot pending. `contextInvalidated` não pode
        // reescrever esse terminal nem apagar a evidência do owner que cancelou o trabalho canônico.
        XCTAssertEqual(
            registration.expire(reason: .bgTaskExpired),
            .applied(.workCancelled)
        )
        let transition = await orchestrator.beginAutomationContextTransition()

        let pendingCompletion = await pending.completion()
        XCTAssertEqual(pendingCompletion.evaluationID, pending.evaluationID)
        XCTAssertEqual(pendingCompletion.outcome, .expired)
        XCTAssertFalse(pendingCompletion.completedBeforeExpiration)

        let snapshot = await journal.snapshot()
        XCTAssertEqual(
            snapshot.finishes.filter { $0.evaluationID == pending.evaluationID },
            [.init(
                evaluationID: pending.evaluationID,
                outcome: .expired,
                stage: .admitted
            )]
        )
        XCTAssertEqual(
            snapshot.ownerExpirations.filter {
                $0.evaluationID == pending.evaluationID
            },
            [.init(
                evaluationID: pending.evaluationID,
                owner: .bgAppRefresh,
                cancelledCanonicalWork: true
            )]
        )

        await preferences.releaseFirstKeyRead()
        let runningCompletion = await running.completion()
        XCTAssertEqual(runningCompletion.outcome, .staleContext)
        await orchestrator.awaitAutomationQuiescence(transition)
        await orchestrator.endAutomationContextTransition(transition)

        let activitySnapshot = await activities.snapshot()
        XCTAssertEqual(activitySnapshot.callCount, 0)
    }

    func test_cancellingOnePendingWaiter_doesNotCancelCanonicalWorkOrOtherWaiters() async {
        let firstGate = AsyncGate()
        let followUpGate = AsyncGate()
        let activities = ScriptedAutoActivities([
            .init(.noAction, gate: firstGate),
            .init(.noAction, gate: followUpGate),
        ])
        let journal = RecordingEvaluationJournal()
        let orchestrator = makeCandidateOrchestrator(
            preferences: activePreferences(),
            activities: activities,
            journal: journal
        )

        let first = await orchestrator.evaluationTicket(.geofence)
        await waitForCalls(1, activities: activities)
        let pending = await orchestrator.evaluationTicket(.geofence)
        let coalesced = await orchestrator.evaluationTicket(.timer)
        XCTAssertEqual(coalesced.admission, .coalesced)
        XCTAssertEqual(coalesced.evaluationID, pending.evaluationID)

        let cancelledWaiter = Task { await pending.completion() }
        let survivingWaiter = Task { await coalesced.completion() }
        cancelledWaiter.cancel()

        await firstGate.release()
        _ = await first.completion()
        await waitForCalls(2, activities: activities)
        await followUpGate.release()

        let survivingCompletion = await survivingWaiter.value
        let cancelledCallerCompletion = await cancelledWaiter.value
        XCTAssertEqual(survivingCompletion, cancelledCallerCompletion)
        XCTAssertEqual(survivingCompletion.evaluationID, pending.evaluationID)
        XCTAssertEqual(survivingCompletion.outcome, .noAction)

        let activitySnapshot = await activities.snapshot()
        XCTAssertEqual(activitySnapshot.callCount, 2)
        XCTAssertEqual(activitySnapshot.maximumActiveCount, 1)
        let journalSnapshot = await journal.snapshot()
        XCTAssertEqual(
            journalSnapshot.finishes.filter { $0.id == pending.evaluationID }.count,
            1
        )
    }

    func test_drainOrder_keepsPendingNormalWakeBeforeAccuracyRetry() async {
        let firstGate = AsyncGate()
        let normalGate = AsyncGate()
        let activities = ScriptedAutoActivities([
            .init(.noAction, gate: firstGate),
            .init(.noAction, gate: normalGate),
        ])
        let journal = RecordingEvaluationJournal()
        let orchestrator = makeCandidateOrchestrator(
            preferences: activePreferences(),
            activities: activities,
            journal: journal
        )

        let first = await orchestrator.evaluationTicket(.geofence)
        await waitForCalls(1, activities: activities)
        let normal = await orchestrator.evaluationTicket(.geofence)
        let retry = await orchestrator.evaluationTicket(.accuracyRetry)
        XCTAssertEqual(normal.admission, .deferred)
        XCTAssertEqual(retry.admission, .deferred)

        await firstGate.release()
        _ = await first.completion()
        await waitForCalls(2, activities: activities)

        // A segunda chamada do motor é o normal já iniciado e bloqueado; o retry só pode alcançar seu
        // terminal depois que esse follow-up canônico concluir.
        let whileNormalIsBlocked = await journal.snapshot()
        XCTAssertEqual(whileNormalIsBlocked.finishes.map(\.id), [
            first.evaluationID,
        ])

        await normalGate.release()
        let normalCompletion = await normal.completion()
        XCTAssertEqual(normalCompletion.outcome, .noAction)
        let retryCompletion = await retry.completion()
        XCTAssertEqual(retryCompletion.outcome, .staleContext)

        let finalJournalSnapshot = await journal.snapshot()
        XCTAssertEqual(finalJournalSnapshot.finishes.map(\.id), [
            first.evaluationID,
            normal.evaluationID,
            retry.evaluationID,
        ])
        let activitySnapshot = await activities.snapshot()
        XCTAssertEqual(activitySnapshot.maximumActiveCount, 1)
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
            notifyActivities: false,
            notifyScheduledPause: false,
            notifyAccident: false
        )
        let data = try! JSONCoding.encoder.encode(["HR70": settings])
        return String(decoding: data, as: UTF8.self)
    }

    private func activePreferences() -> FakeAppPreferences {
        let preferences = FakeAppPreferences()
        preferences.chaveValue = "HR70"
        preferences.languageValue = "pt"
        preferences.userSettingsJsonValue = activeSettingsJSON()
        return preferences
    }

    private func makeCandidateOrchestrator(
        preferences: any AppPreferencesReading,
        activities: any RunningAutomaticActivities,
        journal: any EvaluationJournaling = NoopEvaluationJournal(),
        backgroundGuard: any BackgroundTaskGuard = NoopBackgroundTaskGuard(),
        backgroundExecutionLeasing: any BackgroundExecutionLeasing = NoopBackgroundExecutionLeasing()
    ) -> BackgroundCheckOrchestrator {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(
            LocationOptions(
                items: ["configured-location"],
                accuracyThresholdMeters: 50,
                mixedZoneIntervalMinutes: 15
            )
        )
        repository.getStateResult = .success(ucHistory(.checkOut))
        return BackgroundCheckOrchestrator(
            appPrefs: preferences,
            checkRepository: repository,
            runAutomaticActivities: activities,
            locationProvider: FakeLocationProvider(.unavailable),
            clock: FixedClock(now),
            authSessionCoordinator: OrchestratorAuthSessionCoordinator(
                authRepository: NoopAuthRepository(),
                securePasswordStore: NoopSecurePasswordStore()
            ),
            accidentRepository: FakeAccidentStateRepository(),
            activityLogger: NoopActivityLogger(),
            notifications: SpyNotifications(),
            automaticEvaluationPipeline: .candidate,
            evaluationJournal: journal,
            backgroundTaskGuard: backgroundGuard,
            backgroundExecutionLeasing: backgroundExecutionLeasing,
            pauseAlarms: NoopPauseAlarmScheduling(),
            accuracyRetrySleeper: TaskSleeper(),
            pauseActivationSleeper: TaskSleeper(),
            pauseTransitionSleeper: TaskSleeper(),
            appRefreshScheduler: NoopAppRefreshScheduler()
        )
    }

    private func waitForCalls(
        _ expected: Int,
        activities: ScriptedAutoActivities
    ) async {
        await waitUntil {
            await activities.snapshot().callCount == expected
        }
        let snapshot = await activities.snapshot()
        XCTAssertEqual(snapshot.callCount, expected)
    }

    private func assertCoalescence(
        _ wake: EvaluationWakeKind,
        count: Int,
        evaluationID: EvaluationID,
        in snapshot: RecordingEvaluationJournal.Snapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matches = snapshot.coalescences.filter {
            $0.evaluationID == evaluationID && $0.wake == wake
        }
        XCTAssertEqual(matches.count, 1, file: file, line: line)
        XCTAssertEqual(matches.first?.count, count, file: file, line: line)
        XCTAssertEqual(matches.first?.stage, .admitted, file: file, line: line)
        XCTAssertEqual(
            matches.first?.targetCount,
            wake == .geofence ? 2 : 1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            matches.first?.effectiveTrigger,
            .significantLocation,
            file: file,
            line: line
        )
    }
}
