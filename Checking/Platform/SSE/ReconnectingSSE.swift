import Foundation

/// Envolve uma conexão SSE única em reconexão — port de `sseFlow` (SseDataSource.kt, `retryWhen`).
/// - Falha de CONEXÃO re-tenta: `URLError` (transporte) E `HTTPError` (não-2xx). No Kotlin TODA falha de
///   SSE vira `IOException` (o `onFailure` faz `close(t ?: IOException(...))`, inclusive p/ 401/404/5xx),
///   e o `retryWhen` re-tenta todo `IOException` — então re-tentamos ambos p/ paridade.
/// - Espera voltar online (`waitUntilOnline` ≈ `isOnline.first { it }`) antes de re-tentar.
/// - Backoff `sseReconnectDelayMillis(attempt)` — cumulativo, NÃO reseta em sucesso (igual ao `attempt` do retryWhen).
/// - Fim NORMAL (EOF/onClosed) NÃO re-tenta. Reinicia sempre do zero (sem Last-Event-ID).
func reconnectingSSE(url: URL, source: any SSEConnecting, networkMonitor: any NetworkMonitoring,
                     sleeper: any Sleeping = TaskSleeper()) -> AsyncStream<String> {
    AsyncStream { continuation in
        let task = Task {
            var attempt = 0
            while !Task.isCancelled {
                do {
                    for try await data in source.connect(url) { continuation.yield(data) }
                    break                                          // fim normal (EOF) → sem retry
                } catch is CancellationError {
                    break
                } catch {
                    guard error is URLError || error is HTTPError else { break }   // falha de conexão → re-tenta
                    await networkMonitor.waitUntilOnline()
                    await sleeper.sleep(milliseconds: sseReconnectDelayMillis(attempt: attempt))
                    attempt += 1
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
