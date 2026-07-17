import Foundation

/// Endpoints de auth — port de data/api/AuthApi.kt. Lança em não-2xx; o repo envolve em `safeApiCall`. §4.
protocol AuthApi: Sendable {
    func getStatus(_ chave: String) async throws -> WebPasswordStatusResponse           // GET  auth/status?chave
    func registerPassword(_ body: WebPasswordRegisterRequest) async throws -> WebPasswordActionResponse  // POST auth/register-password
    func registerUser(_ body: WebUserSelfRegistrationRequest) async throws -> WebUserSelfRegistrationResponse // POST auth/register-user
    func login(_ body: WebPasswordLoginRequest) async throws -> WebPasswordActionResponse               // POST auth/login
    func logout() async throws -> WebPasswordActionResponse                              // POST auth/logout (sem body)
    func changePassword(_ body: WebPasswordChangeRequest) async throws -> WebPasswordActionResponse      // POST auth/change-password
    func deleteAccount() async throws -> WebPasswordActionResponse                       // POST auth/delete-account (cookie)
}

struct AuthApiLive: AuthApi {
    let http: any HTTPClient

    func getStatus(_ chave: String) async throws -> WebPasswordStatusResponse {
        try decode(await http.data(for: HTTPRequest(method: .get, path: "auth/status", query: ["chave": chave])))
    }
    func registerPassword(_ body: WebPasswordRegisterRequest) async throws -> WebPasswordActionResponse {
        try decode(await http.data(for: HTTPRequest(method: .post, path: "auth/register-password", body: try JSONCoding.encoder.encode(body))))
    }
    func registerUser(_ body: WebUserSelfRegistrationRequest) async throws -> WebUserSelfRegistrationResponse {
        try decode(await http.data(for: HTTPRequest(method: .post, path: "auth/register-user", body: try JSONCoding.encoder.encode(body))))
    }
    func login(_ body: WebPasswordLoginRequest) async throws -> WebPasswordActionResponse {
        try decode(await http.data(for: HTTPRequest(method: .post, path: "auth/login", body: try JSONCoding.encoder.encode(body))))
    }
    func logout() async throws -> WebPasswordActionResponse {
        try decode(await http.data(for: HTTPRequest(method: .post, path: "auth/logout")))
    }
    func changePassword(_ body: WebPasswordChangeRequest) async throws -> WebPasswordActionResponse {
        try decode(await http.data(for: HTTPRequest(method: .post, path: "auth/change-password", body: try JSONCoding.encoder.encode(body))))
    }
    func deleteAccount() async throws -> WebPasswordActionResponse {
        try decode(await http.data(for: HTTPRequest(method: .post, path: "auth/delete-account")))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T { try JSONCoding.decoder.decode(T.self, from: data) }
}
