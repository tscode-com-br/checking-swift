import XCTest
@testable import Checking

private final class WakeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@MainActor
final class CLLocationManagerSignificantChangeMonitorTests: XCTestCase {
    func test_delegateIsInstalledImmediatelyAndWakeReachesCallbackWhenActive() async {
        let counter = WakeCounter()
        let monitor = CLLocationManagerSignificantChangeMonitor(
            activityLogger: NoopActivityLogger(),
            startsImmediately: false,
            onSignificantLocationWake: { counter.increment() }
        )

        XCTAssertTrue(monitor.isDelegateActiveForTest)
        let initiallyActive = await monitor.isActive()
        XCTAssertFalse(initiallyActive)

        await monitor.start()
        monitor.simulateSignificantLocationForTest()

        let activeAfterStart = await monitor.isActive()
        XCTAssertTrue(activeAfterStart)
        XCTAssertEqual(counter.count, 1)
        await monitor.stop()
    }

    func test_inactiveMonitorDoesNotWakeBusinessFlow() {
        let counter = WakeCounter()
        let monitor = CLLocationManagerSignificantChangeMonitor(
            activityLogger: NoopActivityLogger(),
            startsImmediately: false,
            onSignificantLocationWake: { counter.increment() }
        )

        monitor.simulateSignificantLocationForTest()
        XCTAssertEqual(counter.count, 0)
    }
}
