import XCTest
@testable import Checking

// Port de RunAutomaticActivitiesOfflineTest.kt — só falha de REDE enfileira; HTTP nunca.
// Ver docs/port_spec_offline_replay.md §4 e port_spec_decision_engine.md §9.6.
final class AutoActivitiesOfflineTests: XCTestCase {

    private func run(capture: LocationCaptureResult, submit: AppResult<HistoryState> = .success(ucHistory(.checkIn)),
                     state: HistoryState?) async -> (AutoActivitiesResult, FakeOfflineQueue) {
        let repo = FakeCheckRepository(); repo.submitResult = submit
        let queue = FakeOfflineQueue()
        let useCase = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: FakeCaptureLocation(capture), checkRepository: repo, offlineQueue: queue,
            clock: FixedClock(iso("2026-06-16T12:00:00Z")), activityLogger: NoopActivityLogger())
        let result = await useCase(chave: "HR70", userProjects: UserProjects(projects: ["P80"], activeProject: "P80"),
                                   currentState: state, mixedZoneIntervalMinutes: 15, accuracyThresholdMeters: 50)
        return (result, queue)
    }

    func test_capture_network_failure_with_fix_enqueues_raw_event() async {
        let reading = LocationReading(lat: 1.5, lon: 103.8, accuracyMeters: 12.0)
        let (r, queue) = await run(capture: .networkError(reading: reading), state: ucHistory(.checkIn))
        XCTAssertEqual(r, .networkError)
        XCTAssertEqual(queue.enqueued.count, 1)
        guard case .raw(let raw) = queue.enqueued.first else { return XCTFail("expected .raw, got \(String(describing: queue.enqueued.first))") }
        XCTAssertEqual(raw.latitude, 1.5)
        XCTAssertEqual(raw.longitude, 103.8)
        XCTAssertEqual(raw.projeto, "P80")
    }

    func test_capture_network_failure_without_fix_does_not_enqueue() async {
        let (r, queue) = await run(capture: .networkError(reading: nil), state: ucHistory(.checkIn))
        XCTAssertEqual(r, .networkError)
        XCTAssertTrue(queue.enqueued.isEmpty)
    }

    func test_submit_network_failure_enqueues_decided_event() async {
        let (r, queue) = await run(capture: .matched(ucMatch(.matched, "Unidade P80")),
                                   submit: .failure(.network), state: ucHistory(.checkOut))
        XCTAssertEqual(r, .networkError)
        XCTAssertEqual(queue.enqueued.count, 1)
        guard case .decided(let decided) = queue.enqueued.first else { return XCTFail("expected .decided, got \(String(describing: queue.enqueued.first))") }
        XCTAssertEqual(decided.action, "checkin")
        XCTAssertEqual(decided.local, "Unidade P80")
    }

    func test_submit_http_failure_does_not_enqueue() async {
        let (r, queue) = await run(capture: .matched(ucMatch(.matched, "Unidade P80")),
                                   submit: .failure(.http(status: 500, detail: "boom")), state: ucHistory(.checkOut))
        XCTAssertEqual(r, .networkError)
        XCTAssertTrue(queue.enqueued.isEmpty)
    }
}
