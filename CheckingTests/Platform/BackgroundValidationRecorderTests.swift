#if DEBUG
import XCTest
@testable import Checking

final class BackgroundValidationRecorderTests: XCTestCase {
    func test_newRecorderContinuesPersistedReportAndSequence() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-validation-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let firstProcess = BackgroundValidationRecorder(fileURL: fileURL)
        await firstProcess.reset()
        await firstProcess.record("before_relaunch")

        let relaunchedProcess = BackgroundValidationRecorder(fileURL: fileURL)
        await relaunchedProcess.record("after_relaunch")
        let report = await relaunchedProcess.snapshot()

        XCTAssertEqual(report.events.map(\.kind), ["before_relaunch", "after_relaunch"])
        XCTAssertEqual(report.events.map(\.sequence), [1, 2])
    }

    func test_corruptPersistedReportStartsFresh() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-validation-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data("not-json".utf8).write(to: fileURL)

        let recorder = BackgroundValidationRecorder(fileURL: fileURL)
        await recorder.record("recovered")
        let report = await recorder.snapshot()

        XCTAssertEqual(report.events.map(\.kind), ["recovered"])
        XCTAssertEqual(report.events.first?.sequence, 1)
    }

    func test_reportDropsRegionCoordinatesLocalAndRawErrorButKeepsClosedErrorCode() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-validation-private-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recorder = BackgroundValidationRecorder(fileURL: fileURL)
        let regionSentinel = "REGION_PRIVATE_P80"
        let localSentinel = "LOCAL_PRIVATE_UNIT"
        let errorSentinel = "ERROR_PRIVATE_TOKEN"

        await recorder.reset()
        await recorder.record("geofence", details: [
            "region": regionSentinel,
            "identifier": regionSentinel,
            "latitude": "-23.500000",
            "longitude": "-46.600000",
            "local": localSentinel,
            "error": errorSentinel,
            "errorCode": GeofenceMonitoringFailureCode.regionMonitoringDenied.rawValue,
            "rawErrorCode": errorSentinel,
            "failureCodes": "\(GeofenceMonitoringFailureCode.denied.rawValue):2",
            "active": "true"
        ])

        let report = await recorder.snapshot()
        let details = try XCTUnwrap(report.events.first?.details)
        XCTAssertEqual(details, [
            "errorCode": GeofenceMonitoringFailureCode.regionMonitoringDenied.rawValue,
            "failureCodes": "\(GeofenceMonitoringFailureCode.denied.rawValue):2",
            "active": "true"
        ])

        let serialized = try String(contentsOf: fileURL, encoding: .utf8)
        for forbidden in [regionSentinel, localSentinel, errorSentinel, "-23.500000", "-46.600000"] {
            XCTAssertFalse(serialized.contains(forbidden))
        }
    }

    func test_reportDropsRawErrorEvenWhenCallSiteMislabelsItAsErrorCode() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-validation-raw-code-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recorder = BackgroundValidationRecorder(fileURL: fileURL)
        let rawErrorSentinel = "ERROR_PRIVATE_MISLABELED"

        await recorder.reset()
        await recorder.record("geofence", details: [
            "errorCode": rawErrorSentinel,
            "failureCodes": "\(rawErrorSentinel):1",
            "active": "true"
        ])

        let report = await recorder.snapshot()
        let details = try XCTUnwrap(report.events.first?.details)
        XCTAssertEqual(details, ["active": "true"])
        XCTAssertFalse(try String(contentsOf: fileURL, encoding: .utf8).contains(rawErrorSentinel))
    }

    func test_reportRejectsSensitiveValuesEvenUnderOtherwiseAllowedKeys() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-validation-allowed-key-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recorder = BackgroundValidationRecorder(fileURL: fileURL)
        let sentinel = "REGION_PRIVATE_MISLABELED"

        await recorder.reset()
        await recorder.record("geofence", details: [
            "state": sentinel,
            "authorization": sentinel,
            "requested": "-23.500000",
            "active": "true"
        ])

        let report = await recorder.snapshot()
        XCTAssertEqual(report.events.first?.details, ["active": "true"])
        XCTAssertFalse(try String(contentsOf: fileURL, encoding: .utf8).contains(sentinel))
        XCTAssertFalse(try String(contentsOf: fileURL, encoding: .utf8).contains("-23.500000"))
    }

    func test_relaunchSanitizesPersistedReportFromOlderSchema() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-validation-migration-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let regionSentinel = "REGION_PRIVATE_LEGACY"
        let errorSentinel = "ERROR_PRIVATE_LEGACY"
        let legacy = BackgroundValidationReport(
            schemaVersion: 1,
            startedAt: Date(timeIntervalSince1970: 1),
            events: [
                BackgroundValidationEvent(
                    sequence: 1,
                    timestamp: Date(timeIntervalSince1970: 2),
                    kind: "legacy-\(regionSentinel)",
                    details: [
                        "region": regionSentinel,
                        "latitude": "-23.500000",
                        "errorCode": errorSentinel,
                        "active": "true"
                    ]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: fileURL)

        let relaunchedRecorder = BackgroundValidationRecorder(
            fileURL: fileURL,
            clock: FixedClock(Date(timeIntervalSince1970: 3))
        )
        let report = await relaunchedRecorder.snapshot()

        XCTAssertEqual(report.schemaVersion, 2)
        XCTAssertEqual(report.events.first?.kind, "sanitized")
        XCTAssertEqual(report.events.first?.details, ["active": "true"])
        let serialized = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(serialized.contains(regionSentinel))
        XCTAssertFalse(serialized.contains(errorSentinel))
        XCTAssertFalse(serialized.contains("-23.500000"))
    }

    func test_reportAppliesRetentionAndEventCapBeforePersistingSnapshot() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-validation-retention-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let persisted = BackgroundValidationReport(
            schemaVersion: 2,
            startedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            events: [
                BackgroundValidationEvent(
                    sequence: 1,
                    timestamp: now.addingTimeInterval(-31 * 24 * 60 * 60),
                    kind: "before_relaunch",
                    details: ["active": "true"]
                ),
                BackgroundValidationEvent(
                    sequence: 2,
                    timestamp: now.addingTimeInterval(-60),
                    kind: "after_relaunch",
                    details: ["active": "true"]
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(persisted).write(to: fileURL)

        let recorder = BackgroundValidationRecorder(
            fileURL: fileURL,
            clock: FixedClock(now),
            maximumEvents: 2
        )
        let restored = await recorder.snapshot()
        XCTAssertEqual(restored.events.map(\.kind), ["after_relaunch"])

        await recorder.record("recovered")
        await recorder.record("geofence")
        let report = await recorder.snapshot()
        XCTAssertEqual(report.events.map(\.kind), ["recovered", "geofence"])
        XCTAssertEqual(report.events.map(\.sequence), [1, 2])
    }

    func test_clearRemovesReportIdempotentlyAndFencesLateDebugRecords() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-validation-clear-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recorder = BackgroundValidationRecorder(fileURL: fileURL)

        await recorder.reset()
        await recorder.record("before_relaunch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        await recorder.clear()
        await recorder.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let cleared = await recorder.snapshot()
        XCTAssertTrue(cleared.events.isEmpty)

        await recorder.record("after_relaunch")
        let fenced = await recorder.snapshot()
        XCTAssertTrue(fenced.events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        await recorder.reset()
        await recorder.record("after_relaunch")
        let restarted = await recorder.snapshot()
        XCTAssertEqual(restarted.events.map(\.kind), ["after_relaunch"])
    }
}
#endif
