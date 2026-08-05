import Foundation

/// Endpoints tipados do módulo Check — port de data/api/CheckApi.kt (Retrofit → protocolo Swift).
/// Cada método lança em não-2xx (via `HTTPError`); o repositório envolve em `safeApiCall`.
/// A conexão SSE `check/stream` NÃO está aqui (é consumida por `CheckEventStream`, slice de background).
/// Ver port_spec_network_contracts §5.
protocol CheckApi: Sendable {
    func getState(_ chave: String) async throws -> WebCheckHistoryResponse            // GET  check/state?chave
    func getHistory(_ chave: String) async throws -> WebCheckHistoryListResponseDto   // GET  check/history?chave
    func getLocations() async throws -> WebLocationOptionsResponse                    // GET  check/locations
    func matchLocation(_ body: WebLocationMatchRequest) async throws -> WebLocationMatchResponse  // POST check/location
    func getGeofences(_ chave: String) async throws -> WebGeofencesResponse           // GET  check/geofences?chave
    func submit(_ body: WebCheckSubmitRequest) async throws -> MobileSubmitResponse   // POST check

    /// Variantes exclusivas do motor automático. `notDispatched` é distinto de uma falha HTTP e prova
    /// que a revogação venceu antes do início do request; os contratos de body/path permanecem os mesmos.
    func matchLocation(
        _ body: WebLocationMatchRequest,
        dispatchAuthorization: HTTPRequestDispatchAuthorization
    ) async throws -> GuardedOperationResult<WebLocationMatchResponse>
    func submit(
        _ body: WebCheckSubmitRequest,
        dispatchAuthorization: HTTPRequestDispatchAuthorization
    ) async throws -> GuardedOperationResult<MobileSubmitResponse>
}

extension CheckApi {
    /// Compatibilidade para fakes/adapters: cria a chamada antiga dentro do ponto de linearização.
    /// `CheckApiLive` sobrescreve estas variantes e lineariza o `URLSessionDataTask.resume()` real.
    func matchLocation(
        _ body: WebLocationMatchRequest,
        dispatchAuthorization: HTTPRequestDispatchAuthorization
    ) async throws -> GuardedOperationResult<WebLocationMatchResponse> {
        try await runGuardedAsyncOperation(
            authorization: dispatchAuthorization,
            operation: { try await self.matchLocation(body) }
        )
    }

    func submit(
        _ body: WebCheckSubmitRequest,
        dispatchAuthorization: HTTPRequestDispatchAuthorization
    ) async throws -> GuardedOperationResult<MobileSubmitResponse> {
        try await runGuardedAsyncOperation(
            authorization: dispatchAuthorization,
            operation: { try await self.submit(body) }
        )
    }
}
