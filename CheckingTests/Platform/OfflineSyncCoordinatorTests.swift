import XCTest
@testable import Checking

// Port do gatilho NetworkType.CONNECTED (SyncPendingChecksWorker) — drena ao reconectar; single-flight.
final class OfflineSyncCoordinatorTests: XCTestCase {
    private final class CancellationAwareDrainer: OfflineDraining, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        var count: Int { lock.withLock { calls } }

        func drain() async -> DrainResult {
            lock.withLock { calls += 1 }
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return .completed
            } catch {
                return .retry
            }
        }
    }

    func test_drains_on_transition_to_online() async {
        let replayer = SpyDrainer()
        let drained = expectation(description: "drained")
        replayer.onDrain = { drained.fulfill() }
        let monitor = FakeNetworkMonitor(online: false)
        let coordinator = OfflineSyncCoordinator(replayer: replayer, monitor: monitor)
        await coordinator.start()
        await waitUntil { monitor.subscriberCount == 1 }   // o observador assinou
        monitor.set(true)                                  // offline → online
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(replayer.count, 1)
        await coordinator.stop()
    }

    func test_first_online_triggers_drain() async {
        let replayer = SpyDrainer()
        let drained = expectation(description: "drained")
        replayer.onDrain = { drained.fulfill() }
        let coordinator = OfflineSyncCoordinator(replayer: replayer, monitor: FakeNetworkMonitor(online: true))
        await coordinator.start()
        await fulfillment(of: [drained], timeout: 2)       // já online → dispara no 1º estado
        XCTAssertEqual(replayer.count, 1)
        await coordinator.stop()
    }

    func test_no_duplicate_drain_while_staying_online() async {
        let replayer = SpyDrainer()
        let monitor = FakeNetworkMonitor(online: false)
        let coordinator = OfflineSyncCoordinator(replayer: replayer, monitor: monitor)
        await coordinator.start()
        await waitUntil { monitor.subscriberCount == 1 }
        monitor.set(true)
        monitor.set(true)                                  // no-op (distinct) → sem segundo drain
        await waitUntil { replayer.count == 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(replayer.count, 1)
        await coordinator.stop()
    }

    func test_concurrentTriggersShareOneDrainAndTheSameTerminal() async {
        let gate = AsyncGate()
        let replayer = SpyDrainer()
        let started = expectation(description: "first drain started")
        replayer.onDrain = { started.fulfill() }
        replayer.block = { await gate.wait() }
        let coordinator = OfflineSyncCoordinator(replayer: replayer, monitor: FakeNetworkMonitor(online: false))

        let first = Task { await coordinator.triggerDrain() }
        await fulfillment(of: [started], timeout: 2)       // 1º drain em andamento (bloqueado no gate)
        let second = Task { await coordinator.triggerDrain() }
        await Task.yield()
        XCTAssertEqual(replayer.count, 1)
        await gate.release()
        let firstResult = await first.value
        let secondResult = await second.value

        XCTAssertEqual(firstResult, .completed)
        XCTAssertEqual(secondResult, .completed)
        XCTAssertEqual(replayer.count, 1)
    }

    func test_cancellingOneWaiterDoesNotCancelTheCanonicalDrainOrOtherWaiters() async {
        let gate = AsyncGate()
        let replayer = SpyDrainer()
        replayer.block = { await gate.wait() }
        let coordinator = OfflineSyncCoordinator(
            replayer: replayer,
            monitor: FakeNetworkMonitor(online: false)
        )

        let cancelledWaiter = Task { await coordinator.triggerDrain() }
        await waitUntil { replayer.count == 1 }
        let survivingWaiter = Task { await coordinator.triggerDrain() }
        await Task.yield()

        cancelledWaiter.cancel()
        XCTAssertEqual(replayer.count, 1)
        await gate.release()

        let cancelledWaiterResult = await cancelledWaiter.value
        let survivingWaiterResult = await survivingWaiter.value
        XCTAssertEqual(cancelledWaiterResult, .completed)
        XCTAssertEqual(survivingWaiterResult, .completed)
        XCTAssertEqual(replayer.count, 1)
    }

    func test_triggerDrainReturnsRetryForBGProcessingControllerMapping() async {
        let replayer = SpyDrainer()
        replayer.result = .retry
        let coordinator = OfflineSyncCoordinator(
            replayer: replayer,
            monitor: FakeNetworkMonitor(online: false)
        )

        let result = await coordinator.triggerDrain()

        XCTAssertEqual(result, .retry)
        XCTAssertEqual(replayer.count, 1)
    }

    func test_ticketCanCancelCanonicalWorkWhenFutureOwnershipReleasesLastOwner() async {
        let replayer = CancellationAwareDrainer()
        let coordinator = OfflineSyncCoordinator(
            replayer: replayer,
            monitor: FakeNetworkMonitor(online: false)
        )

        let ticket = await coordinator.drainTicket()
        await waitUntil { replayer.count == 1 }
        ticket.cancelCanonicalWork()

        let result = await ticket.completion()
        XCTAssertEqual(result, .retry)
        XCTAssertEqual(replayer.count, 1)
    }
}
