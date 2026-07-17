import Foundation
import Network

/// Monitor de conectividade — port de platform/connectivity/NetworkMonitor.kt (`isOnline: Flow<Boolean>`).
/// Emite o estado ATUAL imediatamente ao assinar, depois em cada mudança (distinctUntilChanged).
/// Usado pelo SSE para portar `isOnline.first { it }` (espera até voltar a rede). Ver port_spec_background §9.
protocol NetworkMonitoring: Sendable {
    func onlineStates() -> AsyncStream<Bool>
}

extension NetworkMonitoring {
    /// Suspende até estar online (no-op se já online) — espelha `isOnline.first { it }`.
    func waitUntilOnline() async {
        for await online in onlineStates() where online { return }
    }
}

/// Monitor de estado fixo (previews/testes triviais) — emite um valor e nunca muda.
struct StaticNetworkMonitor: NetworkMonitoring {
    let online: Bool
    init(online: Bool = true) { self.online = online }
    func onlineStates() -> AsyncStream<Bool> {
        let online = self.online
        return AsyncStream { continuation in continuation.yield(online) }   // 1 emissão, sem finish (não encerra o wait)
    }
}

/// Implementação `NWPathMonitor` (integração — não coberta por teste unitário; a lógica que a usa é fakeada).
final class NWPathMonitorNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    /// Box do último estado — mutado APENAS na queue serial do monitor (por isso `@unchecked Sendable`).
    private final class LastState: @unchecked Sendable { var value: Bool? }

    func onlineStates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "br.com.tscode.checking.network-monitor")
            let last = LastState()
            monitor.pathUpdateHandler = { path in
                let online = path.status == .satisfied
                if online != last.value { last.value = online; continuation.yield(online) }   // distinctUntilChanged
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }
}
