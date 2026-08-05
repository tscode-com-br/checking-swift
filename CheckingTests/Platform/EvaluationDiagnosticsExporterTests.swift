#if DEBUG
import Foundation
import XCTest
@testable import Checking

final class EvaluationDiagnosticsExporterTests: XCTestCase {
    func test_explicitExportIsBoundedSanitizedAndCleanedUp() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = FixedClock(now)
        let journalURL = root.appendingPathComponent("evaluation-journal.json")
        let firstID = EvaluationID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let secondID = EvaluationID(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let thirdID = EvaluationID(UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
        let journal = DurableEvaluationJournal(
            fileURL: journalURL,
            clock: clock,
            processID: EvaluationProcessID(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!),
            maxRecords: 2
        )
        for id in [firstID, secondID, thirdID] {
            await journal.begin(EvaluationStart(
                id: id,
                trigger: .geofence,
                primaryWake: .geofence,
                stage: .captured,
                appState: .background,
                launchState: .cold,
                permissionMode: .always,
                accuracyMode: .full,
                backgroundRefresh: .available,
                lowPowerMode: false,
                monitors: EvaluationMonitorFlags(
                    geofence: .active,
                    significantLocation: .active,
                    backgroundTask: .active
                ),
                locationSource: .freshCapture,
                captureReused: false,
                accuracyBucket: .elevenTo25Meters,
                ageBucket: .oneTo5Seconds
            ))
            await journal.finish(
                id: id,
                terminal: EvaluationTerminal(
                    outcome: .noAction,
                    durationBucket: .oneTo5Seconds,
                    locationSource: .freshCapture,
                    captureReused: false,
                    accuracyBucket: .elevenTo25Meters,
                    ageBucket: .oneTo5Seconds,
                    http: EvaluationHTTPDiagnostic(status: 204),
                    notificationScheduled: false
                )
            )
        }

        let recorder = BackgroundValidationRecorder(
            fileURL: root.appendingPathComponent("validation-report.json"),
            clock: clock,
            maximumEvents: 2
        )
        await recorder.reset()
        await recorder.record("before_relaunch", details: ["active": "true"])
        await recorder.record("after_relaunch", details: ["active": "true"])
        let sentinels = [
            "LAT_SENTINEL_1_352100", "LON_SENTINEL_103_819800", "KEY_SENTINEL_HR70",
            "PASSWORD_SENTINEL_W7", "COOKIE_SENTINEL_SESSION_93A", "TOKEN_SENTINEL_APNS_77",
            "BODY_SENTINEL_PRIVATE_31", "URL_SENTINEL_CHECK_27", "LOCATION_SENTINEL_UNIDADE_P80",
            "REGION_SENTINEL_P80_42",
        ]
        await recorder.record("geofence", details: [
            "latitude": sentinels[0],
            "longitude": sentinels[1],
            "chave": sentinels[2],
            "password": sentinels[3],
            "cookie": sentinels[4],
            "token": sentinels[5],
            "body": sentinels[6],
            "url": sentinels[7],
            "local": sentinels[8],
            "region": sentinels[9],
            "state": sentinels[5],
            "active": "true",
        ])

        let exportDirectory = root.appendingPathComponent(
            EvaluationDiagnosticsExporter.exportDirectoryName,
            isDirectory: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportDirectory.path))

        let exporter = EvaluationDiagnosticsExporter(
            journal: journal,
            recorder: recorder,
            clock: clock,
            temporaryDirectory: root
        )
        let createdExport = await exporter.createTemporaryExport()
        let exportURL = try XCTUnwrap(createdExport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
        XCTAssertEqual(exportURL.deletingLastPathComponent().standardizedFileURL, exportDirectory.standardizedFileURL)

        let data = try Data(contentsOf: exportURL)
        let rootJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(rootJSON.keys),
            ["schema_version", "exported_at", "evaluation_records", "validation_report"]
        )
        let records = try XCTUnwrap(rootJSON["evaluation_records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 2)
        for record in records {
            XCTAssertNil(record["evaluation_id"])
            XCTAssertNil(record["process_id"])
            XCTAssertNil(record["sequence"])
        }
        let validation = try XCTUnwrap(rootJSON["validation_report"] as? [String: Any])
        let events = try XCTUnwrap(validation["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)

        let forbiddenKeys: Set<String> = [
            "latitude", "longitude", "altitude", "speed", "course", "location", "project", "user",
            "chave", "password", "cookie", "token", "headers", "clienteventid", "requestbody",
            "responsebody", "url", "regionid", "rawerror", "evaluationid", "processid", "sequence",
        ]
        let normalizedKeys = collectKeys(rootJSON).map {
            $0.lowercased().replacingOccurrences(of: "_", with: "")
        }
        XCTAssertTrue(forbiddenKeys.isDisjoint(with: Set(normalizedKeys)))

        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        for sentinel in sentinels {
            XCTAssertFalse(serialized.contains(sentinel), "Exported forbidden sentinel: \(sentinel)")
        }
        for identifier in [firstID, secondID, thirdID] {
            XCTAssertFalse(serialized.contains(identifier.rawValue.uuidString))
        }

        let unrelatedFile = root.appendingPathComponent("keep-me.json")
        try Data("unrelated".utf8).write(to: unrelatedFile)
        EvaluationDiagnosticsExporter.removeTemporaryExport(at: unrelatedFile, temporaryDirectory: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))

        EvaluationDiagnosticsExporter.removeTemporaryExport(at: exportURL, temporaryDirectory: root)
        EvaluationDiagnosticsExporter.removeTemporaryExport(at: exportURL, temporaryDirectory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
    }

    func test_exportFailureFromInvalidTemporaryParentLeavesNoExport() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedParent = root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blockedParent)
        let recorder = BackgroundValidationRecorder(
            fileURL: root.appendingPathComponent("validation-report.json")
        )
        let exporter = EvaluationDiagnosticsExporter(
            journal: NoopEvaluationJournal(),
            recorder: recorder,
            temporaryDirectory: blockedParent
        )

        let exportURL = await exporter.createTemporaryExport()

        XCTAssertNil(exportURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blockedParent.appendingPathComponent(
            EvaluationDiagnosticsExporter.exportDirectoryName
        ).path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evaluation-diagnostics-exporter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func collectKeys(_ value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return Array(dictionary.keys) + dictionary.values.flatMap(collectKeys)
        }
        if let array = value as? [Any] {
            return array.flatMap(collectKeys)
        }
        return []
    }
}
#endif
