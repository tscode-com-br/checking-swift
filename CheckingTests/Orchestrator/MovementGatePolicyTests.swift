import XCTest
@testable import Checking

final class MovementGatePolicyTests: XCTestCase {
    private let sut = MovementGatePolicy.production

    func test_minimumThresholdUsesStrictlyLessThanComparison() {
        XCTAssertEqual(
            sut.thresholdMeters(horizontalAccuracyMeters: 5),
            50
        )
        XCTAssertTrue(
            sut.shouldSkip(
                distanceMeters: 49.999,
                horizontalAccuracyMeters: 5
            )
        )
        XCTAssertFalse(
            sut.shouldSkip(
                distanceMeters: 50,
                horizontalAccuracyMeters: 5
            )
        )
        XCTAssertFalse(
            sut.shouldSkip(
                distanceMeters: 50.001,
                horizontalAccuracyMeters: 5
            )
        )
    }

    func test_accuracyDerivedThresholdUsesStrictlyLessThanComparison() {
        XCTAssertEqual(
            sut.thresholdMeters(horizontalAccuracyMeters: 30),
            60
        )
        XCTAssertTrue(
            sut.shouldSkip(
                distanceMeters: 59.999,
                horizontalAccuracyMeters: 30
            )
        )
        XCTAssertFalse(
            sut.shouldSkip(
                distanceMeters: 60,
                horizontalAccuracyMeters: 30
            )
        )
        XCTAssertFalse(
            sut.shouldSkip(
                distanceMeters: 60.001,
                horizontalAccuracyMeters: 30
            )
        )
    }

    func test_invalidInputsFailOpenAndNeverClaimNoMovement() {
        let invalidValues: [Double] = [
            -.infinity,
            -1,
            .nan,
            .infinity,
        ]

        for value in invalidValues {
            XCTAssertFalse(
                sut.shouldSkip(
                    distanceMeters: value,
                    horizontalAccuracyMeters: 5
                )
            )
            XCTAssertFalse(
                sut.shouldSkip(
                    distanceMeters: 0,
                    horizontalAccuracyMeters: value
                )
            )
        }
    }
}
