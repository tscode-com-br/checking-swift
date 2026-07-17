import XCTest
@testable import Checking

// Port do gatilho NetworkType.CONNECTED (SyncPendingChecksWorker) — drena ao reconectar; single-flight.
final class OfflineSyncCoordinatorTests: XCTestCase {

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

    func test_single_flight_blocks_overlapping_drain() async {
        let gate = AsyncGate()
        let replayer = SpyDrainer()
        let started = expectation(description: "first drain started")
        replayer.onDrain = { started.fulfill() }
        replayer.block = { await gate.wait() }
        let coordinator = OfflineSyncCoordinator(replayer: replayer, monitor: FakeNetworkMonitor(online: false))

        let first = Task { await coordinator.triggerDrain() }
        await fulfillment(of: [started], timeout: 2)       // 1º drain em andamento (bloqueado no gate)
        await coordinator.triggerDrain()                   // 2º — single-flight → no-op
        XCTAssertEqual(replayer.count, 1)
        await gate.release()
        await first.value
        XCTAssertEqual(replayer.count, 1)
    }
}
