import XCTest
@testable import Checking

// Port de AutoActivitiesSituationTest.kt (e2e do RunAutomaticActivitiesUseCase; os 4 testes puros de
// mixed-zone estão em DecisionMatrixTests). Ver docs/port_spec_decision_engine.md §9.1.
final class AutoActivitiesUseCaseTests: XCTestCase {

    private func run(_ match: LocationMatch, _ state: HistoryState?) async -> (AutoActivitiesResult, FakeCheckRepository) {
        let repo = FakeCheckRepository()
        repo.submitResult = .success(ucHistory(.checkIn))
        let useCase = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: FakeCaptureLocation(.matched(match)),
            checkRepository: repo, offlineQueue: FakeOfflineQueue(),
            clock: FixedClock(iso("2026-06-16T12:00:00Z")), activityLogger: NoopActivityLogger())
        let result = await useCase(chave: "STSM", userProjects: UserProjects(projects: ["P80"], activeProject: "P80"),
                                   currentState: state, mixedZoneIntervalMinutes: 15, accuracyThresholdMeters: 50)
        return (result, repo)
    }
    private func assertSubmitted(_ r: AutoActivitiesResult, _ action: CheckAction, _ local: String?, file: StaticString = #filePath, line: UInt = #line) {
        guard case .submitted(let a, let l, _) = r else { return XCTFail("expected .submitted, got \(r)", file: file, line: line) }
        XCTAssertEqual(a, action, file: file, line: line)
        XCTAssertEqual(l, local, file: file, line: line)
    }
    private func assertNoAction(_ r: AutoActivitiesResult, _ repo: FakeCheckRepository, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r, .noAction, file: file, line: line)
        XCTAssertEqual(repo.submitCount, 0, file: file, line: line)
    }

    func test_s1_checkin_in_checkout_zone_checks_out() async {
        let (r, _) = await run(ucMatch(.matched, "Zona de CheckOut"), ucHistory(.checkIn)); assertSubmitted(r, .checkOut, "Zona de CheckOut")
    }
    func test_s1_checkin_far_checks_out() async {
        let (r, _) = await run(ucMatch(.outsideWorkplace, nearest: 5000.0), ucHistory(.checkIn)); assertSubmitted(r, .checkOut, "Fora do Local de Trabalho")
    }
    func test_s2_checkout_in_checkout_zone_no_action() async {
        let (r, repo) = await run(ucMatch(.matched, "Zona de CheckOut"), ucHistory(.checkOut)); assertNoAction(r, repo)
    }
    func test_s2_checkout_far_no_action() async {
        let (r, repo) = await run(ucMatch(.outsideWorkplace, nearest: 5000.0), ucHistory(.checkOut)); assertNoAction(r, repo)
    }
    func test_s3_checkout_in_registered_location_checks_in() async {
        let (r, _) = await run(ucMatch(.matched, "Unidade P80"), ucHistory(.checkOut)); assertSubmitted(r, .checkIn, "Unidade P80")
    }
    func test_s3near_checkout_near_not_registered_no_action() async {
        let (r, repo) = await run(ucMatch(.notInKnownLocation, nearest: 500.0), ucHistory(.checkOut)); assertNoAction(r, repo)
    }
    func test_s4_checkin_same_registered_location_no_action() async {
        let (r, repo) = await run(ucMatch(.matched, "Unidade P80"), ucHistory(.checkIn, currentLocal: "Unidade P80")); assertNoAction(r, repo)
    }
    func test_s4_checkin_different_registered_location_rechecks_in() async {
        let (r, _) = await run(ucMatch(.matched, "Unidade P81"), ucHistory(.checkIn, currentLocal: "Unidade P80")); assertSubmitted(r, .checkIn, "Unidade P81")
    }
    func test_s5_checkin_near_not_registered_checks_in_unregistered() async {
        let (r, _) = await run(ucMatch(.notInKnownLocation, nearest: 500.0), ucHistory(.checkIn, currentLocal: "Unidade P80")); assertSubmitted(r, .checkIn, "Localização não Cadastrada")
    }
    func test_s5_checkin_already_unregistered_no_repeat() async {
        let (r, repo) = await run(ucMatch(.notInKnownLocation, nearest: 500.0), ucHistory(.checkIn, currentLocal: "Localização não Cadastrada")); assertNoAction(r, repo)
    }
    func test_s7b_checkout_near_not_registered_no_action() async {
        let (r, repo) = await run(ucMatch(.notInKnownLocation, nearest: 800.0), ucHistory(.checkOut)); assertNoAction(r, repo)
    }
    func test_s8_mixed_zone_checkin_outside_interval_checks_out() async {
        let s = ucHistory(.checkIn, currentLocal: "Unidade P80", lastCheckinAt: Date().addingTimeInterval(-20 * 60))
        let (r, _) = await run(ucMatch(.matched, "Zona Mista"), s); assertSubmitted(r, .checkOut, "Zona Mista")
    }
    func test_s8_mixed_zone_checkout_outside_interval_checks_in() async {
        let s = ucHistory(.checkOut, currentLocal: "Unidade P80", lastCheckoutAt: Date().addingTimeInterval(-20 * 60))
        let (r, _) = await run(ucMatch(.matched, "Zona Mista"), s); assertSubmitted(r, .checkIn, "Zona Mista")
    }
    func test_s8_mixed_zone_checkin_within_interval_no_action() async {
        let (r, repo) = await run(ucMatch(.matched, "Zona Mista"), ucHistory(.checkIn, currentLocal: "Unidade P80")); assertNoAction(r, repo)
    }
    func test_s8_mixed_zone_checkout_within_interval_no_action() async {
        let (r, repo) = await run(ucMatch(.matched, "Zona Mista"), ucHistory(.checkOut, currentLocal: "Unidade P80")); assertNoAction(r, repo)
    }
    func test_s8_mixed_zone_drift_cooldown_does_not_block_other_locations() async {
        let (r1, _) = await run(ucMatch(.matched, "Zona de CheckOut"), ucHistory(.checkIn, currentLocal: "Unidade P80")); assertSubmitted(r1, .checkOut, "Zona de CheckOut")
        let (r2, _) = await run(ucMatch(.matched, "Unidade P81"), ucHistory(.checkOut, currentLocal: "Unidade P80")); assertSubmitted(r2, .checkIn, "Unidade P81")
    }
    func test_no_history_in_registered_location_checks_in() async {
        let (r, _) = await run(ucMatch(.matched, "Unidade P80"), ucHistory(nil)); assertSubmitted(r, .checkIn, "Unidade P80")
    }
    func test_no_history_far_no_action() async {
        let (r, repo) = await run(ucMatch(.outsideWorkplace, nearest: 5000.0), ucHistory(nil)); assertNoAction(r, repo)
    }
    func test_no_history_in_checkout_zone_no_action() async {
        let (r, repo) = await run(ucMatch(.matched, "Zona de CheckOut"), ucHistory(nil)); assertNoAction(r, repo)
    }
    func test_no_history_near_not_registered_no_action() async {
        let (r, repo) = await run(ucMatch(.notInKnownLocation, nearest: 500.0), ucHistory(nil)); assertNoAction(r, repo)
    }
}
