import Foundation
import XCTest
@testable import Checking

final class BGProcessingExecutionControllerTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var startedTicketIDs: [UUID] = []
        private var startedCount = 0
        private var schedules = 0
        private var completions: [Bool] = []

        func recordStartRequest() {
            lock.withLock { startedCount += 1 }
        }

        func record(ticket: UUID) {
            lock.withLock { startedTicketIDs.append(ticket) }
        }

        func schedule() {
            lock.withLock { schedules += 1 }
        }

        func complete(_ success: Bool) {
            lock.withLock { completions.append(success) }
        }

        var startRequestCount: Int { lock.withLock { startedCount } }
        var ticketIDs: [UUID] { lock.withLock { startedTicketIDs } }
        var scheduleCount: Int { lock.withLock { schedules } }
        var completionSnapshot: [Bool] { lock.withLock { completions } }
    }

    /// Ticket determinístico: só o controller faz o await canônico; testes usam `resolve` para modelar
    /// o terminal do replayer e `cancelCanonicalWork` resolve `.retry` sem apagar o evento durável.
    private final class ControlledDrainTicket: OfflineDrainExecutionTicket, @unchecked Sendable {
        let id = UUID()

        private let lock = NSLock()
        private var terminalResult: DrainResult?
        private var continuation: CheckedContinuation<DrainResult, Never>?
        private var completionAwaitCount = 0
        private var canonicalCancellationCount = 0

        init(result: DrainResult? = nil) {
            terminalResult = result
        }

        func completion() async -> DrainResult {
            lock.withLock { completionAwaitCount += 1 }
            return await withCheckedContinuation { continuation in
                let readyResult = lock.withLock { () -> DrainResult? in
                    if let terminalResult { return terminalResult }
                    precondition(
                        self.continuation == nil,
                        "ControlledDrainTicket has more than one canonical waiter."
                    )
                    self.continuation = continuation
                    return nil
                }
                if let readyResult {
                    continuation.resume(returning: readyResult)
                }
            }
        }

        func cancelCanonicalWork() {
            lock.withLock { canonicalCancellationCount += 1 }
            resolve(.retry)
        }

        func resolve(_ result: DrainResult) {
            let continuation = lock.withLock { () -> CheckedContinuation<DrainResult, Never>? in
                guard terminalResult == nil else { return nil }
                terminalResult = result
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: result)
        }

        var completionCalls: Int { lock.withLock { completionAwaitCount } }
        var cancellationCalls: Int { lock.withLock { canonicalCancellationCount } }
    }

    /// Modelo mínimo de fila: cancelamento do replay mantém o evento pendente e devolve `.retry`.
    private final class CancellationAwareDurableDrainer: OfflineDraining, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var pendingEvents = 1

        var count: Int { lock.withLock { calls } }
        var pendingEventCount: Int { lock.withLock { pendingEvents } }

        func drain() async -> DrainResult {
            lock.withLock { calls += 1 }
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                lock.withLock { pendingEvents = 0 }
                return .completed
            } catch {
                // Equivale ao fence do replayer: não remove o evento quando a resposta/trabalho é
                // interrompido. O ticket canônico permanece a única autoridade que recebeu cancelamento.
                return .retry
            }
        }
    }

    func test_completedDrainUsesCanonicalTicketAndCompletesTrueOnce() async {
        let recorder = Recorder()
        let ticket = ControlledDrainTicket(result: .completed)
        let sut = makeController(recorder: recorder, ticket: ticket)

        let handle = sut.start { recorder.complete($0) }
        await handle.completion()

        XCTAssertEqual(recorder.ticketIDs, [ticket.id])
        XCTAssertEqual(ticket.completionCalls, 1)
        XCTAssertEqual(ticket.cancellationCalls, 0)
        XCTAssertEqual(recorder.scheduleCount, 0)
        XCTAssertEqual(recorder.completionSnapshot, [true])
        XCTAssertEqual(handle.expire(), .ignored)
    }

    func test_retryIsControlledBecauseQueueIsAlreadyDurable() async {
        let recorder = Recorder()
        let ticket = ControlledDrainTicket(result: .retry)
        let sut = makeController(recorder: recorder, ticket: ticket)

        let handle = sut.start { recorder.complete($0) }
        await handle.completion()

        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [true])
        XCTAssertEqual(ticket.cancellationCalls, 0)
    }

    func test_expirationDuringCanonicalDrainCancelsItOnceAndCompletesFalse() async {
        let recorder = Recorder()
        let ticket = ControlledDrainTicket()
        let sut = makeController(recorder: recorder, ticket: ticket)

        let handle = sut.start { recorder.complete($0) }
        await waitUntil { ticket.completionCalls == 1 }

        XCTAssertEqual(handle.expire(), .applied(.workCancelled))
        await handle.completion()

        XCTAssertEqual(ticket.cancellationCalls, 1)
        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertEqual(handle.workOwnership.cancellationContext.reason, .bgTaskExpired)
        XCTAssertEqual(handle.expire(), .ignored)
    }

    func test_expirationBeforeTicketAdmissionCancelsImmediatelyAfterAttachment() async {
        let recorder = Recorder()
        let ticket = ControlledDrainTicket()
        let admissionGate = AsyncGate()
        let sut = BGProcessingExecutionController(
            startDrain: {
                recorder.recordStartRequest()
                await admissionGate.wait()
                recorder.record(ticket: ticket.id)
                return ticket
            },
            scheduleProcessing: { recorder.schedule() }
        )

        let handle = sut.start { recorder.complete($0) }
        await waitUntil { recorder.startRequestCount == 1 }

        XCTAssertEqual(handle.expire(), .applied(.workCancelled))
        await admissionGate.release()
        await handle.completion()

        XCTAssertEqual(recorder.ticketIDs, [ticket.id])
        XCTAssertEqual(ticket.cancellationCalls, 1)
        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [false])
    }

    func test_expirationAfterTerminalIsIgnoredAndCannotRecomplete() async {
        let recorder = Recorder()
        let ticket = ControlledDrainTicket(result: .completed)
        let sut = makeController(recorder: recorder, ticket: ticket)

        let handle = sut.start { recorder.complete($0) }
        await handle.completion()

        XCTAssertEqual(handle.expire(), .ignored)
        XCTAssertEqual(ticket.cancellationCalls, 0)
        XCTAssertEqual(recorder.scheduleCount, 0)
        XCTAssertEqual(recorder.completionSnapshot, [true])
    }

    func test_expiringBGProcessingOwnerDoesNotCancelDrainWhenAnotherOwnerIsValid() async {
        let ownership = BackgroundWorkOwnership()
        let uiOwner = tryAcquire(.uiBackgroundTask, from: ownership)
        let recorder = Recorder()
        let ticket = ControlledDrainTicket()
        let sut = makeController(recorder: recorder, ticket: ticket)

        let handle = sut.start(ownership: ownership) { recorder.complete($0) }
        await waitUntil { !recorder.ticketIDs.isEmpty }

        XCTAssertEqual(handle.expire(), .applied(.workContinues))
        await handle.completion()

        XCTAssertEqual(ticket.cancellationCalls, 0)
        XCTAssertFalse(ownership.cancellationContext.isCancelled)
        XCTAssertEqual(ownership.activeOwnerCount, 1)
        XCTAssertEqual(recorder.scheduleCount, 0)
        XCTAssertEqual(recorder.completionSnapshot, [false])

        XCTAssertTrue(ownership.release(uiOwner))
        ticket.resolve(.completed)
    }

    func test_contextInvalidationCancelsAllOwnersAndTheCanonicalDrainOnce() async {
        let ownership = BackgroundWorkOwnership()
        let uiOwner = tryAcquire(.uiBackgroundTask, from: ownership)
        let recorder = Recorder()
        let ticket = ControlledDrainTicket()
        let sut = makeController(recorder: recorder, ticket: ticket)

        let handle = sut.start(ownership: ownership) { recorder.complete($0) }
        await waitUntil { ticket.completionCalls == 1 }

        XCTAssertTrue(ownership.invalidateContext())
        await handle.completion()

        XCTAssertEqual(ownership.cancellationContext.reason, .contextInvalidated)
        XCTAssertEqual(ownership.activeOwnerCount, 0)
        XCTAssertEqual(ticket.cancellationCalls, 1)
        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [false])
        XCTAssertEqual(handle.expire(), .ignored)
        _ = uiOwner // O token pertence ao owner já removido pela invalidação global.
    }

    func test_realOfflineDrainTicketCancellationPreservesDurableEvent() async {
        let drainer = CancellationAwareDurableDrainer()
        let coordinator = OfflineSyncCoordinator(
            replayer: drainer,
            monitor: FakeNetworkMonitor(online: false)
        )
        let recorder = Recorder()
        let sut = BGProcessingExecutionController(
            startDrain: {
                let ticket = await coordinator.drainTicket()
                recorder.record(ticket: ticket.id)
                return ticket
            },
            scheduleProcessing: { recorder.schedule() }
        )

        let handle = sut.start { recorder.complete($0) }
        await waitUntil { drainer.count == 1 }

        XCTAssertEqual(handle.expire(), .applied(.workCancelled))
        await handle.completion()

        XCTAssertEqual(drainer.pendingEventCount, 1)
        XCTAssertEqual(recorder.ticketIDs.count, 1)
        XCTAssertEqual(recorder.scheduleCount, 1)
        XCTAssertEqual(recorder.completionSnapshot, [false])
    }

    func test_terminalAndManyExpirationCallsRaceThroughOneFinalizer() async {
        let recorder = Recorder()
        let ticket = ControlledDrainTicket()
        let sut = makeController(recorder: recorder, ticket: ticket)

        let handle = sut.start { recorder.complete($0) }
        await waitUntil { ticket.completionCalls == 1 }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { _ = handle.expire() }
            }
            group.addTask { ticket.resolve(.completed) }
        }
        await handle.completion()

        XCTAssertTrue(recorder.scheduleCount == 0 || recorder.scheduleCount == 1)
        XCTAssertEqual(recorder.completionSnapshot.count, 1)
        XCTAssertLessThanOrEqual(ticket.cancellationCalls, 1)
        XCTAssertTrue(recorder.completionSnapshot == [true] || recorder.completionSnapshot == [false])
    }

    func test_cancellingOneCompletionWaiterDoesNotCancelDrainOrOtherWaiter() async {
        let recorder = Recorder()
        let ticket = ControlledDrainTicket()
        let sut = makeController(recorder: recorder, ticket: ticket)

        let handle = sut.start { recorder.complete($0) }
        await waitUntil { ticket.completionCalls == 1 }
        let cancelledWaiter = Task { await handle.completion() }
        let survivingWaiter = Task { await handle.completion() }

        cancelledWaiter.cancel()
        await Task.yield()
        XCTAssertTrue(recorder.completionSnapshot.isEmpty)
        XCTAssertEqual(ticket.cancellationCalls, 0)

        ticket.resolve(.completed)
        await cancelledWaiter.value
        await survivingWaiter.value

        XCTAssertEqual(recorder.scheduleCount, 0)
        XCTAssertEqual(recorder.completionSnapshot, [true])
    }

    func test_policyMakesCancellationWinOverDurableRetry() {
        XCTAssertEqual(
            BGProcessingCompletionPolicy.disposition(for: .completed, cancellationReason: nil),
            BGProcessingCompletionDisposition(success: true, shouldReschedule: false)
        )
        XCTAssertEqual(
            BGProcessingCompletionPolicy.disposition(for: .retry, cancellationReason: nil),
            BGProcessingCompletionDisposition(success: true, shouldReschedule: true)
        )

        for reason in [
            EvaluationCancellationReason.bgTaskExpired,
            .uiBackgroundTimeExpired,
            .contextInvalidated,
            .taskCancelled,
        ] {
            XCTAssertEqual(
                BGProcessingCompletionPolicy.disposition(for: .retry, cancellationReason: reason),
                BGProcessingCompletionDisposition(success: false, shouldReschedule: true)
            )
        }
    }

    private func makeController(
        recorder: Recorder,
        ticket: ControlledDrainTicket
    ) -> BGProcessingExecutionController {
        BGProcessingExecutionController(
            startDrain: {
                recorder.recordStartRequest()
                recorder.record(ticket: ticket.id)
                return ticket
            },
            scheduleProcessing: { recorder.schedule() }
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
