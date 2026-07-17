import Foundation

/// Taxonomia de erro de domínio — espelha `core/error/ApiError` do Kotlin.
/// Mapeamento exato em `safeApiCall` — ver port_spec_network_contracts §2.
public enum ApiError: Error, Sendable {
    /// 4xx/5xx com o `detail` do FastAPI.
    case http(status: Int, detail: String?)
    /// 401/403 — sessão expirada; volta ao prompt de senha silenciosamente.
    case unauthorized
    /// 409 — conflito (acidente já ativo; emergência já acionada).
    case conflict
    /// Sem rede OU timeout (indistinguíveis).
    case network
    /// Erro inesperado não coberto acima (inclui `DecodingError`, cancelamento). Espelha o
    /// `Unknown(cause: Throwable)` do Kotlin; guardamos a DESCRIÇÃO textual (Sendable-safe) em vez do
    /// `Error` tipado (não-Sendable) — o suficiente para diagnóstico/log (golden rule 2).
    case unknown(description: String?)
}

extension ApiError: Equatable {
    // `unknown` compara por tipo (a descrição é diagnóstica; nenhum consumidor roteia por ela — o replayer
    // trata Unknown por tipo). Manual porque `Error`/`String?`-diagnóstico não deve influenciar igualdade.
    public static func == (lhs: ApiError, rhs: ApiError) -> Bool {
        switch (lhs, rhs) {
        case let (.http(ls, ld), .http(rs, rd)): return ls == rs && ld == rd
        case (.unauthorized, .unauthorized), (.conflict, .conflict), (.network, .network): return true
        case (.unknown, .unknown): return true
        default: return false
        }
    }
}
