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
}
