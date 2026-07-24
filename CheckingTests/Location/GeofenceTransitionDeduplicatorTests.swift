import XCTest
@testable import Checking

final class GeofenceTransitionDeduplicatorTests: XCTestCase {
    func test_sameRegionAndDirectionInsideWindowIsSuppressed() {
        var deduplicator = GeofenceTransitionDeduplicator()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(deduplicator.shouldHandle(identifier: "2", entered: true, at: start))
        XCTAssertFalse(deduplicator.shouldHandle(identifier: "2", entered: true, at: start.addingTimeInterval(0.1)))
    }

    func test_oppositeDirectionAndDifferentRegionAreNeverCollapsed() {
        var deduplicator = GeofenceTransitionDeduplicator()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(deduplicator.shouldHandle(identifier: "2", entered: true, at: start))
        XCTAssertTrue(deduplicator.shouldHandle(identifier: "2", entered: false, at: start.addingTimeInterval(0.1)))
        XCTAssertTrue(deduplicator.shouldHandle(identifier: "1", entered: true, at: start.addingTimeInterval(0.1)))
    }

    func test_sameTransitionAfterWindowIsAcceptedAgain() {
        var deduplicator = GeofenceTransitionDeduplicator()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(deduplicator.shouldHandle(identifier: "2", entered: true, at: start))
        XCTAssertTrue(deduplicator.shouldHandle(
            identifier: "2",
            entered: true,
            at: start.addingTimeInterval(GeofenceTransitionDeduplicator.defaultWindow)
        ))
    }
}
