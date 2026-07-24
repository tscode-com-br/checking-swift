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
}
#endif
