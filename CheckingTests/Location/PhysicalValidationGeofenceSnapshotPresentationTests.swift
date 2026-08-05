import XCTest
@testable import Checking

final class PhysicalValidationGeofenceSnapshotPresentationTests: XCTestCase {
    func test_rendersOnlyTheAllowedGenerationCountsAndClosedFailureCodes() {
        let presentation = PhysicalValidationGeofenceSnapshotPresentation(
            snapshot: GeofenceMonitoringSnapshot(
                syncGeneration: 12,
                requestedCount: 9,
                confirmedCount: 7,
                failedCount: 2,
                failedCodes: [.denied: 1, .other: 1],
                omittedCount: 3,
                pendingCount: 0,
                confirmationState: .partiallyConfirmed,
                inheritedUnknownCount: 0
            )
        )

        XCTAssertEqual(presentation.generationOrdinalText, "12")
        XCTAssertEqual(presentation.confirmationStateText, "partiallyConfirmed")
        XCTAssertFalse(presentation.confirmationUncertain)
        XCTAssertEqual(
            presentation.counts,
            [
                .init(name: "requested", value: 9),
                .init(name: "confirmed", value: 7),
                .init(name: "failed", value: 2),
                .init(name: "omitted", value: 3),
                .init(name: "pending", value: 0),
                .init(name: "inheritedUnknown", value: 0),
            ]
        )
        XCTAssertEqual(presentation.failureCodes, ["denied: 1", "other: 1"])
    }

    func test_uncertainInheritedSnapshotStaysExplicitAndContainsNoCorrelationFields() {
        let presentation = PhysicalValidationGeofenceSnapshotPresentation(
            snapshot: GeofenceMonitoringSnapshot(
                syncGeneration: 0,
                requestedCount: 0,
                confirmedCount: 0,
                failedCount: 0,
                failedCodes: [:],
                omittedCount: 0,
                pendingCount: 0,
                confirmationState: .confirmationUncertain,
                inheritedUnknownCount: 4
            )
        )

        XCTAssertEqual(presentation.confirmationStateText, "confirmationUncertain")
        XCTAssertTrue(presentation.confirmationUncertain)
        XCTAssertEqual(presentation.counts.last, .init(name: "inheritedUnknown", value: 4))

        let visibleValues = [
            presentation.generationOrdinalText,
            presentation.confirmationStateText,
            presentation.failureCodes.joined(separator: " "),
            presentation.counts.map(\.name).joined(separator: " "),
        ].joined(separator: " ")
        for forbiddenName in ["identifier", "token", "local", "latitude", "longitude", "coordinate", "error"] {
            XCTAssertFalse(visibleValues.contains(forbiddenName))
        }
    }

    func test_unavailableSnapshotShowsNoPriorGenerationOrFailureData() {
        let presentation = PhysicalValidationGeofenceSnapshotPresentation(snapshot: nil)

        XCTAssertEqual(presentation.generationOrdinalText, "indisponível")
        XCTAssertEqual(presentation.confirmationStateText, "notRequested")
        XCTAssertFalse(presentation.confirmationUncertain)
        XCTAssertEqual(presentation.counts.map(\.value), [0, 0, 0, 0, 0, 0])
        XCTAssertTrue(presentation.failureCodes.isEmpty)
    }
}
