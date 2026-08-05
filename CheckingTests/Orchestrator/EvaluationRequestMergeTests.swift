import XCTest
@testable import Checking

final class EvaluationRequestMergeTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func test_timerWithTimerRemainsExclusiveTimerAndKeepsCanonicalIdentity() throws {
        let current = request(
            id: 1,
            trigger: .timer,
            receivedAt: now.addingTimeInterval(-2),
            appState: .background
        )
        let new = request(
            id: 2,
            trigger: .timer,
            receivedAt: now.addingTimeInterval(-1),
            appState: .active
        )

        let merged = try XCTUnwrap(merge(current, new))

        XCTAssertEqual(merged.id, current.id)
        XCTAssertEqual(merged.trigger, .timer)
        XCTAssertEqual(merged.sourceMask, .timer)
        XCTAssertTrue(merged.isExclusivelyTimer)
        XCTAssertEqual(merged.wakeCounts.count(for: .timer), 2)
        XCTAssertEqual(merged.coalescedWakeCount, 2)
        XCTAssertEqual(merged.receivedAt, new.receivedAt)
        XCTAssertEqual(merged.appStateAtReceipt, .active)
    }

    func test_timerAndEventPromoteToEventInBothOrders() throws {
        let events: [(
            trigger: OrchestratorTrigger,
            source: EvaluationWakeSourceMask,
            wake: EvaluationWakeKind
        )] = [
            (.geofence, .geofence, .geofence),
            (.significantLocation, .significantLocation, .significantLocation),
        ]

        for (index, event) in events.enumerated() {
            let timer = request(
                id: 10 + index * 10,
                trigger: .timer,
                receivedAt: now.addingTimeInterval(-2)
            )
            let eventRequest = request(
                id: 11 + index * 10,
                trigger: event.trigger,
                receivedAt: now.addingTimeInterval(-1)
            )

            let timerThenEvent = try XCTUnwrap(merge(timer, eventRequest))
            XCTAssertEqual(timerThenEvent.id, timer.id)
            XCTAssertEqual(timerThenEvent.trigger, event.trigger)
            XCTAssertEqual(
                timerThenEvent.sourceMask,
                [.timer, event.source]
            )
            XCTAssertFalse(timerThenEvent.isExclusivelyTimer)
            XCTAssertEqual(timerThenEvent.wakeCounts.count(for: .timer), 1)
            XCTAssertEqual(
                timerThenEvent.wakeCounts.count(for: event.wake),
                1
            )

            let eventThenTimer = try XCTUnwrap(merge(eventRequest, timer))
            XCTAssertEqual(eventThenTimer.id, eventRequest.id)
            XCTAssertEqual(eventThenTimer.trigger, event.trigger)
            XCTAssertEqual(
                eventThenTimer.sourceMask,
                [.timer, event.source]
            )
            XCTAssertFalse(eventThenTimer.isExclusivelyTimer)
            XCTAssertEqual(eventThenTimer.wakeCounts.count(for: .timer), 1)
            XCTAssertEqual(
                eventThenTimer.wakeCounts.count(for: event.wake),
                1
            )
        }
    }

    func test_geofenceAndSignificantPreferSignificantInBothOrdersAndPreserveSeed() throws {
        let significantSeed = sample(
            accuracy: 8,
            capturedAt: now.addingTimeInterval(-1)
        )
        let geofence = request(
            id: 30,
            trigger: .geofence,
            receivedAt: now.addingTimeInterval(-2)
        )
        let significant = request(
            id: 31,
            trigger: .significantLocation,
            receivedAt: now.addingTimeInterval(-1),
            sample: significantSeed
        )

        let geofenceThenSignificant = try XCTUnwrap(merge(geofence, significant))
        XCTAssertEqual(geofenceThenSignificant.id, geofence.id)
        XCTAssertEqual(geofenceThenSignificant.trigger, .significantLocation)
        XCTAssertEqual(geofenceThenSignificant.sample, significantSeed)
        XCTAssertEqual(
            geofenceThenSignificant.sourceMask,
            [.geofence, .significantLocation]
        )

        let significantThenGeofence = try XCTUnwrap(merge(significant, geofence))
        XCTAssertEqual(significantThenGeofence.id, significant.id)
        XCTAssertEqual(significantThenGeofence.trigger, .significantLocation)
        XCTAssertEqual(significantThenGeofence.sample, significantSeed)
        XCTAssertEqual(
            significantThenGeofence.sourceMask,
            [.geofence, .significantLocation]
        )
    }

    func test_preciseOlderSeedBeatsCoarseNewerSeedInBothOrders() throws {
        let precise = sample(
            accuracy: 5,
            capturedAt: now.addingTimeInterval(-2)
        )
        let coarse = sample(
            accuracy: 500,
            capturedAt: now.addingTimeInterval(-1)
        )
        let preciseRequest = request(
            id: 40,
            trigger: .significantLocation,
            receivedAt: now.addingTimeInterval(-2),
            sample: precise
        )
        let coarseRequest = request(
            id: 41,
            trigger: .significantLocation,
            receivedAt: now.addingTimeInterval(-1),
            sample: coarse
        )

        let preciseThenCoarse = try XCTUnwrap(
            merge(preciseRequest, coarseRequest, requiredAccuracyMeters: 50)
        )
        let coarseThenPrecise = try XCTUnwrap(
            merge(coarseRequest, preciseRequest, requiredAccuracyMeters: 50)
        )

        XCTAssertEqual(preciseThenCoarse.sample, precise)
        XCTAssertEqual(coarseThenPrecise.sample, precise)
    }

    func test_staleFutureAndInvalidSeedsCannotReplaceFreshValidSeed() throws {
        let valid = sample(
            accuracy: 9,
            capturedAt: now.addingTimeInterval(-1)
        )
        let rejected: [LocationSample] = [
            sample(
                accuracy: 1,
                capturedAt: now.addingTimeInterval(
                    -LocationSamplePolicy.candidateTrial.maximumAge - 0.001
                )
            ),
            sample(
                accuracy: 1,
                capturedAt: now.addingTimeInterval(
                    LocationSamplePolicy.candidateTrial.futureTolerance + 0.001
                )
            ),
            sample(
                latitude: .nan,
                accuracy: 1,
                capturedAt: now
            ),
        ]

        for (index, rejectedSeed) in rejected.enumerated() {
            let validRequest = request(
                id: 50 + index * 10,
                trigger: .significantLocation,
                receivedAt: now.addingTimeInterval(-2),
                sample: valid
            )
            let rejectedRequest = request(
                id: 51 + index * 10,
                trigger: .significantLocation,
                receivedAt: now.addingTimeInterval(-1),
                sample: rejectedSeed
            )

            XCTAssertEqual(
                try XCTUnwrap(merge(validRequest, rejectedRequest)).sample,
                valid
            )
            XCTAssertEqual(
                try XCTUnwrap(merge(rejectedRequest, validRequest)).sample,
                valid
            )
        }
    }

    func test_onlyRejectedSeedsProduceNoReusableSample() throws {
        let stale = sample(
            accuracy: 1,
            capturedAt: now.addingTimeInterval(
                -LocationSamplePolicy.candidateTrial.maximumAge - 0.001
            )
        )
        let future = sample(
            accuracy: 1,
            capturedAt: now.addingTimeInterval(
                LocationSamplePolicy.candidateTrial.futureTolerance + 0.001
            )
        )

        let merged = try XCTUnwrap(
            merge(
                request(
                    id: 80,
                    trigger: .significantLocation,
                    receivedAt: now.addingTimeInterval(-2),
                    sample: stale
                ),
                request(
                    id: 81,
                    trigger: .significantLocation,
                    receivedAt: now.addingTimeInterval(-1),
                    sample: future
                )
            )
        )

        XCTAssertNil(merged.sample)
    }

    func test_receivedAtAndAppStateComeFromLatestWakeWithoutChangingCanonicalID() throws {
        let earlier = request(
            id: 90,
            trigger: .timer,
            receivedAt: now.addingTimeInterval(-3),
            appState: .background
        )
        let later = request(
            id: 91,
            trigger: .geofence,
            receivedAt: now.addingTimeInterval(-1),
            appState: .inactive
        )

        let earlierThenLater = try XCTUnwrap(merge(earlier, later))
        XCTAssertEqual(earlierThenLater.id, earlier.id)
        XCTAssertEqual(earlierThenLater.receivedAt, later.receivedAt)
        XCTAssertEqual(earlierThenLater.appStateAtReceipt, .inactive)

        let laterThenEarlier = try XCTUnwrap(merge(later, earlier))
        XCTAssertEqual(laterThenEarlier.id, later.id)
        XCTAssertEqual(laterThenEarlier.receivedAt, later.receivedAt)
        XCTAssertEqual(laterThenEarlier.appStateAtReceipt, .inactive)
    }

    func test_wakeCountsAndTotalSaturateWithoutGrowingStorage() throws {
        var timerCounts = EvaluationRequestWakeCounts(trigger: .timer)
        timerCounts.increment(.timer, by: .max)
        var geofenceCounts = EvaluationRequestWakeCounts(trigger: .geofence)
        geofenceCounts.increment(.geofence, by: .max)

        let current = request(
            id: 100,
            trigger: .timer,
            receivedAt: now.addingTimeInterval(-2),
            wakeCounts: timerCounts
        )
        let new = request(
            id: 101,
            trigger: .geofence,
            receivedAt: now.addingTimeInterval(-1),
            wakeCounts: geofenceCounts
        )

        let merged = try XCTUnwrap(merge(current, new))

        XCTAssertEqual(merged.wakeCounts.count(for: .timer), .max)
        XCTAssertEqual(merged.wakeCounts.count(for: .geofence), .max)
        XCTAssertEqual(merged.wakeCounts.total, .max)
        XCTAssertEqual(
            merged.coalescedWakeCount,
            EvaluationRequest.maximumCoalescedWakeCount
        )
    }

    func test_foregroundIsRejectedFromNormalMergeInBothPositions() {
        let normal = request(
            id: 110,
            trigger: .geofence,
            receivedAt: now.addingTimeInterval(-2)
        )
        let foreground = request(
            id: 111,
            trigger: .foreground,
            receivedAt: now.addingTimeInterval(-1)
        )

        XCTAssertNil(merge(normal, foreground))
        XCTAssertNil(merge(foreground, normal))
        XCTAssertNil(merge(foreground, foreground))
    }

    func test_sourceMaskContainsOnlyWakeKindsAndNoRegionMetadata() throws {
        let merged = try XCTUnwrap(
            merge(
                request(
                    id: 120,
                    trigger: .geofence,
                    receivedAt: now.addingTimeInterval(-2)
                ),
                request(
                    id: 121,
                    trigger: .significantLocation,
                    receivedAt: now.addingTimeInterval(-1)
                )
            )
        )
        let allDefinedSources: EvaluationWakeSourceMask = [
            .timer,
            .geofence,
            .significantLocation,
            .foreground,
            .accuracyRetry,
            .pauseActivation,
            .pauseTransition,
        ]
        let requestLabels = Mirror(reflecting: merged).children.compactMap(\.label)
        let sourceLabels = Mirror(reflecting: merged.sourceMask).children.compactMap(\.label)

        XCTAssertEqual(
            merged.sourceMask,
            [.geofence, .significantLocation]
        )
        XCTAssertEqual(
            merged.sourceMask.rawValue & ~allDefinedSources.rawValue,
            0
        )
        XCTAssertEqual(sourceLabels, ["rawValue"])
        XCTAssertFalse(
            requestLabels.contains {
                $0.localizedCaseInsensitiveContains("region")
            }
        )
        XCTAssertFalse(
            sourceLabels.contains {
                $0.localizedCaseInsensitiveContains("region")
            }
        )
    }

    private func merge(
        _ current: EvaluationRequest,
        _ new: EvaluationRequest,
        requiredAccuracyMeters: Int = 50
    ) -> EvaluationRequest? {
        PendingWakeMerge.mergePendingWake(
            current: current,
            new: new,
            now: now,
            requiredAccuracyMeters: requiredAccuracyMeters
        )
    }

    private func request(
        id: Int,
        trigger: OrchestratorTrigger,
        receivedAt: Date,
        sample: LocationSample? = nil,
        appState: EvaluationApplicationState = .unknown,
        wakeCounts: EvaluationRequestWakeCounts? = nil
    ) -> EvaluationRequest {
        EvaluationRequest(
            id: evaluationID(id),
            trigger: trigger,
            receivedAt: receivedAt,
            sample: sample,
            appStateAtReceipt: appState,
            wakeCounts: wakeCounts
        )
    }

    private func sample(
        latitude: Double = 1,
        longitude: Double = 1,
        accuracy: Double,
        capturedAt: Date
    ) -> LocationSample {
        LocationSample(
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracyMeters: accuracy,
            capturedAt: capturedAt,
            source: .significantChange
        )
    }

    private func evaluationID(_ value: Int) -> EvaluationID {
        let suffix = String(format: "%012d", value)
        return EvaluationID(
            UUID(uuidString: "20000000-0000-0000-0000-\(suffix)")!
        )
    }
}
