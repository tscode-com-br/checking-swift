import XCTest
@testable import Checking

// Port de CaptureLocationLoggingTest.kt — o único chokepoint que escreve a linha LOCATION.
// Logger REAL + DAO in-memory + InlineLogScheduler. Ver docs/port_spec_decision_engine.md §9.3.
final class CaptureLocationLoggingTests: XCTestCase {

    private func run(provider: LocationCapture, match: AppResult<LocationMatch>, dao: CapturingDao) async -> LocationCaptureResult {
        let repo = FakeCheckRepository(); repo.matchLocationResult = match
        let logger = ActivityLogger(clock: FixedClock(iso("2026-06-20T08:00:00Z")),
                                    activityLog: ActivityLog(dao: dao), scheduler: InlineLogScheduler())
        let useCase = CaptureLocationUseCase(locationProvider: FakeLocationProvider(provider),
                                             checkRepository: repo, activityLogger: logger)
        return await useCase(50)
    }

    func test_matched_fix_writes_location_info_line() async {
        let dao = CapturingDao()
        let r = await run(provider: .success(lat: 1.3, lon: 103.8, accuracyMeters: 12.7),
                          match: .success(ucMatch(.matched, "Unidade P80")), dao: dao)
        guard case .matched = r else { return XCTFail("expected matched, got \(r)") }
        let row = dao.rows.last!
        XCTAssertEqual(row.kind, "LOCATION")
        XCTAssertEqual(row.severity, "INFO")
        XCTAssertEqual(row.actor, "SYS")
        XCTAssertEqual(row.description, "Location fixed (±12m) → Unidade P80.")
        XCTAssertEqual(row.location, "Unidade P80")
    }

    func test_accuracy_too_low_writes_location_warning_line() async {
        let dao = CapturingDao()
        _ = await run(provider: .success(lat: 1.3, lon: 103.8, accuracyMeters: 80.4),
                      match: .success(ucMatch(.accuracyTooLow, nil)), dao: dao)
        let row = dao.rows.last!
        XCTAssertEqual(row.kind, "LOCATION")
        XCTAssertEqual(row.severity, "WARNING")
        XCTAssertEqual(row.description, "Location accuracy too low (±80m).")
    }

    func test_logging_failure_never_breaks_capture() async {
        let dao = CapturingDao(throwOnInsert: true)
        let r = await run(provider: .success(lat: 1.3, lon: 103.8, accuracyMeters: 12.7),
                          match: .success(ucMatch(.matched, "Unidade P80")), dao: dao)
        guard case .matched = r else { return XCTFail("expected matched, got \(r)") }
        XCTAssertEqual(dao.rows.count, 0)
    }
}
