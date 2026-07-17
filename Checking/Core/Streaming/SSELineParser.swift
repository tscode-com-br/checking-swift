import Foundation

/// Parser de linhas SSE (Server-Sent Events) — no iOS não há cliente SSE first-party, então
/// reimplementamos o parsing que o OkHttp `EventSource` fazia no Android. Ver port_spec_network_contracts §3.
///
/// Regras (WHATWG EventSource, igual ao comportamento observado do OkHttp):
/// - `data:` acumula (múltiplas linhas concatenadas com `\n`).
/// - `event:` / `id:` / `retry:` e campos desconhecidos são **descartados** — só o payload `data` segue
///   adiante (o Android encaminha apenas `data` via `Flow<String>`).
/// - Linha iniciando com `:` é comentário (keep-alive) → ignorada.
/// - **Linha em branco despacha** o evento acumulado (só se houve algum `data`).
/// - `\r` final (CRLF) é removido.
///
/// Uso streaming: alimente `consume(_:)` linha a linha; ele devolve o payload quando um evento fecha.
struct SSELineParser {
    private var dataLines: [String] = []

    /// Consome uma linha; devolve o payload `data` se esta linha (em branco) fechou um evento, senão `nil`.
    mutating func consume(_ rawLine: String) -> String? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }

        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }   // blank sem data → keep-alive, nada a despachar
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            return payload
        }
        if line.hasPrefix(":") { return nil }              // comentário

        let (field, value) = Self.splitField(line)
        if field == "data" { dataLines.append(value) }     // demais campos: descartados
        return nil
    }

    /// Divide "campo: valor" — valor após o primeiro `:` com UM espaço inicial opcional removido.
    /// Sem `:` → a linha inteira é o nome do campo, valor vazio (spec SSE).
    private static func splitField(_ line: String) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        let field = String(line[line.startIndex..<colon])
        var valueStart = line.index(after: colon)
        if valueStart < line.endIndex, line[valueStart] == " " { valueStart = line.index(after: valueStart) }
        return (field, String(line[valueStart..<line.endIndex]))
    }
}

/// Divide bytes SSE em linhas PRESERVANDO linhas em branco (o `AsyncLineSequence` da Foundation as
/// DESCARTA, quebrando o despacho de eventos). Companheiro puro/testável da `URLSessionSSEConnection`.
func splitSSEBytesIntoLines(_ bytes: [UInt8]) -> [String] {
    var lines: [String] = []
    var buffer: [UInt8] = []
    for byte in bytes {
        if byte == 0x0A {   // \n
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll(keepingCapacity: true)
        } else {
            buffer.append(byte)
        }
    }
    return lines
}

/// Backoff de reconexão SSE — `min(1000 · 2^min(tentativa,5), 30000)` (tentativa 0-based).
/// Sequência: 1s, 2s, 4s, 8s, 16s, 30s (cap). Ver port_spec_network_contracts §3.
func sseReconnectDelayMillis(attempt: Int) -> Int {
    let exponent = min(max(attempt, 0), 5)
    return min(1000 * (1 << exponent), 30000)
}
