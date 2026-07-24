import XCTest
@testable import Checking

@MainActor
final class CLLocationManagerGeofenceMonitorTests: XCTestCase {
    func test_delegateIsActiveImmediatelyAfterInitialization() {
        let monitor = CLLocationManagerGeofenceMonitor(
            activityLogger: NoopActivityLogger(),
            onGeofenceWake: {}
        )

        XCTAssertTrue(monitor.isDelegateActiveForTest)
    }
}
