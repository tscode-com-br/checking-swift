import Foundation

/// Implementação de `CheckApi` sobre `HTTPClient` + `JSONCoding`. Mapeamento de path/query/body 1:1
/// com o Retrofit do Android. Ver port_spec_network_contracts §5.
struct CheckApiLive: CheckApi {
    let http: any HTTPClient

    func getState(_ chave: String) async throws -> WebCheckHistoryResponse {
        try decode(await http.data(for: HTTPRequest(method: .get, path: "check/state", query: ["chave": chave])))
    }
    func getHistory(_ chave: String) async throws -> WebCheckHistoryListResponseDto {
        try decode(await http.data(for: HTTPRequest(method: .get, path: "check/history", query: ["chave": chave])))
    }
    func getLocations() async throws -> WebLocationOptionsResponse {
        try decode(await http.data(for: HTTPRequest(method: .get, path: "check/locations")))
    }
    func matchLocation(_ body: WebLocationMatchRequest) async throws -> WebLocationMatchResponse {
        try decode(await http.data(for: HTTPRequest(method: .post, path: "check/location", body: try JSONCoding.encoder.encode(body))))
    }
    func getGeofences(_ chave: String) async throws -> WebGeofencesResponse {
        try decode(await http.data(for: HTTPRequest(method: .get, path: "check/geofences", query: ["chave": chave])))
    }
    func submit(_ body: WebCheckSubmitRequest) async throws -> MobileSubmitResponse {
        try decode(await http.data(for: HTTPRequest(method: .post, path: "check", body: try JSONCoding.encoder.encode(body))))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: data)
    }
}
