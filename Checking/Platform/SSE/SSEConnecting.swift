import Foundation

/// Uma conexão SSE única — emite os payloads `data` até fechar (fim normal) ou lançar (erro).
/// Seam testável: o wrapper de reconexão roda sobre um fake; a impl viva usa URLSession.bytes.
protocol SSEConnecting: Sendable {
    func connect(_ url: URL) -> AsyncThrowingStream<String, Error>
}

/// Espera injetável (backoff) — no-op instantâneo nos testes. Port do `delay` do retryWhen.
protocol Sleeping: Sendable {
    func sleep(milliseconds: Int) async
}
struct TaskSleeper: Sleeping {
    func sleep(milliseconds: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }
}

/// Conexão SSE viva via `URLSession.bytes` + `SSELineParser` — port do `sseFlow`/EventSource.
/// `Accept: text/event-stream`, `X-Client`, sem read-timeout mid-stream. Só o payload `data` segue adiante.
/// Integração (não coberta por teste unitário; a lógica de reconexão/multicast que a usa é fakeada).
final class URLSessionSSEConnection: SSEConnecting, @unchecked Sendable {
    private let session: URLSession
    private let xClient: String
    private let cookieStore: (any SessionCookieStore)?

    init(xClient: String, session: URLSession? = nil, cookieStore: (any SessionCookieStore)? = nil) {
        self.xClient = xClient
        self.cookieStore = cookieStore
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 0        // SSE infinito — sem read-timeout mid-stream (§1)
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config)
        }
    }

    func connect(_ url: URL) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue(xClient, forHTTPHeaderField: "X-Client")
                    if let cookieStore, let header = cookieStore.cookieHeader(for: url) {
                        request.setValue(header, forHTTPHeaderField: "Cookie")
                    }
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw HTTPError(status: http.statusCode, body: nil)   // não-2xx → retentável no wrapper (§ Kotlin)
                    }
                    // NÃO usar `bytes.lines`: o AsyncLineSequence da Foundation DESCARTA linhas em branco,
                    // e é a linha em branco que DESPACHA o evento SSE. Split manual preservando vazias.
                    var parser = SSELineParser()
                    var lineBytes: [UInt8] = []
                    for try await byte in bytes {
                        if byte == 0x0A {   // \n → fim de linha (o parser tira o \r final)
                            if let payload = parser.consume(String(decoding: lineBytes, as: UTF8.self)) { continuation.yield(payload) }
                            lineBytes.removeAll(keepingCapacity: true)
                        } else {
                            lineBytes.append(byte)
                        }
                    }
                    continuation.finish()                 // EOF do servidor → fim normal (sem retry)
                } catch {
                    continuation.finish(throwing: error)  // URLError (rede) → retentável no wrapper
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
