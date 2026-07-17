import Foundation

/// Envelopa toda chamada de rede na taxonomia de erro EXATA do Android (`ApiCallUtils.safeApiCall`).
/// Ordem dos catches fiel: HTTPError → (cancelamento) → URLError → tudo mais. Ver port_spec_network_contracts §2.
///
/// - 401/403 → `.unauthorized` (sessão expirada, volta ao prompt silenciosamente)
/// - 409     → `.conflict`
/// - outro HTTP → `.http(status, detail)` — `detail` é o corpo cru (não parseado)
/// - `URLError` (timeout OU sem-rede, indistinguíveis) → `.network`
/// - cancelamento (`CancellationError` / `URLError.cancelled`) → `.unknown` — no Android a
///   `CancellationException` não é `IOException`, então cai em `Unknown` (NÃO em `Network`, que o
///   replayer trataria como RETRY). Manter fora de `.network` evita retry de evento cancelado.
/// - qualquer outro (inclui `DecodingError`) → `.unknown`
func safeApiCall<T>(_ call: () async throws -> T) async -> AppResult<T> {
    do {
        return .success(try await call())
    } catch let error as HTTPError {
        switch error.status {
        case 401, 403: return .failure(.unauthorized)
        case 409:      return .failure(.conflict)
        default:       return .failure(.http(status: error.status, detail: error.body))
        }
    } catch is CancellationError {
        return .failure(.unknown(description: "cancelled"))
    } catch let urlError as URLError where urlError.code == .cancelled {
        return .failure(.unknown(description: String(describing: urlError)))
    } catch is URLError {
        return .failure(.network)
    } catch {
        return .failure(.unknown(description: String(describing: error)))
    }
}
