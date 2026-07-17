import XCTest
@testable import Checking

// Port de AuthMappingTest.kt — DTO→AuthStatus (fake AuthApi). §9.2.
final class AuthMappingTests: XCTestCase {

    private func makeRepo(_ api: FakeAuthApi) -> AuthRepositoryLive {
        AuthRepositoryLive(api: api, checkRepository: FakeCheckRepository(), cookieStore: InMemorySessionCookieStore())
    }
    private func statusDto(found: Bool, hasPassword: Bool, pendingApproval: Bool) -> WebPasswordStatusResponse {
        WebPasswordStatusResponse(found: found, chave: "NEW1", hasPassword: hasPassword, authenticated: false, message: "m", pendingApproval: pendingApproval)
    }
    private func selfRegDto(status: String, authenticated: Bool, pending: Bool, queueFull: Bool) -> WebUserSelfRegistrationResponse {
        WebUserSelfRegistrationResponse(ok: true, authenticated: authenticated, hasPassword: authenticated, message: "m",
                                        status: status, pendingApproval: pending, queueFull: queueFull,
                                        projects: ["P80"], activeProject: authenticated ? "P80" : "")
    }
    private func selfRegister(_ repo: AuthRepositoryLive) async -> AppResult<AuthStatus> {
        await repo.selfRegister("NEW1", "Nome Completo", ["P80"], nil, "abc123", "abc123")
    }

    func test_getStatus_maps_pending_approval_true() async {
        let api = FakeAuthApi(); api.statusByChave["NEW1"] = statusDto(found: false, hasPassword: false, pendingApproval: true)
        guard case .success(let s) = await makeRepo(api).getStatus("NEW1") else { return XCTFail("expected success") }
        XCTAssertFalse(s.found); XCTAssertFalse(s.authenticated); XCTAssertTrue(s.pendingApproval)
    }

    func test_getStatus_normal_user() async {
        let api = FakeAuthApi(); api.statusByChave["HR70"] = statusDto(found: true, hasPassword: true, pendingApproval: false)
        guard case .success(let s) = await makeRepo(api).getStatus("HR70") else { return XCTFail("expected success") }
        XCTAssertTrue(s.found); XCTAssertFalse(s.pendingApproval)
    }

    func test_selfRegister_pending() async {
        let api = FakeAuthApi(); api.selfRegResult = selfRegDto(status: "pending", authenticated: false, pending: true, queueFull: false)
        guard case .success(let s) = await selfRegister(makeRepo(api)) else { return XCTFail("expected success") }
        XCTAssertFalse(s.found); XCTAssertFalse(s.authenticated); XCTAssertTrue(s.pendingApproval); XCTAssertFalse(s.queueFull)
    }

    func test_selfRegister_queue_full() async {
        let api = FakeAuthApi(); api.selfRegResult = selfRegDto(status: "queue_full", authenticated: false, pending: false, queueFull: true)
        guard case .success(let s) = await selfRegister(makeRepo(api)) else { return XCTFail("expected success") }
        XCTAssertFalse(s.found); XCTAssertFalse(s.authenticated); XCTAssertTrue(s.queueFull); XCTAssertFalse(s.pendingApproval)
    }

    func test_selfRegister_registered() async {
        let api = FakeAuthApi(); api.selfRegResult = selfRegDto(status: "registered", authenticated: true, pending: false, queueFull: false)
        guard case .success(let s) = await selfRegister(makeRepo(api)) else { return XCTFail("expected success") }
        XCTAssertTrue(s.found); XCTAssertTrue(s.authenticated); XCTAssertFalse(s.pendingApproval); XCTAssertFalse(s.queueFull)
    }
}
