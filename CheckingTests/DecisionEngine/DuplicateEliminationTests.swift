import XCTest
@testable import Checking

// Port de DuplicateEliminationTest.kt — conta submits. Ver docs/port_spec_decision_engine.md §9.5.

private func dupCheckedIn(_ local: String) -> HistoryState {
    HistoryState(found: true, chave: "DUP1", projeto: "P80", currentAction: .checkIn, currentLocal: local,
                 hasCurrentDayCheckin: true, lastCheckinAt: iso("2026-06-18T07:00:00Z"), lastCheckoutAt: nil, transportEnabled: false)
}
private func dupMatch(_ local: String) -> LocationMatch {
    LocationMatch(matched: true, resolvedLocal: local, label: local, status: .matched, message: "",
                  accuracyMeters: 10.0, accuracyThresholdMeters: 50, minimumCheckoutDistanceMeters: 2000, nearestWorkplaceDistanceMeters: nil)
}

final class DuplicateEliminationTests: XCTestCase {

    private func makeUseCase(_ capture: FakeCaptureLocation, _ repo: FakeCheckRepository) -> RunAutomaticActivitiesUseCase {
        RunAutomaticActivitiesUseCase(captureLocationUseCase: capture, checkRepository: repo, offlineQueue: FakeOfflineQueue(),
                                      clock: FixedClock(iso("2026-06-18T08:00:00Z")), activityLogger: NoopActivityLogger())
    }
    private func run(_ useCase: RunAutomaticActivitiesUseCase, _ state: HistoryState?) async -> AutoActivitiesResult {
        await useCase(chave: "DUP1", userProjects: UserProjects(projects: ["P80"], activeProject: "P80"),
                      currentState: state, mixedZoneIntervalMinutes: 15, accuracyThresholdMeters: 50)
    }

    func test_two_runs_same_new_location_submits_exactly_once() async {
        let repo = FakeCheckRepository()
        repo.submitHandler = { _, local in .success(dupCheckedIn(local ?? "?")) }
        let useCase = makeUseCase(FakeCaptureLocation(.matched(dupMatch("B"))), repo)
        let r1 = await run(useCase, dupCheckedIn("A"))
        guard case .submitted(_, let l1, let newState) = r1 else { return XCTFail("expected submitted, got \(r1)") }
        XCTAssertEqual(l1, "B")
        let r2 = await run(useCase, newState)
        XCTAssertEqual(r2, .noAction)
        XCTAssertEqual(repo.submitCount, 1)
    }

    func test_stationary_repeats_never_re_check_in() async {
        let repo = FakeCheckRepository()
        let useCase = makeUseCase(FakeCaptureLocation(.matched(dupMatch("B"))), repo)
        for _ in 0..<5 {
            let r = await run(useCase, dupCheckedIn("B"))
            XCTAssertEqual(r, .noAction)
        }
        XCTAssertEqual(repo.submitCount, 0)
    }

    func test_genuine_moves_check_in_per_distinct_location() async {
        let repo = FakeCheckRepository()
        repo.submitHandler = { _, local in .success(dupCheckedIn(local ?? "?")) }
        let capture = FakeCaptureLocation(.matched(dupMatch("B")))
        let useCase = makeUseCase(capture, repo)
        var state = dupCheckedIn("A")
        for loc in ["B", "C"] {
            capture.result = .matched(dupMatch(loc))
            let r = await run(useCase, state)
            guard case .submitted(_, let l, let newState) = r else { return XCTFail("expected submitted, got \(r)") }
            XCTAssertEqual(l, loc)
            state = newState
        }
        XCTAssertEqual(repo.submitCount, 2)
    }

    func test_failed_submit_leaves_state_unchanged_so_retry_may_re_decide() async {
        let repo = FakeCheckRepository()
        repo.submitResult = .failure(.network)
        let useCase = makeUseCase(FakeCaptureLocation(.matched(dupMatch("B"))), repo)
        let r1 = await run(useCase, dupCheckedIn("A"))
        XCTAssertEqual(r1, .networkError)
        repo.submitResult = .success(dupCheckedIn("B"))
        let r2 = await run(useCase, dupCheckedIn("A"))
        guard case .submitted = r2 else { return XCTFail("expected submitted, got \(r2)") }
    }
}
