import Foundation
import XCTest
@testable import Checking

private final class ProjectRecordingHTTPClient: HTTPClient, @unchecked Sendable {
    private let response: Data
    private let lock = NSLock()
    private var recordedRequests: [HTTPRequest] = []

    init(response: String) {
        self.response = Data(response.utf8)
    }

    var requests: [HTTPRequest] { lock.withLock { recordedRequests } }

    func data(for request: HTTPRequest) async throws -> Data {
        lock.withLock { recordedRequests.append(request) }
        return response
    }
}

final class ProjectsApiLiveTests: XCTestCase {
    func test_getUserProjectsUsesWebUserProjectsEndpoint() async throws {
        let http = ProjectRecordingHTTPClient(
            response: #"{"projects":["P80"],"active_project":"P80"}"#)
        let api = ProjectsApiLive(http: http)

        let response = try await api.getUserProjects()

        XCTAssertEqual(response.projects, ["P80"])
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests.first?.method.rawValue, "GET")
        XCTAssertEqual(http.requests.first?.path, "user-projects")
        XCTAssertNil(http.requests.first?.body)
    }

    func test_updateUserProjectsPutsEmptySelectionAndAppliesEmptyResponse() async throws {
        let http = ProjectRecordingHTTPClient(
            response: #"{"projects":[],"active_project":"","ok":true,"message":"ok"}"#)
        let api = ProjectsApiLive(http: http)

        let response = try await api.updateUserProjects(
            WebUserProjectsUpdateRequest(projects: []))

        XCTAssertEqual(response.projects, [])
        XCTAssertEqual(response.activeProject, "")
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests.first?.method.rawValue, "PUT")
        XCTAssertEqual(http.requests.first?.path, "user-projects")
        let body = try XCTUnwrap(http.requests.first?.body)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["projects"] as? [String], [])
    }
}
