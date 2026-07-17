import Foundation
@testable import Checking

/// Fake de `AuthApi` no nível de DTO — espelha o `mockk<AuthApi>()` do AuthMappingTest.
final class FakeAuthApi: AuthApi, @unchecked Sendable {
    struct NotStubbed: Error {}
    var statusByChave: [String: WebPasswordStatusResponse] = [:]
    var selfRegResult: WebUserSelfRegistrationResponse?
    var loginResult: WebPasswordActionResponse?
    private(set) var lastSelfRegChave: String?

    func getStatus(_ chave: String) async throws -> WebPasswordStatusResponse {
        guard let r = statusByChave[chave] else { throw NotStubbed() }; return r
    }
    func registerUser(_ body: WebUserSelfRegistrationRequest) async throws -> WebUserSelfRegistrationResponse {
        lastSelfRegChave = body.chave
        guard let r = selfRegResult else { throw NotStubbed() }; return r
    }
    func login(_ body: WebPasswordLoginRequest) async throws -> WebPasswordActionResponse {
        guard let r = loginResult else { throw NotStubbed() }; return r
    }
    func registerPassword(_ body: WebPasswordRegisterRequest) async throws -> WebPasswordActionResponse { throw NotStubbed() }
    func logout() async throws -> WebPasswordActionResponse { throw NotStubbed() }
    func changePassword(_ body: WebPasswordChangeRequest) async throws -> WebPasswordActionResponse { throw NotStubbed() }
    func deleteAccount() async throws -> WebPasswordActionResponse { throw NotStubbed() }
}
