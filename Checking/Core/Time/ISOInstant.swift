import Foundation

/// Parse/format de instante ISO-8601 no boundary da rede — espelha `Instant.parse(...)` /
/// `Instant.toString()` do Android, com **fallback nil** em parse falho
/// (`runCatching { Instant.parse }.getOrNull()`). Ver port_spec_network_contracts §9.
///
/// Timestamps trafegam como `String` na camada DTO; o parse acontece AQUI, no repositório, não no decode.
/// Formatters são criados por chamada (boundary, não hot-loop) para não segurar estado não-Sendable.
enum ISOInstant {
    /// `nil` em entrada inválida (nunca lança) — igual ao Android.
    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        // Só tenta frações se o primeiro parse falhou (um formatter não faz ambos).
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    /// ISO-8601 com `Z` — espelha `Instant.toString()`, que emite frações de segundo SÓ quando não-zero
    /// (ex.: `...:00Z` para segundo inteiro, `...:00.123Z` para milissegundos).
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        let seconds = date.timeIntervalSince1970
        let fraction = seconds - seconds.rounded(.down)
        formatter.formatOptions = fraction > 0.0005
            ? [.withInternetDateTime, .withFractionalSeconds]   // milissegundos (3 dígitos)
            : [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
