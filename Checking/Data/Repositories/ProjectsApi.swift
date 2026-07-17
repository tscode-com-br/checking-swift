import Foundation

/// Endpoints de projetos — port de data/api/ProjectsApi.kt. Lança em não-2xx; o repo envolve em `safeApiCall`.
protocol ProjectsApi: Sendable {
    func listProjects() async throws -> [ProjectRow]                                  // GET  projects
    func getUserProjects() async throws -> WebUserProjectsResponse                     // GET  user-projects
    func updateUserProjects(_ body: WebUserProjectsUpdateRequest) async throws -> WebUserProjectsUpdateResponse  // PUT user-projects
    func updateActiveProject(_ body: WebProjectUpdateRequest) async throws -> WebProjectUpdateResponse           // PUT project
}

struct ProjectsApiLive: ProjectsApi {
    let http: any HTTPClient

    func listProjects() async throws -> [ProjectRow] {
        try decode(await http.data(for: HTTPRequest(method: .get, path: "projects")))
    }
    func getUserProjects() async throws -> WebUserProjectsResponse {
        try decode(await http.data(for: HTTPRequest(method: .get, path: "user-projects")))
    }
    func updateUserProjects(_ body: WebUserProjectsUpdateRequest) async throws -> WebUserProjectsUpdateResponse {
        try decode(await http.data(for: HTTPRequest(method: .put, path: "user-projects", body: try JSONCoding.encoder.encode(body))))
    }
    func updateActiveProject(_ body: WebProjectUpdateRequest) async throws -> WebProjectUpdateResponse {
        try decode(await http.data(for: HTTPRequest(method: .put, path: "project", body: try JSONCoding.encoder.encode(body))))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T { try JSONCoding.decoder.decode(T.self, from: data) }
}
