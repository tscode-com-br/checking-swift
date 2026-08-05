import Foundation
import XCTest
@testable import Checking

final class BGAppRefreshExecutionControllerTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var triggers: [OrchestratorTrigger] = []
        private var attachmentResults: [BackgroundWorkOwnerAttachmentResult] = []
        private var schedules = 0
        private var completions: [Bool] = []

        func record(trigger: OrchestratorTrigger) {
            lock.withLock { triggers.append(trigger) }
        }

        func record(attachment: BackgroundWorkOwnerAttachmentResult) {
            lock.withLock { attachmentResults.append(attachment) }
        }

        func schedule() {
            lock.withLock { schedules += 1 }
        }

        func complete(_ success: Bool) {
            lock.withLock { completions.append(success) }
        }

        var triggerSnapshot: [OrchestratorTrigger] {
            lock.withLock { triggers }
        }

        var attachmentSnapshot: [BackgroundWorkOwnerAttachmentResult] {
            lock.withLock { attachmentResults }
        }

        var scheduleCount: Int {
            lock.withLock { schedules }
        }

        var completionSnapshot: [Bool] {
            lock.withLock { completions }
        }
    }

    func test_controlledTerminalCompletesTrueAndSchedulesExactlyOnce() async {
        let ownership = BackgroundWorkOwnership()
        let recorder = Recorder()
        let ticket = immediateTicket(outcome: .noAction)
        let sut = makeController(recorder: recorder) { trigger, registration in
            recorder.record(trigger: trigger)
            recorder.record(attachment: registration.attach(to: ownership))
            return ticket
        }

        let handle = sut.start(trigger: .accuracyRetry) { recorder.complete($0) }
        await handle.completion()

        XCTAssertEqual(recorder.triggerSnapshot, [.accuracyRetry])
        XCTAssertEqual(recorder.attachmentSnapshot, [.attached])
        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [true])
        XCTAssertEqual(ownership.activeOwnerCount, 0)
        XCTAssertFalse(ownership.cancellationContext.isCancelled)
        XCTAssertEqual(handle.expire(), .ignored)
        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [true])
    }

    func test_submissionOutcomeUnknownCompletesFalseWithoutInventingHandoff() async {
        let ownership = BackgroundWorkOwnership()
        let recorder = Recorder()
        let ticket = immediateTicket(
            outcome: .submissionOutcomeUnknown,
            completedBeforeExpiration: false
        )
        let sut = makeController(recorder: recorder) { _, registration in
            recorder.record(attachment: registration.attach(to: ownership))
            return ticket
        }

        let handle = sut.start(trigger: .timer) { recorder.complete($0) }
        await handle.completion()

        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertFalse(ownership.cancellationContext.isCancelled)
    }

    func test_deferredAdmissionDoesNotCompleteBeforeCanonicalTerminal() async {
        let ownership = BackgroundWorkOwnership()
        let recorder = Recorder()
        let terminalGate = AsyncGate()
        let ticket = gatedTicket(
            admission: .deferred,
            gate: terminalGate,
            outcome: .noAction
        )
        let sut = makeController(recorder: recorder) { _, registration in
            recorder.record(attachment: registration.attach(to: ownership))
            return ticket
        }

        let handle = sut.start(trigger: .geofence) { recorder.complete($0) }
        await waitUntil { recorder.attachmentSnapshot == [.attached] }

        XCTAssertEqual(recorder.scheduleCount, 0)
        XCTAssertTrue(recorder.completionSnapshot.isEmpty)
        XCTAssertEqual(ownership.activeOwnerCount, 1)

        await terminalGate.release()
        await handle.completion()

        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [true])
        XCTAssertEqual(ownership.activeOwnerCount, 0)
    }

    func test_coalescedAdmissionAlsoWaitsForTheSharedFollowUpTerminal() async {
        let ownership = BackgroundWorkOwnership()
        let recorder = Recorder()
        let terminalGate = AsyncGate()
        let ticket = gatedTicket(
            admission: .coalesced,
            gate: terminalGate,
            outcome: .queuedOfflineRaw
        )
        let sut = makeController(recorder: recorder) { _, registration in
            recorder.record(attachment: registration.attach(to: ownership))
            return ticket
        }

        let handle = sut.start(trigger: .significantLocation) { recorder.complete($0) }
        await waitUntil { recorder.attachmentSnapshot == [.attached] }

        XCTAssertEqual(recorder.scheduleCount, 0)
        XCTAssertTrue(recorder.completionSnapshot.isEmpty)

        await terminalGate.release()
        await handle.completion()

        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [true])
        XCTAssertEqual(ownership.activeOwnerCount, 0)
    }

    func test_expirationOfLastOwnerWaitsForCanonicalTerminalAndJournalBoundary() async {
        let ownership = BackgroundWorkOwnership()
        let recorder = Recorder()
        let terminalGate = AsyncGate()
        let ticket = gatedTicket(
            gate: terminalGate,
            outcome: .expired,
            completedBeforeExpiration: false
        )
        let sut = makeController(recorder: recorder) { _, registration in
            recorder.record(attachment: registration.attach(to: ownership))
            return ticket
        }

        let handle = sut.start(trigger: .timer) { recorder.complete($0) }
        await waitUntil { recorder.attachmentSnapshot == [.attached] }

        XCTAssertEqual(handle.expire(), .applied(.workCancelled))
        XCTAssertEqual(ownership.cancellationContext.reason, .bgTaskExpired)
        XCTAssertEqual(recorder.scheduleCount, 0)
        XCTAssertTrue(recorder.completionSnapshot.isEmpty)

        // No app real, o gate representa o terminal do orquestrador depois de cleanup + journal.finish.
        await terminalGate.release()
        await handle.completion()

        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertEqual(ownership.activeOwnerCount, 0)
    }

    func test_expirationWithAnotherOwnerCompletesFalseWithoutCancellingCanonicalWork() async {
        let ownership = BackgroundWorkOwnership()
        let uiOwner = tryAcquire(.uiBackgroundTask, from: ownership)
        let recorder = Recorder()
        let terminalGate = AsyncGate()
        let ticket = gatedTicket(gate: terminalGate, outcome: .noAction)
        let sut = makeController(recorder: recorder) { _, registration in
            recorder.record(attachment: registration.attach(to: ownership))
            return ticket
        }

        let handle = sut.start(trigger: .timer) { recorder.complete($0) }
        await waitUntil { recorder.attachmentSnapshot == [.attached] }

        XCTAssertEqual(handle.expire(), .applied(.workContinues))
        await handle.completion()

        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertFalse(ownership.cancellationContext.isCancelled)
        XCTAssertEqual(ownership.activeOwnerCount, 1)

        // A lease UIKit ainda sustenta a avaliação; resolver o terminal depois não pode completar ou
        // reagendar este owner de BGTask novamente.
        await terminalGate.release()
        await Task.yield()
        XCTAssertTrue(ownership.release(uiOwner))
        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [false])
    }

    func test_expirationBeforeAttachIsAppliedAndWaitsWhenItCancelsLastOwner() async {
        let ownership = BackgroundWorkOwnership()
        let recorder = Recorder()
        let admissionGate = AsyncGate()
        let terminalGate = AsyncGate()
        let ticket = gatedTicket(
            gate: terminalGate,
            outcome: .expired,
            completedBeforeExpiration: false
        )
        let sut = makeController(recorder: recorder) { _, registration in
            recorder.record(trigger: .timer)
            await admissionGate.wait()
            recorder.record(attachment: registration.attach(to: ownership))
            return ticket
        }

        let handle = sut.start(trigger: .timer) { recorder.complete($0) }
        await waitUntil { recorder.triggerSnapshot == [.timer] }

        XCTAssertEqual(handle.expire(), .pendingAttachment)
        XCTAssertEqual(recorder.scheduleCount, 0)
        await admissionGate.release()
        await waitUntil {
            recorder.attachmentSnapshot == [.pendingExpirationApplied(.workCancelled)]
        }

        XCTAssertEqual(ownership.cancellationContext.reason, .bgTaskExpired)
        XCTAssertEqual(recorder.scheduleCount, 0)
        XCTAssertTrue(recorder.completionSnapshot.isEmpty)

        await terminalGate.release()
        await handle.completion()
        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [false])
    }

    func test_expirationBeforeAttachCompletesPromptlyWhenExistingOwnerKeepsWork() async {
        let ownership = BackgroundWorkOwnership()
        let uiOwner = tryAcquire(.uiBackgroundTask, from: ownership)
        let recorder = Recorder()
        let admissionGate = AsyncGate()
        let terminalGate = AsyncGate()
        let ticket = gatedTicket(gate: terminalGate, outcome: .noAction)
        let sut = makeController(recorder: recorder) { _, registration in
            recorder.record(trigger: .timer)
            await admissionGate.wait()
            recorder.record(attachment: registration.attach(to: ownership))
            return ticket
        }

        let handle = sut.start(trigger: .timer) { recorder.complete($0) }
        await waitUntil { recorder.triggerSnapshot == [.timer] }
        XCTAssertEqual(handle.expire(), .pendingAttachment)

        await admissionGate.release()
        await handle.completion()

        XCTAssertEqual(
            recorder.attachmentSnapshot,
            [.pendingExpirationApplied(.workContinues)]
        )
        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertFalse(ownership.cancellationContext.isCancelled)
        XCTAssertEqual(ownership.activeOwnerCount, 1)

        await terminalGate.release()
        XCTAssertTrue(ownership.release(uiOwner))
    }

    func test_repeatedExpirationAndTerminalRaceStillFinalizeExactlyOnce() async {
        let ownership = BackgroundWorkOwnership()
        let uiOwner = tryAcquire(.uiBackgroundTask, from: ownership)
        let recorder = Recorder()
        let terminalGate = AsyncGate()
        let ticket = gatedTicket(gate: terminalGate, outcome: .submittedCheckIn)
        let sut = makeController(recorder: recorder) { _, registration in
            recorder.record(attachment: registration.attach(to: ownership))
            return ticket
        }

        let handle = sut.start(trigger: .timer) { recorder.complete($0) }
        await waitUntil { recorder.attachmentSnapshot == [.attached] }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { _ = handle.expire() }
            }
            group.addTask { await terminalGate.release() }
        }
        await handle.completion()
        await Task.yield()

        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot.count, 1)
        XCTAssertFalse(ownership.cancellationContext.isCancelled)
        XCTAssertTrue(ownership.release(uiOwner))
    }

    func test_cancellingOneCompletionWaiterDoesNotCancelCanonicalWorkOrOtherWaiter() async {
        let ownership = BackgroundWorkOwnership()
        let recorder = Recorder()
        let terminalGate = AsyncGate()
        let ticket = gatedTicket(gate: terminalGate, outcome: .submittedCheckOut)
        let sut = makeController(recorder: recorder) { _, registration in
            recorder.record(attachment: registration.attach(to: ownership))
            return ticket
        }

        let handle = sut.start(trigger: .timer) { recorder.complete($0) }
        await waitUntil { recorder.attachmentSnapshot == [.attached] }
        let cancelledWaiter = Task { await handle.completion() }
        let survivingWaiter = Task { await handle.completion() }

        cancelledWaiter.cancel()
        await Task.yield()
        XCTAssertFalse(ownership.cancellationContext.isCancelled)
        XCTAssertTrue(recorder.completionSnapshot.isEmpty)

        await terminalGate.release()
        await cancelledWaiter.value
        await survivingWaiter.value

        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [true])
        XCTAssertFalse(ownership.cancellationContext.isCancelled)
    }

    private func makeController(
        recorder: Recorder,
        startEvaluation: @escaping BGAppRefreshExecutionController.EvaluationStarter
    ) -> BGAppRefreshExecutionController {
        BGAppRefreshExecutionController(
            startEvaluation: startEvaluation,
            scheduleRegularRefresh: { recorder.schedule() }
        )
    }

    private func immediateTicket(
        admission: EvaluationAdmission = .admitted,
        outcome: EvaluationTerminalOutcome,
        completedBeforeExpiration: Bool = true
    ) -> EvaluationTicket {
        let evaluationID = EvaluationID()
        let completion = EvaluationCompletion(
            evaluationID: evaluationID,
            outcome: outcome,
            completedBeforeExpiration: completedBeforeExpiration
        )
        return EvaluationTicket(
            evaluationID: evaluationID,
            admission: admission,
            completionTask: Task { completion }
        )
    }

    private func gatedTicket(
        admission: EvaluationAdmission = .admitted,
        gate: AsyncGate,
        outcome: EvaluationTerminalOutcome,
        completedBeforeExpiration: Bool = true
    ) -> EvaluationTicket {
        let evaluationID = EvaluationID()
        let completion = EvaluationCompletion(
            evaluationID: evaluationID,
            outcome: outcome,
            completedBeforeExpiration: completedBeforeExpiration
        )
        return EvaluationTicket(
            evaluationID: evaluationID,
            admission: admission,
            completionTask: Task {
                await gate.wait()
                return completion
            }
        )
    }

    private func tryAcquire(
        _ kind: BackgroundWorkOwnerKind,
        from ownership: BackgroundWorkOwnership,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> BackgroundWorkOwnerToken {
        guard let token = ownership.acquire(kind) else {
            XCTFail("Expected owner token for \(kind)", file: file, line: line)
            fatalError("Missing background owner")
        }
        return token
    }
}

