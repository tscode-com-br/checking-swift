import XCTest
@testable import Checking

// Semântica do monitor (port de NetworkMonitor.isOnline): emite atual + distinct; waitUntilOnline.
final class NetworkMonitoringTests: XCTestCase {

    func test_emits_current_then_distinct_changes() async {
        let monitor = FakeNetworkMonitor(online: false)
        let received = Task { () -> [Bool] in
            var out: [Bool] = []
            for await value in monitor.onlineStates() { out.append(value); if out.count == 3 { break } }
            return out
        }
        await waitUntil { monitor.subscriberCount == 1 }   // assinou → estado atual emitido
        monitor.set(true)
        monitor.set(true)                                  // no-op (distinctUntilChanged)
        monitor.set(false)
        let out = await received.value
        XCTAssertEqual(out, [false, true, false])
    }

    func test_waitUntilOnline_returns_immediately_when_online() async {
        await FakeNetworkMonitor(online: true).waitUntilOnline()   // não trava
    }

    func test_waitUntilOnline_waits_for_reconnect() async {
        let monitor = FakeNetworkMonitor(online: false)
        let waited = Task { await monitor.waitUntilOnline() }
        await waitUntil { monitor.subscriberCount == 1 }
        monitor.set(true)
        await waited.value                                 // completa quando volta online
    }
}
