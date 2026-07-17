import Foundation
@testable import Checking

/// Fake de `CheckApi` no nível de DTO — espelha o `mockk<CheckApi>()` do CheckHistoryMapperTest.kt
/// (retorna objetos DTO, não JSON). Grava os últimos requests para asserção de construção.
final class FakeCheckApi: CheckApi, @unchecked Sendable {
    struct NotStubbed: Error {}

    var onGetState: (@Sendable (String) async throws -> WebCheckHistoryResponse)?
    var onGetHistory: (@Sendable (String) async throws -> WebCheckHistoryListResponseDto)?
    var onGetLocations: (@Sendable () async throws -> WebLocationOptionsResponse)?
    var onMatchLocation: (@Sendable (WebLocationMatchRequest) async throws -> WebLocationMatchResponse)?
    var onGetGeofences: (@Sendable (String) async throws -> WebGeofencesResponse)?
    var onSubmit: (@Sendable (WebCheckSubmitRequest) async throws -> MobileSubmitResponse)?

    private(set) var lastSubmitRequest: WebCheckSubmitRequest?
    private(set) var lastMatchRequest: WebLocationMatchRequest?
    private(set) var getGeofencesCallCount = 0

    func getState(_ chave: String) async throws -> WebCheckHistoryResponse {
        guard let h = onGetState else { throw NotStubbed() }; return try await h(chave)
    }
    func getHistory(_ chave: String) async throws -> WebCheckHistoryListResponseDto {
        guard let h = onGetHistory else { throw NotStubbed() }; return try await h(chave)
    }
    func getLocations() async throws -> WebLocationOptionsResponse {
        guard let h = onGetLocations else { throw NotStubbed() }; return try await h()
    }
    func matchLocation(_ body: WebLocationMatchRequest) async throws -> WebLocationMatchResponse {
        lastMatchRequest = body
        guard let h = onMatchLocation else { throw NotStubbed() }; return try await h(body)
    }
    func getGeofences(_ chave: String) async throws -> WebGeofencesResponse {
        getGeofencesCallCount += 1
        guard let h = onGetGeofences else { throw NotStubbed() }; return try await h(chave)
    }
    func submit(_ body: WebCheckSubmitRequest) async throws -> MobileSubmitResponse {
        lastSubmitRequest = body
        guard let h = onSubmit else { throw NotStubbed() }; return try await h(body)
    }
}