/// Exercita a fronteira real controller → orquestrador candidato. Os testes acima isolam o controller;
/// estes preservam as corridas que só aparecem quando ownership, lease UIKit, journal e pipeline coexistem.
final class BGAppRefreshExecutionIntegrationTests: XCTestCase {
    private final class SystemRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var schedules = 0
        private var completions: [Bool] = []

        var scheduleCount: Int { lock.withLock { schedules } }
        var completionSnapshot: [Bool] { lock.withLock { completions } }

        func schedule() {
            lock.withLock { schedules += 1 }
        }

        func complete(_ success: Bool) {
            lock.withLock { completions.append(success) }
        }
    }

    /// Lease UIKit controlável: expirar chama o mesmo `BackgroundExecutionLease.expire()` usado pelo
    /// adapter de produção e o end handler permite provar que o recurso físico foi encerrado uma vez.
    private final class LeaseProbe: @unchecked Sendable, BackgroundExecutionLeasing {
        struct Snapshot: Equatable {
            let names: [String]
            let endCount: Int
            let expirationRequests: Int
        }

        private let lock = NSLock()
        private var leases: [BackgroundExecutionLease] = []
        private var names: [String] = []
        private var ends = 0
        private var expirationRequests = 0

        func begin(
            name: String,
            onExpiration: @escaping @Sendable () -> Void
        ) async -> BackgroundExecutionLease {
            let lease = BackgroundExecutionLease(onExpiration: onExpiration)
            lease.installEndHandler { [weak self] in
                self?.lock.withLock { self?.ends += 1 }
            }
            lock.withLock {
                names.append(name)
                leases.append(lease)
            }
            return lease
        }

        @discardableResult
        func expireLatestLease() -> Bool {
            let lease = lock.withLock { leases.last }
            guard let lease else { return false }
            lock.withLock { expirationRequests += 1 }
            lease.expire()
            return true
        }

        var snapshot: Snapshot {
            lock.withLock {
                Snapshot(
                    names: names,
                    endCount: ends,
                    expirationRequests: expirationRequests
                )
            }
        }
    }

    /// Exercita o adapter UIKit real sem chamar `UIApplication`: o teste controla o callback que a
    /// plataforma entregaria para `beginBackgroundTask(expirationHandler:)` e observa o mesmo token
    /// físico que precisa ser encerrado uma única vez.
    private final class UIKitTaskOperations: @unchecked Sendable {
        struct Snapshot: Equatable {
            let beginNames: [String]
            let endTokens: [Int]
            let expirationInstallations: Int
        }

        private let token: Int
        private let lock = NSLock()
        private var beginNames: [String] = []
        private var endTokens: [Int] = []
        private var expirationHandler: (@Sendable () -> Void)?
        private var expirationInstallations = 0

        init(token: Int) {
            self.token = token
        }

        func begin(
            name: String,
            expirationHandler: @escaping @Sendable () -> Void
        ) -> Int {
            lock.withLock {
                beginNames.append(name)
                self.expirationHandler = expirationHandler
                expirationInstallations += 1
            }
            return token
        }

        func end(_ token: Int) {
            lock.withLock { endTokens.append(token) }
        }

        @discardableResult
        func fireExpiration() -> Bool {
            let handler = lock.withLock { expirationHandler }
            guard let handler else { return false }
            handler()
            return true
        }

        var snapshot: Snapshot {
            lock.withLock {
                Snapshot(
                    beginNames: beginNames,
                    endTokens: endTokens,
                    expirationInstallations: expirationInstallations
                )
            }
        }

        func makeLeasing() -> UIKitBackgroundTaskGuard {
            UIKitBackgroundTaskGuard(
                invalidToken: -1,
                beginOperation: { [self] name, expirationHandler in
                    begin(name: name, expirationHandler: expirationHandler)
                },
                endOperation: { [self] token in
                    end(token)
                }
            )
        }
    }

    /// Provider bloqueável que não interpreta cancelamento como sucesso. O controller precisa cancelar
    /// o trabalho; o teste libera o callback pendente para provar que nenhum estágio posterior começa.
    private final class GatedLocationProvider: LocationProvider, @unchecked Sendable {
        private let gate = AsyncGate()
        private let lock = NSLock()
        private let result: LocationCapture
        private var calls = 0

        init(_ result: LocationCapture) {
            self.result = result
        }

        var callCount: Int {
            lock.withLock { calls }
        }

        func capture(
            _ accuracyThresholdMeters: Int,
            seed: LocationSample?
        ) async -> LocationCapture {
            lock.withLock { calls += 1 }
            await gate.wait()
            return result
        }

        func release() async {
            await gate.release()
        }
    }

    /// `EvaluationJournaling` é intencionalmente non-throwing. Este probe representa I/O indisponível:
    /// conta a tentativa, mas não retém record algum, para provar que o controller ainda fecha/reagenda.
    private actor UnavailableJournalProbe: EvaluationJournaling {
        struct Attempts: Equatable, Sendable {
            let begins: Int
            let finishes: Int
        }

        private var begins = 0
        private var finishes = 0

        func begin(_ start: EvaluationStart) async {
            begins += 1
        }

        func coalesce(_ event: EvaluationCoalescence) async {}
        func advance(_ progress: EvaluationProgress) async {}
        func recordOwnerExpiration(
            evaluationID: EvaluationID,
            owner: EvaluationJournalOwnerKind,
            cancelledCanonicalWork: Bool
        ) async {}

        func finish(id: EvaluationID, terminal: EvaluationTerminal) async {
            finishes += 1
        }

        func reconcileOrphans() async {}
        func recent(limit: Int) async -> [EvaluationRecord] { [] }
        func clear() async {}

        func attempts() -> Attempts {
            Attempts(begins: begins, finishes: finishes)
        }
    }

    private actor JournalProbe: EvaluationJournaling {
        struct Finish: Equatable, Sendable {
            let evaluationID: EvaluationID
            let outcome: EvaluationTerminalOutcome
            let stage: EvaluationStage?
        }

        struct OwnerExpiration: Equatable, Sendable {
            let evaluationID: EvaluationID
            let owner: EvaluationJournalOwnerKind
            let cancelledCanonicalWork: Bool
        }

        struct Coalescence: Equatable, Sendable {
            let evaluationID: EvaluationID
            let wake: EvaluationWakeKind
            let count: Int
        }

        struct Snapshot: Sendable {
            let begunIDs: [EvaluationID]
            let finishes: [Finish]
            let ownerExpirations: [OwnerExpiration]
            let coalescences: [Coalescence]
        }

        private let blocksFinish: Bool
        private let finishRelease = AsyncGate()
        private var begunIDs: [EvaluationID] = []
        private var finishes: [Finish] = []
        private var ownerExpirations: [OwnerExpiration] = []
        private var coalescences: [Coalescence] = []

        init(blocksFinish: Bool = false) {
            self.blocksFinish = blocksFinish
        }

        func begin(_ start: EvaluationStart) async {
            begunIDs.append(start.id)
        }

        func coalesce(_ event: EvaluationCoalescence) async {
            coalescences.append(Coalescence(
                evaluationID: event.evaluationID,
                wake: event.wake,
                count: event.count
            ))
        }

        func advance(_ progress: EvaluationProgress) async {}

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
            if blocksFinish {
                await finishRelease.wait()
            }
        }

        func reconcileOrphans() async {}
        func recent(limit: Int) async -> [EvaluationRecord] { [] }
        func clear() async {}

        func releaseFinish() async {
            await finishRelease.release()
        }

        func snapshot() -> Snapshot {
            Snapshot(
                begunIDs: begunIDs,
                finishes: finishes,
                ownerExpirations: ownerExpirations,
                coalescences: coalescences
            )
        }
    }

    private actor TicketProbe {
        private var recordedTicket: EvaluationTicket?

        func record(_ ticket: EvaluationTicket) {
            recordedTicket = ticket
        }

        func snapshot() -> EvaluationTicket? {
            recordedTicket
        }
    }

    /// A primeira avaliação pode terminar; a segunda fica no terminal real para verificar que o
    /// controller do BGTask não confunde admissão no slot pending com conclusão canônica.
    private actor TwoStepAutomaticActivities: RunningAutomaticActivities {
        private let secondRelease = AsyncGate()
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
            if calls == 2 {
                await secondRelease.wait()
            }
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

        func callCount() -> Int { calls }

        func releaseSecond() async {
            await secondRelease.release()
        }
    }

    private let now = iso("2026-08-03T10:00:00Z")

    override func setUp() {
        super.setUp()
        EvaluationLog.shared.reset()
    }

    func test_realCandidate_bgExpirationBeforeAcquisitionWaitsForExpiredJournalThenCompletesFalse() async {
        let preferences = activeCandidatePreferences()
        let restoreGate = AsyncGate()
        preferences.accuracyRetryEpisodeGate = restoreGate
        let journal = JournalProbe(blocksFinish: true)
        let lease = LeaseProbe()
        let automatic = SpyAutoActivities()
        let orchestrator = candidateOrchestrator(
            preferences: preferences,
            automatic: automatic,
            journal: journal,
            lease: lease
        )
        let recorder = SystemRecorder()
        let controller = controller(
            orchestrator: orchestrator,
            recorder: recorder
        )

        let handle = controller.start(trigger: .geofence) { recorder.complete($0) }
        await waitUntil { preferences.accuracyRetryEpisodeReadStarted }
        XCTAssertTrue(preferences.accuracyRetryEpisodeReadStarted)

        XCTAssertEqual(handle.expire(), .applied(.workCancelled))
        await restoreGate.release()

        // `finish` já recebeu o terminal, mas fica bloqueado para provar que completion/reagendamento
        // não passam na frente da fronteira de journal.
        await waitUntil {
            let snapshot = await journal.snapshot()
            return snapshot.finishes.count == 1
        }
        let beforeJournalReturns = await journal.snapshot()
        XCTAssertEqual(beforeJournalReturns.finishes, [
            .init(
                evaluationID: beforeJournalReturns.begunIDs[0],
                outcome: .expired,
                stage: .restore
            ),
        ])
        XCTAssertEqual(beforeJournalReturns.ownerExpirations, [
            .init(
                evaluationID: beforeJournalReturns.begunIDs[0],
                owner: .bgAppRefresh,
                cancelledCanonicalWork: true
            ),
        ])
        XCTAssertEqual(automatic.callCount, 0)
        XCTAssertEqual(lease.snapshot.names, [])
        XCTAssertEqual(lease.snapshot.endCount, 0)
        XCTAssertTrue(recorder.completionSnapshot.isEmpty)
        XCTAssertEqual(recorder.scheduleCount, 0)

        await journal.releaseFinish()
        await handle.completion()

        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(handle.expire(), .ignored)
        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertEqual(recorder.scheduleCount, 1)
    }

    func test_realCandidate_lateBGExpirationIsLinkedToTerminalJournalBeforeFalseCompletion() async {
        let preferences = activeCandidatePreferences()
        let journal = JournalProbe(blocksFinish: true)
        let lease = LeaseProbe()
        let automatic = SpyAutoActivities()
        let orchestrator = candidateOrchestrator(
            preferences: preferences,
            automatic: automatic,
            journal: journal,
            lease: lease
        )
        let recorder = SystemRecorder()
        let controller = controller(
            orchestrator: orchestrator,
            recorder: recorder
        )

        let handle = controller.start(trigger: .geofence) { recorder.complete($0) }
        await waitUntil {
            let snapshot = await journal.snapshot()
            return snapshot.finishes.count == 1
        }

        // O trabalho de negócio e a lease UIKit já fecharam, mas `journal.finish` ainda não devolveu.
        // A expiração do BGTask precisa mudar somente a conclusão do sistema para false e anexar sua
        // evidência ao mesmo record, sem reabrir/cancelar o terminal normal.
        XCTAssertEqual(handle.expire(), .applied(.ignored))
        await waitUntil {
            let snapshot = await journal.snapshot()
            return snapshot.ownerExpirations == [
                .init(
                    evaluationID: snapshot.begunIDs[0],
                    owner: .bgAppRefresh,
                    cancelledCanonicalWork: false
                ),
            ]
        }
        let beforeRelease = await journal.snapshot()
        XCTAssertEqual(beforeRelease.finishes.map(\.outcome), [.noAction])
        XCTAssertTrue(recorder.completionSnapshot.isEmpty)
        XCTAssertEqual(recorder.scheduleCount, 0)

        await journal.releaseFinish()
        await handle.completion()

        XCTAssertEqual(lease.snapshot.endCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertEqual(recorder.scheduleCount, 1)
    }

    func test_realCandidate_coalescedBGTicketWaitsForPendingCanonicalTerminal() async {
        let preferences = activeCandidatePreferences()
        let firstKeyGate = AsyncGate()
        preferences.chaveGate = firstKeyGate
        preferences.chaveGateOnCall = 1
        let automatic = TwoStepAutomaticActivities()
        let journal = JournalProbe()
        let lease = LeaseProbe()
        let orchestrator = candidateOrchestrator(
            preferences: preferences,
            automatic: automatic,
            journal: journal,
            lease: lease
        )

        let firstTicket = await orchestrator.evaluationTicket(.geofence)
        XCTAssertEqual(firstTicket.admission, .admitted)
        await waitUntil { preferences.chaveReadStarted }
        XCTAssertTrue(preferences.chaveReadStarted)

        let pendingTicket = await orchestrator.evaluationTicket(.significantLocation)
        XCTAssertEqual(pendingTicket.admission, .deferred)
        let ticketProbe = TicketProbe()
        let recorder = SystemRecorder()
        let controller = controller(
            orchestrator: orchestrator,
            recorder: recorder,
            ticketProbe: ticketProbe
        )
        let handle = controller.start(trigger: .geofence) { recorder.complete($0) }

        await waitUntil {
            await ticketProbe.snapshot()?.admission == .coalesced
        }
        guard let bgTicket = await ticketProbe.snapshot() else {
            return XCTFail("The BG request was not admitted into the pending canonical ticket.")
        }
        XCTAssertEqual(bgTicket.evaluationID, pendingTicket.evaluationID)
        XCTAssertEqual(recorder.completionSnapshot, [])
        XCTAssertEqual(recorder.scheduleCount, 0)

        await firstKeyGate.release()
        let firstCompletion = await firstTicket.completion()
        XCTAssertEqual(firstCompletion.outcome, .noAction)

        await waitUntil { await automatic.callCount() == 2 }
        let automaticCallCount = await automatic.callCount()
        XCTAssertEqual(automaticCallCount, 2)
        let whilePendingTerminalIsBlocked = await journal.snapshot()
        XCTAssertEqual(whilePendingTerminalIsBlocked.finishes.count, 1)
        XCTAssertTrue(recorder.completionSnapshot.isEmpty)
        XCTAssertEqual(recorder.scheduleCount, 0)

        await automatic.releaseSecond()
        await handle.completion()
        let pendingCompletion = await pendingTicket.completion()

        XCTAssertEqual(pendingCompletion.evaluationID, pendingTicket.evaluationID)
        XCTAssertEqual(pendingCompletion.outcome, .noAction)
        XCTAssertEqual(recorder.completionSnapshot, [true])
        XCTAssertEqual(recorder.scheduleCount, 1)
        let finalJournal = await journal.snapshot()
        XCTAssertEqual(finalJournal.begunIDs, [
            firstTicket.evaluationID,
            pendingTicket.evaluationID,
        ])
        XCTAssertEqual(finalJournal.finishes.map(\.evaluationID), [
            firstTicket.evaluationID,
            pendingTicket.evaluationID,
        ])
    }

    func test_realCandidate_submitResponseCancelledAfterDispatchIsUnknownWithoutAutomaticQueue() async {
        let preferences = activeCandidatePreferences()
        let repository = configuredRepository()
        let submitGate = AsyncGate()
        repository.submitGate = submitGate
        repository.submitResult = .failure(.network)
        let queue = FakeOfflineQueue()
        let journal = JournalProbe()
        let lease = LeaseProbe()
        let locationProvider = FakeLocationProvider(.success(sample()))
        let automatic = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: CaptureLocationUseCase(
                locationProvider: locationProvider,
                checkRepository: repository,
                activityLogger: NoopActivityLogger(),
                clock: FixedClock(now),
                samplePolicy: .candidateTrial,
                captureBehavior: .freshnessValidated
            ),
            checkRepository: repository,
            offlineQueue: queue,
            clock: FixedClock(now),
            activityLogger: NoopActivityLogger(),
            makeClientEventID: { "prompt14-submission-id" }
        )
        let orchestrator = candidateOrchestrator(
            preferences: preferences,
            automatic: automatic,
            journal: journal,
            lease: lease,
            checkRepository: repository,
            locationProvider: locationProvider
        )
        let ticketProbe = TicketProbe()
        let recorder = SystemRecorder()
        let controller = controller(
            orchestrator: orchestrator,
            recorder: recorder,
            ticketProbe: ticketProbe
        )

        let handle = controller.start(trigger: .geofence) { recorder.complete($0) }
        await waitUntil {
            repository.submitCount == 1 && lease.snapshot.names.count == 1
        }
        XCTAssertEqual(repository.submitCount, 1)
        let submittedRequest = try? XCTUnwrap(repository.submitCalls.first)
        XCTAssertEqual(submittedRequest?.clientEventId, "prompt14-submission-id")
        XCTAssertEqual(submittedRequest?.eventTime, now)

        // O BG owner expira primeiro, mas a lease UIKit ainda sustenta a avaliação. O task do sistema
        // recebe false uma única vez; o trabalho canônico só é cancelado quando a última lease expira.
        XCTAssertEqual(handle.expire(), .applied(.workContinues))
        await waitUntil { recorder.completionSnapshot == [false] }
        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertTrue(lease.expireLatestLease())
        await submitGate.release()

        await waitUntil {
            let snapshot = await journal.snapshot()
            return snapshot.finishes.count == 1
        }
        let terminalSnapshot = await journal.snapshot()
        XCTAssertEqual(terminalSnapshot.finishes.map(\.outcome), [.submissionOutcomeUnknown])
        XCTAssertEqual(terminalSnapshot.finishes.map(\.stage), [.submit])
        XCTAssertEqual(
            Set(terminalSnapshot.ownerExpirations.map(\.owner)),
            [.bgAppRefresh, .uiBackgroundTask]
        )
        XCTAssertTrue(terminalSnapshot.ownerExpirations.contains(
            .init(
                evaluationID: terminalSnapshot.begunIDs[0],
                owner: .bgAppRefresh,
                cancelledCanonicalWork: false
            )
        ))
        XCTAssertTrue(terminalSnapshot.ownerExpirations.contains(
            .init(
                evaluationID: terminalSnapshot.begunIDs[0],
                owner: .uiBackgroundTask,
                cancelledCanonicalWork: true
            )
        ))
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertEqual(lease.snapshot.endCount, 1)
        XCTAssertEqual(lease.snapshot.expirationRequests, 1)

        guard let ticket = await ticketProbe.snapshot() else {
            return XCTFail("The real controller did not retain the canonical evaluation ticket.")
        }
        let completion = await ticket.completion()
        XCTAssertEqual(completion.outcome, .submissionOutcomeUnknown)
        XCTAssertFalse(completion.completedBeforeExpiration)
        await handle.completion()
        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertEqual(recorder.scheduleCount, 1)
    }

    func test_realCandidate_uikitThenBGExpirationDuringAcquisitionStopsBeforeMatchAndEndsLeaseOnce() async {
        let preferences = activeCandidatePreferences()
        let repository = configuredRepository()
        let provider = GatedLocationProvider(.success(sample()))
        let queue = FakeOfflineQueue()
        let automatic = realAutomaticActivities(
            repository: repository,
            locationProvider: provider,
            queue: queue,
            clientEventID: "prompt14-acquisition-id"
        )
        let journal = JournalProbe()
        let uikitOperations = UIKitTaskOperations(token: 91)
        let orchestrator = candidateOrchestrator(
            preferences: preferences,
            automatic: automatic,
            journal: journal,
            lease: uikitOperations.makeLeasing(),
            checkRepository: repository,
            locationProvider: provider
        )
        let recorder = SystemRecorder()
        let controller = controller(orchestrator: orchestrator, recorder: recorder)

        let handle = controller.start(trigger: .geofence) { recorder.complete($0) }
        await waitUntil {
            provider.callCount == 1
                && uikitOperations.snapshot.beginNames == ["Checking candidate automatic evaluation"]
        }
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(uikitOperations.snapshot.expirationInstallations, 1)

        // A expiração UIKit libera apenas sua lease; o BGTask ainda sustenta o trabalho. Quando o
        // orçamento BG também vence, ele é o último owner e cancela o pipeline real de acquisition.
        XCTAssertTrue(uikitOperations.fireExpiration())
        XCTAssertEqual(handle.expire(), .applied(.workCancelled))
        await provider.release()
        await handle.completion()

        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.finishes.map(\.outcome), [.expired])
        XCTAssertEqual(snapshot.finishes.map(\.stage), [.acquisition])
        XCTAssertEqual(
            Set(snapshot.ownerExpirations.map(\.owner)),
            [.bgAppRefresh, .uiBackgroundTask]
        )
        XCTAssertTrue(snapshot.ownerExpirations.contains(
            .init(
                evaluationID: snapshot.begunIDs[0],
                owner: .uiBackgroundTask,
                cancelledCanonicalWork: false
            )
        ))
        XCTAssertTrue(snapshot.ownerExpirations.contains(
            .init(
                evaluationID: snapshot.begunIDs[0],
                owner: .bgAppRefresh,
                cancelledCanonicalWork: true
            )
        ))
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertEqual(uikitOperations.snapshot.endTokens, [91])
        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertEqual(recorder.scheduleCount, 1)
    }

    func test_realCandidate_expirationDuringStateDoesNotStartAcquisitionOrSubmit() async {
        let preferences = activeCandidatePreferences()
        let repository = configuredRepository()
        let stateGate = AsyncGate()
        repository.getStateGate = stateGate
        let provider = FakeLocationProvider(.success(sample()))
        let queue = FakeOfflineQueue()
        let automatic = realAutomaticActivities(
            repository: repository,
            locationProvider: provider,
            queue: queue,
            clientEventID: "prompt14-state-id"
        )
        let journal = JournalProbe()
        let lease = LeaseProbe()
        let orchestrator = candidateOrchestrator(
            preferences: preferences,
            automatic: automatic,
            journal: journal,
            lease: lease,
            checkRepository: repository,
            locationProvider: provider
        )
        let recorder = SystemRecorder()
        let controller = controller(orchestrator: orchestrator, recorder: recorder)

        let handle = controller.start(trigger: .geofence) { recorder.complete($0) }
        await waitUntil { repository.getStateCallCount == 1 && lease.snapshot.names.count == 1 }
        XCTAssertEqual(repository.getStateCallCount, 1)

        XCTAssertTrue(lease.expireLatestLease())
        XCTAssertEqual(handle.expire(), .applied(.workCancelled))
        await stateGate.release()
        await handle.completion()

        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.finishes.map(\.outcome), [.expired])
        XCTAssertEqual(snapshot.finishes.map(\.stage), [.state])
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertEqual(lease.snapshot.endCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertEqual(recorder.scheduleCount, 1)
    }

    func test_realCandidate_expirationDuringMatchDoesNotAdvanceToSubmit() async {
        let preferences = activeCandidatePreferences()
        let repository = configuredRepository()
        let matchGate = AsyncGate()
        repository.matchLocationGate = matchGate
        let provider = FakeLocationProvider(.success(sample()))
        let queue = FakeOfflineQueue()
        let automatic = realAutomaticActivities(
            repository: repository,
            locationProvider: provider,
            queue: queue,
            clientEventID: "prompt14-match-id"
        )
        let journal = JournalProbe()
        let lease = LeaseProbe()
        let orchestrator = candidateOrchestrator(
            preferences: preferences,
            automatic: automatic,
            journal: journal,
            lease: lease,
            checkRepository: repository,
            locationProvider: provider
        )
        let recorder = SystemRecorder()
        let controller = controller(orchestrator: orchestrator, recorder: recorder)

        let handle = controller.start(trigger: .geofence) { recorder.complete($0) }
        await waitUntil { repository.matchLocationCallCount == 1 && lease.snapshot.names.count == 1 }
        XCTAssertEqual(repository.matchLocationCallCount, 1)

        XCTAssertTrue(lease.expireLatestLease())
        XCTAssertEqual(handle.expire(), .applied(.workCancelled))
        await matchGate.release()
        await handle.completion()

        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.finishes.map(\.outcome), [.expired])
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertEqual(lease.snapshot.endCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertEqual(recorder.scheduleCount, 1)
    }

    func test_realCandidate_expirationAfterConfirmedSubmitBeforeJournalKeepsTerminalButCompletesFalse() async {
        let preferences = activeCandidatePreferences()
        let repository = configuredRepository()
        let queue = FakeOfflineQueue()
        let provider = FakeLocationProvider(.success(sample()))
        let automatic = realAutomaticActivities(
            repository: repository,
            locationProvider: provider,
            queue: queue,
            clientEventID: "prompt14-confirmed-submit-id"
        )
        let journal = JournalProbe(blocksFinish: true)
        let lease = LeaseProbe()
        let orchestrator = candidateOrchestrator(
            preferences: preferences,
            automatic: automatic,
            journal: journal,
            lease: lease,
            checkRepository: repository,
            locationProvider: provider
        )
        let recorder = SystemRecorder()
        let controller = controller(orchestrator: orchestrator, recorder: recorder)

        let handle = controller.start(trigger: .geofence) { recorder.complete($0) }
        await waitUntil {
            guard repository.submitCount == 1 else { return false }
            return (await journal.snapshot()).finishes.count == 1
        }
        XCTAssertEqual(repository.submitCount, 1)
        let submit = try? XCTUnwrap(repository.submitCalls.first)
        XCTAssertEqual(submit?.clientEventId, "prompt14-confirmed-submit-id")
        XCTAssertEqual(submit?.eventTime, now)
        XCTAssertEqual(lease.snapshot.endCount, 1)

        // O submit já tem resposta conhecida; uma expiração tardia não o reabre nem o transforma em
        // recovery/queue. Ela só torna a conclusão do orçamento do sistema false e fica ligada ao record.
        XCTAssertEqual(handle.expire(), .applied(.ignored))
        await waitUntil {
            let snapshot = await journal.snapshot()
            return snapshot.ownerExpirations.contains(
                .init(
                    evaluationID: snapshot.begunIDs[0],
                    owner: .bgAppRefresh,
                    cancelledCanonicalWork: false
                )
            )
        }
        let beforeJournalRelease = await journal.snapshot()
        XCTAssertEqual(beforeJournalRelease.finishes.map(\.outcome), [.submittedCheckIn])
        XCTAssertEqual(beforeJournalRelease.finishes.map(\.stage), [.submit])
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertTrue(recorder.completionSnapshot.isEmpty)
        XCTAssertEqual(recorder.scheduleCount, 0)

        await journal.releaseFinish()
        await handle.completion()

        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertEqual(recorder.scheduleCount, 1)
    }

    func test_realCandidate_unavailableJournalStillReschedulesAndCompletesControlledTerminal() async {
        let preferences = activeCandidatePreferences()
        let repository = configuredRepository()
        repository.matchLocationResult = .success(ucMatch(.noKnownLocations))
        let queue = FakeOfflineQueue()
        let provider = FakeLocationProvider(.success(sample()))
        let automatic = realAutomaticActivities(
            repository: repository,
            locationProvider: provider,
            queue: queue,
            clientEventID: "prompt14-journal-unavailable-id"
        )
        let journal = UnavailableJournalProbe()
        let lease = LeaseProbe()
        let orchestrator = candidateOrchestrator(
            preferences: preferences,
            automatic: automatic,
            journal: journal,
            lease: lease,
            checkRepository: repository,
            locationProvider: provider
        )
        let recorder = SystemRecorder()
        let controller = controller(orchestrator: orchestrator, recorder: recorder)

        let handle = controller.start(trigger: .geofence) { recorder.complete($0) }
        await handle.completion()

        let journalAttempts = await journal.attempts()
        XCTAssertEqual(journalAttempts, .init(begins: 1, finishes: 1))
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertEqual(lease.snapshot.endCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [true])
        XCTAssertEqual(recorder.scheduleCount, 1)
    }

    private func controller(
        orchestrator: BackgroundCheckOrchestrator,
        recorder: SystemRecorder,
        ticketProbe: TicketProbe? = nil
    ) -> BGAppRefreshExecutionController {
        BGAppRefreshExecutionController(
            startEvaluation: { trigger, registration in
                let ticket = await orchestrator.evaluationTicket(
                    trigger,
                    ownerRegistration: registration
                )
                await ticketProbe?.record(ticket)
                return ticket
            },
            scheduleRegularRefresh: { recorder.schedule() }
        )
    }

    private func candidateOrchestrator(
        preferences: FakeAppPreferences,
        automatic: any RunningAutomaticActivities,
        journal: any EvaluationJournaling,
        lease: any BackgroundExecutionLeasing,
        checkRepository: (any CheckRepository)? = nil,
        locationProvider: (any LocationProvider)? = nil
    ) -> BackgroundCheckOrchestrator {
        makeOrchestrator(
            prefs: preferences,
            checkRepository: checkRepository ?? configuredRepository(),
            autoActivities: automatic,
            locationProvider: locationProvider ?? FakeLocationProvider(.success(sample())),
            automaticEvaluationPipeline: .candidate,
            clock: FixedClock(now),
            evaluationJournal: journal,
            backgroundExecutionLeasing: lease
        )
    }

    private func realAutomaticActivities(
        repository: any CheckRepository,
        locationProvider: any LocationProvider,
        queue: any OfflineCheckQueueing,
        clientEventID: String
    ) -> RunAutomaticActivitiesUseCase {
        RunAutomaticActivitiesUseCase(
            captureLocationUseCase: CaptureLocationUseCase(
                locationProvider: locationProvider,
                checkRepository: repository,
                activityLogger: NoopActivityLogger(),
                clock: FixedClock(now),
                samplePolicy: .candidateTrial,
                captureBehavior: .freshnessValidated
            ),
            checkRepository: repository,
            offlineQueue: queue,
            clock: FixedClock(now),
            activityLogger: NoopActivityLogger(),
            makeClientEventID: { clientEventID }
        )
    }

    private func activeCandidatePreferences() -> FakeAppPreferences {
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
        let preferences = FakeAppPreferences()
        preferences.chaveValue = "HR70"
        preferences.languageValue = "pt"
        preferences.userSettingsJsonValue = String(data: data, encoding: .utf8)!
        return preferences
    }

    private func configuredRepository() -> FakeCheckRepository {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(LocationOptions(
            items: ["Test Location"],
            accuracyThresholdMeters: 50,
            mixedZoneIntervalMinutes: 15
        ))
        repository.matchLocationResult = .success(LocationMatch(
            matched: true,
            resolvedLocal: "Test Location",
            label: "Test Location",
            status: .matched,
            message: "",
            accuracyMeters: 12,
            accuracyThresholdMeters: 50,
            minimumCheckoutDistanceMeters: 2_000,
            nearestWorkplaceDistanceMeters: nil
        ))
        repository.getStateResult = .success(HistoryState(
            found: true,
            chave: "HR70",
            projeto: "P80",
            currentAction: .checkOut,
            currentLocal: nil,
            hasCurrentDayCheckin: false,
            lastCheckinAt: nil,
            lastCheckoutAt: now.addingTimeInterval(-600),
            transportEnabled: false
        ))
        repository.submitResult = .success(HistoryState(
            found: true,
            chave: "HR70",
            projeto: "P80",
            currentAction: .checkIn,
            currentLocal: "Test Location",
            hasCurrentDayCheckin: true,
            lastCheckinAt: now,
            lastCheckoutAt: nil,
            transportEnabled: false
        ))
        return repository
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
}
