import Foundation
import XCTest
@testable import Checking

/// Provas de exactly-once da fila offline quando muitos callers compartilham o único pending normal.
///
/// A primeira avaliação fica suspensa em um seam controlado. Enquanto ela está running, doze wakes
/// equivalentes são admitidos no mesmo slot pending. Depois do release, somente a avaliação canônica
/// drenada atravessa os casos de uso reais de captura, match, decisão, submit e enqueue.
final class PendingOfflineQueueTests: XCTestCase {
    private actor FirstCallGatedActivities: RunningAutomaticActivities {
        struct Snapshot: Sendable, Equatable {
            let callCount: Int
            let delegatedCallCount: Int
        }

        private let downstream: any RunningAutomaticActivities
        private let firstCallStarted = AsyncGate()
        private let firstCallRelease = AsyncGate()
        private var callCount = 0
        private var delegatedCallCount = 0

        init(downstream: any RunningAutomaticActivities) {
            self.downstream = downstream
        }

        func execute(
            chave: String,
            userProjects: UserProjects?,
            currentState: HistoryState?,
            mixedZoneIntervalMinutes: Int,
            accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> AutomaticActivitiesExecution {
            let isFirstCall = callCount == 0
            callCount += 1

            if isFirstCall {
                await firstCallStarted.release()
                await firstCallRelease.wait()
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

            delegatedCallCount += 1
            return await downstream.execute(
                chave: chave,
                userProjects: userProjects,
                currentState: currentState,
                mixedZoneIntervalMinutes: mixedZoneIntervalMinutes,
                accuracyThresholdMeters: accuracyThresholdMeters,
                locationAttempt: locationAttempt
            )
        }

        func waitUntilFirstCallStarts() async {
            await firstCallStarted.wait()
        }

        func releaseFirstCall() async {
            await firstCallRelease.release()
        }

        func snapshot() -> Snapshot {
            Snapshot(
                callCount: callCount,
                delegatedCallCount: delegatedCallCount
            )
        }
    }

    private final class ClientEventIDSequence: @unchecked Sendable {
        private let lock = NSLock()
        private let prefix: String
        private var generated: [String] = []

        init(prefix: String) {
            self.prefix = prefix
        }

        var values: [String] {
            lock.withLock { generated }
        }

        func next() -> String {
            lock.withLock {
                let value = "\(prefix)-\(generated.count + 1)"
                generated.append(value)
                return value
            }
        }
    }

    private struct Harness {
        let sut: BackgroundCheckOrchestrator
        let activities: FirstCallGatedActivities
        let repository: FakeCheckRepository
        let provider: FakeLocationProvider
        let queue: FakeOfflineQueue
        let notifications: SpyNotifications
        let journal: RecordingEvaluationJournal
        let eventIDs: ClientEventIDSequence
    }

    private let now = iso("2026-07-31T08:00:00Z")
    private let pendingCallerCount = 12

    override func setUp() {
        super.setUp()
        EvaluationLog.shared.reset()
    }

    func test_manyCoalescedCallers_matchNetworkQueuesOneCanonicalRawWithExactPayload() async throws {
        let harness = makeHarness(
            matchResult: .failure(.network),
            submitResult: .success(history(.checkIn, local: "Unidade P80")),
            eventIDPrefix: "pending-raw"
        )

        let first = await harness.sut.evaluationTicket(.geofence)
        XCTAssertEqual(first.admission, .admitted)
        await harness.activities.waitUntilFirstCallStarts()

        let pendingTickets = await admitPendingCallers(on: harness.sut)
        assertOneCanonicalPending(pendingTickets)
        XCTAssertEqual(harness.queue.enqueued.count, 0)
        XCTAssertEqual(harness.repository.submitCount, 0)
        XCTAssertEqual(harness.notifications.activityPosts.count, 0)

        await harness.activities.releaseFirstCall()

        let firstCompletion = await first.completion()
        let pendingCompletions = await completions(of: pendingTickets)

        XCTAssertEqual(firstCompletion.outcome, .noAction)
        assertCanonicalCompletions(
            pendingCompletions,
            evaluationID: try XCTUnwrap(pendingTickets.first?.evaluationID),
            outcome: .queuedOfflineRaw
        )

        XCTAssertEqual(harness.provider.callCount, 1)
        XCTAssertEqual(harness.repository.matchLocationCallCount, 1)
        XCTAssertEqual(harness.repository.getStateCallCount, 2)
        XCTAssertEqual(harness.repository.submitCount, 0)
        XCTAssertTrue(harness.repository.submitCalls.isEmpty)
        XCTAssertEqual(harness.queue.enqueued.count, 1)
        XCTAssertEqual(harness.eventIDs.values, ["pending-raw-1"])
        XCTAssertTrue(harness.notifications.activityPosts.isEmpty)

        guard case .raw(let raw) = try XCTUnwrap(harness.queue.enqueued.first) else {
            return XCTFail("expected exactly one Raw event from the canonical pending evaluation")
        }
        XCTAssertEqual(raw.chave, "HR70")
        XCTAssertEqual(raw.projeto, "P80")
        XCTAssertEqual(raw.capturedAtEpochMs, epochMs(now))
        XCTAssertEqual(raw.clientEventId, "pending-raw-1")
        XCTAssertEqual(raw.latitude, 1.3)
        XCTAssertEqual(raw.longitude, 103.8)
        XCTAssertEqual(raw.accuracyMeters, 12)

        let matchCall = try XCTUnwrap(harness.repository.lastMatchLocationCall)
        XCTAssertEqual(matchCall.latitude, raw.latitude)
        XCTAssertEqual(matchCall.longitude, raw.longitude)
        XCTAssertEqual(matchCall.accuracyMeters, raw.accuracyMeters)

        let activitySnapshot = await harness.activities.snapshot()
        XCTAssertEqual(activitySnapshot.callCount, 2)
        XCTAssertEqual(activitySnapshot.delegatedCallCount, 1)
        await assertJournalExactlyOnce(
            harness.journal,
            firstID: first.evaluationID,
            pendingID: try XCTUnwrap(pendingTickets.first?.evaluationID),
            pendingOutcome: .queuedOfflineRaw
        )
    }

    func test_manyCoalescedCallers_submitNetworkQueuesOneCanonicalDecidedWithSameIDAndTime() async throws {
        let harness = makeHarness(
            matchResult: .success(ucMatch(.matched, "Unidade P80")),
            submitResult: .failure(.network),
            eventIDPrefix: "pending-decided"
        )

        let first = await harness.sut.evaluationTicket(.geofence)
        XCTAssertEqual(first.admission, .admitted)
        await harness.activities.waitUntilFirstCallStarts()

        let pendingTickets = await admitPendingCallers(on: harness.sut)
        assertOneCanonicalPending(pendingTickets)
        XCTAssertEqual(harness.queue.enqueued.count, 0)
        XCTAssertEqual(harness.repository.submitCount, 0)
        XCTAssertEqual(harness.notifications.activityPosts.count, 0)

        await harness.activities.releaseFirstCall()

        let firstCompletion = await first.completion()
        let pendingCompletions = await completions(of: pendingTickets)

        XCTAssertEqual(firstCompletion.outcome, .noAction)
        assertCanonicalCompletions(
            pendingCompletions,
            evaluationID: try XCTUnwrap(pendingTickets.first?.evaluationID),
            outcome: .queuedOfflineDecided
        )

        XCTAssertEqual(harness.provider.callCount, 1)
        XCTAssertEqual(harness.repository.matchLocationCallCount, 1)
        XCTAssertEqual(harness.repository.getStateCallCount, 2)
        XCTAssertEqual(harness.repository.submitCount, 1)
        XCTAssertEqual(harness.repository.submitCalls.count, 1)
        XCTAssertEqual(harness.queue.enqueued.count, 1)
        XCTAssertEqual(harness.eventIDs.values, ["pending-decided-1"])
        XCTAssertTrue(
            harness.notifications.activityPosts.isEmpty,
            "uma tentativa enfileirada não pode produzir nem duplicar notificação de atividade"
        )

        let submit = try XCTUnwrap(harness.repository.submitCalls.first)
        XCTAssertEqual(submit.chave, "HR70")
        XCTAssertEqual(submit.projeto, "P80")
        XCTAssertEqual(submit.action, .checkIn)
        XCTAssertEqual(submit.local, "Unidade P80")
        XCTAssertEqual(submit.informe, .normal)
        XCTAssertEqual(submit.eventTime, now)
        XCTAssertEqual(submit.clientEventId, "pending-decided-1")
        XCTAssertTrue(submit.fillForms)

        guard case .decided(let decided) = try XCTUnwrap(harness.queue.enqueued.first) else {
            return XCTFail("expected exactly one Decided event from the canonical pending evaluation")
        }
        XCTAssertEqual(decided.chave, submit.chave)
        XCTAssertEqual(decided.projeto, submit.projeto)
        XCTAssertEqual(decided.capturedAtEpochMs, epochMs(submit.eventTime))
        XCTAssertEqual(decided.clientEventId, submit.clientEventId)
        XCTAssertEqual(decided.action, "checkin")
        XCTAssertEqual(decided.local, submit.local)
        XCTAssertEqual(decided.informe, "normal")

        let activitySnapshot = await harness.activities.snapshot()
        XCTAssertEqual(activitySnapshot.callCount, 2)
        XCTAssertEqual(activitySnapshot.delegatedCallCount, 1)
        await assertJournalExactlyOnce(
            harness.journal,
            firstID: first.evaluationID,
            pendingID: try XCTUnwrap(pendingTickets.first?.evaluationID),
            pendingOutcome: .queuedOfflineDecided
        )
    }

    private func makeHarness(
        matchResult: AppResult<LocationMatch>,
        submitResult: AppResult<HistoryState>,
        eventIDPrefix: String
    ) -> Harness {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(
            LocationOptions(
                items: ["Unidade P80"],
                accuracyThresholdMeters: 50,
                mixedZoneIntervalMinutes: 15
            )
        )
        repository.matchLocationResult = matchResult
        repository.getStateResult = .success(history(.checkOut))
        repository.submitResult = submitResult

        let provider = FakeLocationProvider(.success(sample()))
        let queue = FakeOfflineQueue()
        let notifications = SpyNotifications()
        let journal = RecordingEvaluationJournal()
        let eventIDs = ClientEventIDSequence(prefix: eventIDPrefix)
        let clock = FixedClock(now)
        let capture = CaptureLocationUseCase(
            locationProvider: provider,
            checkRepository: repository,
            activityLogger: NoopActivityLogger(),
            clock: clock,
            samplePolicy: .candidateTrial,
            captureBehavior: .freshnessValidated
        )
        let automatic = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: clock,
            activityLogger: NoopActivityLogger(),
            makeClientEventID: eventIDs.next
        )
        let activities = FirstCallGatedActivities(downstream: automatic)
        let sut = makeOrchestrator(
            prefs: preferences(),
            checkRepository: repository,
            autoActivities: activities,
            notifications: notifications,
            locationProvider: provider,
            automaticEvaluationPipeline: .candidate,
            clock: clock,
            evaluationJournal: journal
        )
        return Harness(
            sut: sut,
            activities: activities,
            repository: repository,
            provider: provider,
            queue: queue,
            notifications: notifications,
            journal: journal,
            eventIDs: eventIDs
        )
    }

    private func admitPendingCallers(
        on orchestrator: BackgroundCheckOrchestrator
    ) async -> [EvaluationTicket] {
        var tickets: [EvaluationTicket] = []
        tickets.reserveCapacity(pendingCallerCount)
        for _ in 0..<pendingCallerCount {
            tickets.append(await orchestrator.evaluationTicket(.geofence))
        }
        return tickets
    }

    private func completions(
        of tickets: [EvaluationTicket]
    ) async -> [EvaluationCompletion] {
        var values: [EvaluationCompletion] = []
        values.reserveCapacity(tickets.count)
        for ticket in tickets {
            values.append(await ticket.completion())
        }
        return values
    }

    private func assertOneCanonicalPending(
        _ tickets: [EvaluationTicket],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(tickets.count, pendingCallerCount, file: file, line: line)
        guard let canonicalID = tickets.first?.evaluationID else {
            return XCTFail("missing canonical pending ticket", file: file, line: line)
        }
        XCTAssertEqual(tickets.first?.admission, .deferred, file: file, line: line)
        XCTAssertTrue(
            tickets.dropFirst().allSatisfy { $0.admission == .coalesced },
            file: file,
            line: line
        )
        XCTAssertTrue(
            tickets.allSatisfy { $0.evaluationID == canonicalID },
            "todos os callers devem aguardar a mesma avaliação canônica",
            file: file,
            line: line
        )
    }

    private func assertCanonicalCompletions(
        _ completions: [EvaluationCompletion],
        evaluationID: EvaluationID,
        outcome: EvaluationTerminalOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(completions.count, pendingCallerCount, file: file, line: line)
        XCTAssertTrue(
            completions.allSatisfy {
                $0.evaluationID == evaluationID && $0.outcome == outcome
            },
            "todos os callers devem observar o mesmo terminal da avaliação canônica",
            file: file,
            line: line
        )
    }

    private func assertJournalExactlyOnce(
        _ journal: RecordingEvaluationJournal,
        firstID: EvaluationID,
        pendingID: EvaluationID,
        pendingOutcome: EvaluationTerminalOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.begins.map(\.id), [firstID, pendingID], file: file, line: line)
        XCTAssertEqual(
            snapshot.finishes.filter { $0.id == firstID }.count,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            snapshot.finishes.filter { $0.id == pendingID }.count,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            snapshot.finishes.first { $0.id == pendingID }?.terminal.outcome,
            pendingOutcome,
            file: file,
            line: line
        )
        XCTAssertEqual(
            snapshot.coalescences.last { $0.evaluationID == pendingID }?.targetCount,
            pendingCallerCount,
            file: file,
            line: line
        )
        XCTAssertTrue(
            snapshot.progresses.contains {
                $0.evaluationID == pendingID && $0.stage == .drained
            },
            file: file,
            line: line
        )
    }

    private func preferences() -> FakeAppPreferences {
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
        preferences.userSettingsJsonValue = String(decoding: data, as: UTF8.self)
        return preferences
    }

    private func sample() -> LocationSample {
        LocationSample(
            latitude: 1.3,
            longitude: 103.8,
            horizontalAccuracyMeters: 12,
            capturedAt: now,
            source: .standardCapture
        )
    }

    private func history(
        _ action: CheckAction?,
        local: String? = nil
    ) -> HistoryState {
        HistoryState(
            found: action != nil,
            chave: "HR70",
            projeto: "P80",
            currentAction: action,
            currentLocal: local,
            hasCurrentDayCheckin: action == .checkIn,
            lastCheckinAt: action == .checkIn
                ? now.addingTimeInterval(-600)
                : nil,
            lastCheckoutAt: action == .checkOut
                ? now.addingTimeInterval(-600)
                : nil,
            transportEnabled: false
        )
    }

    private func epochMs(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
