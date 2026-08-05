import Foundation
import XCTest
@testable import Checking

final class LocationSamplePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)
    private let requiredAccuracyMeters = 25

    private var policy: LocationSamplePolicy {
        .candidateTrial
    }

    private func sample(
        age: TimeInterval = 0,
        latitude: Double = -23,
        longitude: Double = -46,
        accuracy: Double = 5,
        source: LocationSampleSource = .standardCapture
    ) -> LocationSample {
        LocationSample(
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracyMeters: accuracy,
            capturedAt: now.addingTimeInterval(-age),
            source: source
        )
    }

    private func validity(
        of sample: LocationSample,
        policy: LocationSamplePolicy? = nil,
        now: Date? = nil,
        requiredAccuracyMeters: Int? = nil
    ) -> LocationSampleValidity {
        (policy ?? self.policy).validity(
            of: sample,
            now: now ?? self.now,
            requiredAccuracyMeters: requiredAccuracyMeters ?? self.requiredAccuracyMeters
        )
    }

    func test_candidateTrialUsesApprovedFreshnessParameters() {
        XCTAssertEqual(policy.maximumAge, 10)
        XCTAssertEqual(policy.futureTolerance, 2)
    }

    func test_currentAndZeroAgeSamplesAreUsable() {
        XCTAssertEqual(validity(of: sample(age: 2)), .usable)
        XCTAssertEqual(validity(of: sample(age: 0)), .usable)
    }

    func test_exactMaximumAgeIsUsable() {
        XCTAssertEqual(validity(of: sample(age: 10)), .usable)
    }

    func test_oneMillisecondBeyondMaximumAgeIsStale() {
        XCTAssertEqual(validity(of: sample(age: 10.001)), .stale)
    }

    func test_exactFutureToleranceIsUsable() {
        XCTAssertEqual(validity(of: sample(age: -2)), .usable)
    }

    func test_oneMillisecondBeyondFutureToleranceIsFromFuture() {
        XCTAssertEqual(validity(of: sample(age: -2.001)), .fromFuture)
    }

    func test_accuracyThresholdIsInclusiveAndFreshCoarseSampleIsClassifiedSeparately() {
        XCTAssertEqual(validity(of: sample(accuracy: 25)), .usable)
        XCTAssertEqual(validity(of: sample(accuracy: 25.001)), .freshButTooInaccurate)
        XCTAssertEqual(validity(of: sample(accuracy: 500)), .freshButTooInaccurate)
    }

    func test_negativeNanAndInfiniteAccuracyAreInvalid() {
        for accuracy in [-1.0, .nan, .infinity, -.infinity] {
            XCTAssertEqual(validity(of: sample(accuracy: accuracy)), .invalid)
        }
    }

    func test_coordinateBoundariesAreInclusive() {
        XCTAssertEqual(validity(of: sample(latitude: -90, longitude: -180)), .usable)
        XCTAssertEqual(validity(of: sample(latitude: 90, longitude: 180)), .usable)
    }

    func test_nonFiniteAndOutOfRangeCoordinatesAreInvalid() {
        let invalidCoordinates: [(Double, Double)] = [
            (.nan, 0),
            (.infinity, 0),
            (-.infinity, 0),
            (0, .nan),
            (0, .infinity),
            (0, -.infinity),
            (90.0.nextUp, 0),
            ((-90.0).nextDown, 0),
            (0, 180.0.nextUp),
            (0, (-180.0).nextDown)
        ]

        for (latitude, longitude) in invalidCoordinates {
            XCTAssertEqual(
                validity(of: sample(latitude: latitude, longitude: longitude)),
                .invalid
            )
        }
    }

    func test_sourceIsPreservedWithoutAffectingValidity() {
        let standard = sample(source: .standardCapture)
        let significant = sample(source: .significantChange)

        XCTAssertEqual(standard.source, .standardCapture)
        XCTAssertEqual(significant.source, .significantChange)
        XCTAssertEqual(validity(of: standard), .usable)
        XCTAssertEqual(validity(of: significant), .usable)
    }

    func test_invalidPolicyClockAndRequestedAccuracyFailClosed() {
        XCTAssertEqual(
            validity(
                of: sample(),
                policy: LocationSamplePolicy(maximumAge: .nan, futureTolerance: 2)
            ),
            .invalid
        )
        XCTAssertEqual(
            validity(
                of: sample(),
                policy: LocationSamplePolicy(maximumAge: 10, futureTolerance: -.infinity)
            ),
            .invalid
        )
        XCTAssertEqual(
            validity(
                of: sample(),
                now: Date(timeIntervalSinceReferenceDate: .nan)
            ),
            .invalid
        )
        XCTAssertEqual(
            validity(
                of: LocationSample(
                    latitude: 0,
                    longitude: 0,
                    horizontalAccuracyMeters: 0,
                    capturedAt: Date(timeIntervalSinceReferenceDate: .infinity),
                    source: .standardCapture
                )
            ),
            .invalid
        )
        XCTAssertEqual(validity(of: sample(), requiredAccuracyMeters: -1), .invalid)
        XCTAssertEqual(validity(of: sample(accuracy: 0), requiredAccuracyMeters: 0), .usable)
    }

    func test_preciseTwoSecondSampleBeatsNewerCoarseSampleInEitherArgumentOrder() {
        let precise = sample(age: 2, accuracy: 5)
        let coarse = sample(age: 1, accuracy: 500)

        XCTAssertEqual(
            policy.preferredSeed(
                current: precise,
                candidate: coarse,
                now: now,
                requiredAccuracyMeters: requiredAccuracyMeters
            ),
            precise
        )
        XCTAssertEqual(
            policy.preferredSeed(
                current: coarse,
                candidate: precise,
                now: now,
                requiredAccuracyMeters: requiredAccuracyMeters
            ),
            precise
        )
    }

    func test_accuracyPrecedesTimestampWithinTheSameQualityClass() {
        let moreAccurate = sample(age: 3, accuracy: 7)
        let newer = sample(age: 1, accuracy: 8)

        XCTAssertEqual(
            policy.preferredSeed(
                current: newer,
                candidate: moreAccurate,
                now: now,
                requiredAccuracyMeters: requiredAccuracyMeters
            ),
            moreAccurate
        )
    }

    func test_newerTimestampBreaksAnAccuracyTie() {
        let older = sample(age: 3, accuracy: 7)
        let newer = sample(age: 1, accuracy: 7)

        XCTAssertEqual(
            policy.preferredSeed(
                current: older,
                candidate: newer,
                now: now,
                requiredAccuracyMeters: requiredAccuracyMeters
            ),
            newer
        )
    }

    func test_coarseSeedsAlsoUseAccuracyBeforeTimestamp() {
        let olderButMoreAccurate = sample(age: 3, accuracy: 500)
        let newerButLessAccurate = sample(age: 1, accuracy: 600)
        let exactFutureToleranceWithTiedAccuracy = sample(age: -2, accuracy: 500)

        XCTAssertEqual(
            policy.preferredSeed(
                current: newerButLessAccurate,
                candidate: olderButMoreAccurate,
                now: now,
                requiredAccuracyMeters: requiredAccuracyMeters
            ),
            olderButMoreAccurate
        )
        XCTAssertEqual(
            policy.preferredSeed(
                current: olderButMoreAccurate,
                candidate: exactFutureToleranceWithTiedAccuracy,
                now: now,
                requiredAccuracyMeters: requiredAccuracyMeters
            ),
            exactFutureToleranceWithTiedAccuracy
        )
    }

    func test_ineligibleSeedsAreDiscardedBeforeComparison() {
        let usable = sample(age: 1)
        let stale = sample(age: 10.001)
        let future = sample(age: -2.001)
        let invalid = sample(latitude: .nan)

        XCTAssertEqual(
            policy.preferredSeed(
                current: stale,
                candidate: usable,
                now: now,
                requiredAccuracyMeters: requiredAccuracyMeters
            ),
            usable
        )
        XCTAssertEqual(
            policy.preferredSeed(
                current: usable,
                candidate: future,
                now: now,
                requiredAccuracyMeters: requiredAccuracyMeters
            ),
            usable
        )
        XCTAssertNil(
            policy.preferredSeed(
                current: invalid,
                candidate: stale,
                now: now,
                requiredAccuracyMeters: requiredAccuracyMeters
            )
        )
        XCTAssertNil(
            policy.preferredSeed(
                current: nil,
                candidate: future,
                now: now,
                requiredAccuracyMeters: requiredAccuracyMeters
            )
        )
    }

    func test_completeTiePreservesCurrentAndDoesNotCompareCoordinatesOrSource() {
        let current = sample(
            latitude: 1,
            longitude: 2,
            accuracy: 7,
            source: .standardCapture
        )
        let candidate = sample(
            latitude: 3,
            longitude: 4,
            accuracy: 7,
            source: .significantChange
        )

        XCTAssertEqual(
            policy.preferredSeed(
                current: current,
                candidate: candidate,
                now: now,
                requiredAccuracyMeters: requiredAccuracyMeters
            ),
            current
        )
    }

    func test_sameSampleIsRevalidatedAgainstTheCurrentEvaluationTime() {
        let fixedSample = sample(age: 0)

        XCTAssertEqual(
            policy.validity(
                of: fixedSample,
                now: now.addingTimeInterval(10),
                requiredAccuracyMeters: requiredAccuracyMeters
            ),
            .usable
        )
        XCTAssertEqual(
            policy.validity(
                of: fixedSample,
                now: now.addingTimeInterval(10.001),
                requiredAccuracyMeters: requiredAccuracyMeters
            ),
            .stale
        )
    }

    func test_locationSampleHasNoPersistenceOrDescriptionConformance() {
        XCTAssertFalse(LocationSample.self is any Encodable.Type)
        XCTAssertFalse(LocationSample.self is any Decodable.Type)
        XCTAssertFalse(LocationSample.self is any CustomStringConvertible.Type)
    }
}
