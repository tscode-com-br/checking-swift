import XCTest
@testable import Checking

// Port de RunAutomaticActivitiesLoggingTest.kt — a linha de log escrita por cada desfecho.
// Logger REAL + DAO in-memory + InlineLogScheduler (escrita síncrona, observável no mesmo turno).
// Ver docs/port_spec_decision_engine.md §9.4 e port_spec_persistence_foundation.md §4.
final class AutoActivitiesLoggingTests: XCTestCase {

    private func run(capture: LocationCaptureResult, submit: AppResult<HistoryState> = .success(ucHistory(.checkIn)),
                     dao: CapturingDao, projects: UserProjects = UserProjects(projects: ["P80"], activeProject: "P80"),
                     state: HistoryState? = ucHistory(.checkOut)) async -> AutoActivitiesResult {
        let repo = FakeCheckRepository(); repo.submitResult = submit
        let clock = FixedClock(iso("2026-06-16T12:00:00Z"))
        let logger = ActivityLogger(clock: clock, activityLog: ActivityLog(dao: dao), scheduler: InlineLogScheduler())
        let useCase = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: FakeCaptureLocation(capture), checkRepository: repo,
            offlineQueue: FakeOfflineQueue(), clock: clock, activityLogger: logger)
        return await useCase(chave: "HR70", userProjects: projects, currentState: state,
                             mixedZoneIntervalMinutes: 15, accuracyThresholdMeters: 50)
    }

    func test_success_writes_check_in_success_line() async {
        let dao = CapturingDao()
        let r = await run(capture: .matched(ucMatch(.matched, "Unidade P80")), dao: dao)
        guard case .submitted = r else { return XCTFail("expected submitted, got \(r)") }
        let row = dao.rows.last!
        XCTAssertEqual(row.kind, "CHECK_IN")
        XCTAssertEqual(row.severity, "SUCCESS")
        XCTAssertEqual(row.actor, "SYS")
        XCTAssertEqual(row.description, "Check-in at Unidade P80.")
    }

    func test_network_failure_writes_queued_offline_line() async {
        let dao = CapturingDao()
        let r = await run(capture: .matched(ucMatch(.matched, "Unidade P80")), submit: .failure(.network), dao: dao)
        XCTAssertEqual(r, .networkError)
        let row = dao.rows.last!
        XCTAssertEqual(row.kind, "SYNC")
        XCTAssertEqual(row.severity, "WARNING")
        XCTAssertEqual(row.actor, "SYS")
        XCTAssertTrue(row.description.contains("queued (offline)"))
    }

    func test_http_failure_writes_check_in_failed_line() async {
        let dao = CapturingDao()
        let r = await run(capture: .matched(ucMatch(.matched, "Unidade P80")),
                          submit: .failure(.http(status: 500, detail: "boom")), dao: dao)
        XCTAssertEqual(r, .networkError)
        let row = dao.rows.last!
        XCTAssertEqual(row.kind, "CHECK_IN")
        XCTAssertEqual(row.severity, "FAILURE")
        XCTAssertEqual(row.description, "Check-in failed at Unidade P80.")
    }

    func test_no_active_project_writes_system_warning_line() async {
        let dao = CapturingDao()
        let r = await run(capture: .matched(ucMatch(.matched, "Unidade P80")), dao: dao,
                          projects: UserProjects(projects: [], activeProject: ""))
        XCTAssertEqual(r, .notConfigured)
        let row = dao.rows.last!
        XCTAssertEqual(row.kind, "SYSTEM")
        XCTAssertEqual(row.severity, "WARNING")
        XCTAssertEqual(row.actor, "SYS")
        XCTAssertEqual(row.description, "No active project — skipped.")
    }

    func test_capture_network_failure_writes_location_warning_line() async {
        let dao = CapturingDao()
        let reading = LocationReading(lat: 1.3, lon: 103.8, accuracyMeters: 10.0)
        let r = await run(capture: .networkError(reading: reading), dao: dao)
        XCTAssertEqual(r, .networkError)
        let row = dao.rows.last!
        XCTAssertEqual(row.kind, "LOCATION")
        XCTAssertEqual(row.severity, "WARNING")
        XCTAssertEqual(row.actor, "SYS")
        XCTAssertEqual(row.description, "Location reading queued offline — will sync on reconnect.")
    }

    func test_logging_failure_never_breaks_the_engine() async {
        let dao = CapturingDao(throwOnInsert: true)
        let r = await run(capture: .matched(ucMatch(.matched, "Unidade P80")), dao: dao)
        guard case .submitted = r else { return XCTFail("expected submitted, got \(r)") }
        XCTAssertEqual(dao.rows.count, 0)
    }
}
