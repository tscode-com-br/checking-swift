import XCTest
@testable import Checking

/// Fake de `ProjectsApi` no nível de DTO — p/ os testes de mapeamento do repositório.
final class FakeProjectsApi: ProjectsApi, @unchecked Sendable {
    struct NotStubbed: Error {}
    var listProjectsResult: [ProjectRow]?
    var getUserProjectsResult: WebUserProjectsResponse?
    var updateUserProjectsResult: WebUserProjectsUpdateResponse?
    var updateActiveProjectResult: WebProjectUpdateResponse?
    var throwError: Error?

    private let lock = NSLock()
    private var recordedUpdateUserProjects: [[String]] = []
    private var recordedUpdateActiveProject: [String] = []
    var updateUserProjectsCalls: [[String]] { lock.withLock { recordedUpdateUserProjects } }
    var updateActiveProjectCalls: [String] { lock.withLock { recordedUpdateActiveProject } }

    func listProjects() async throws -> [ProjectRow] {
        if let throwError { throw throwError }
        guard let r = listProjectsResult else { throw NotStubbed() }; return r
    }
    func getUserProjects() async throws -> WebUserProjectsResponse {
        if let throwError { throw throwError }
        guard let r = getUserProjectsResult else { throw NotStubbed() }; return r
    }
    func updateUserProjects(_ body: WebUserProjectsUpdateRequest) async throws -> WebUserProjectsUpdateResponse {
        lock.withLock { recordedUpdateUserProjects.append(body.projects) }
        if let throwError { throw throwError }
        guard let r = updateUserProjectsResult else { throw NotStubbed() }; return r
    }
    func updateActiveProject(_ body: WebProjectUpdateRequest) async throws -> WebProjectUpdateResponse {
        lock.withLock { recordedUpdateActiveProject.append(body.project) }
        if let throwError { throw throwError }
        guard let r = updateActiveProjectResult else { throw NotStubbed() }; return r
    }
}

// Mapeamento DTO→domínio — port implícito de ProjectRepositoryImpl.kt (sem teste dedicado no Kotlin).
final class ProjectRepositoryMappingTests: XCTestCase {

    private func makeRepo(_ api: FakeProjectsApi) -> ProjectRepositoryLive { ProjectRepositoryLive(api: api) }

    func test_listProjects_maps_id_name_transportEnabled_only() async {
        let api = FakeProjectsApi()
        api.listProjectsResult = [
            ProjectRow(id: 1, name: "P80", countryCode: "BR", countryName: "Brasil", timezoneName: "America/Sao_Paulo",
                      timezoneLabel: "BRT", address: "Rua X", zipCode: "0", formsEnabled: true, transportEnabled: true,
                      emergencyPhone: "190", inactivityDaysThreshold: 90, mixedZoneIntervalMinutes: 15),
        ]
        guard case .success(let projects) = await makeRepo(api).listProjects() else { return XCTFail("expected success") }
        XCTAssertEqual(projects, [Project(id: 1, name: "P80", transportEnabled: true)])   // só os 3 campos — nada mais vaza
    }

    func test_listProjects_empty() async {
        let api = FakeProjectsApi()
        api.listProjectsResult = []
        guard case .success(let projects) = await makeRepo(api).listProjects() else { return XCTFail("expected success") }
        XCTAssertTrue(projects.isEmpty)
    }

    func test_getUserProjects_maps_projects_and_activeProject() async {
        let api = FakeProjectsApi()
        api.getUserProjectsResult = WebUserProjectsResponse(projects: ["P80", "P81"], activeProject: "P80")
        guard case .success(let up) = await makeRepo(api).getUserProjects() else { return XCTFail("expected success") }
        XCTAssertEqual(up, UserProjects(projects: ["P80", "P81"], activeProject: "P80"))
    }

    func test_updateUserProjects_sends_names_and_maps_response() async {
        let api = FakeProjectsApi()
        api.updateUserProjectsResult = WebUserProjectsUpdateResponse(projects: ["P80", "P81"], activeProject: "P80", ok: true, message: "ok")
        guard case .success(let up) = await makeRepo(api).updateUserProjects(["P80", "P81"]) else { return XCTFail("expected success") }
        XCTAssertEqual(up.projects, ["P80", "P81"])
        XCTAssertEqual(api.updateUserProjectsCalls, [["P80", "P81"]])
    }

    func test_updateActiveProject_sends_name_and_maps_response() async {
        let api = FakeProjectsApi()
        api.updateActiveProjectResult = WebProjectUpdateResponse(projects: ["P80", "P81"], activeProject: "P81", ok: true, message: "ok", project: "P81")
        guard case .success(let up) = await makeRepo(api).updateActiveProject("P81") else { return XCTFail("expected success") }
        XCTAssertEqual(up.activeProject, "P81")
        XCTAssertEqual(api.updateActiveProjectCalls, ["P81"])
    }

    func test_errors_propagate_via_safeApiCall() async {
        let api = FakeProjectsApi()
        api.throwError = HTTPError(status: 500, body: "boom")
        let result = await makeRepo(api).listProjects()
        XCTAssertEqual(result.error, .http(status: 500, detail: "boom"))
    }

    func test_unauthorized_maps_correctly() async {
        let api = FakeProjectsApi()
        api.throwError = HTTPError(status: 401, body: nil)
        let result = await makeRepo(api).getUserProjects()
        XCTAssertEqual(result.error, .unauthorized)
    }
}
