import Foundation

/// Drena a fila offline (o `PendingCheckReplayer`). Seam p/ fakear o replayer nos testes do coordenador.
protocol OfflineDraining: Sendable {
    func drain() async -> DrainResult
}
extension PendingCheckReplayer: OfflineDraining {}

/// Dispara o drain quando a rede VOLTA — port do gatilho `NetworkType.CONNECTED` do
/// SyncPendingChecksWorker via `NWPathMonitor`. Single-flight: não sobrepõe drains.
/// (O `BGTaskSyncScheduler` complementa com o gatilho oportunista de background.) Ver port_spec_background §9/§10.
actor OfflineSyncCoordinator {
    private let replayer: any OfflineDraining
    private let monitor: any NetworkMonitoring

    private var isDraining = false
    private var monitorTask: Task<Void, Never>?
    private(set) var drainCount = 0        // observabilidade p/ teste

    init(replayer: any OfflineDraining, monitor: any NetworkMonitoring) {
        self.replayer = replayer
        self.monitor = monitor
    }

    /// Observa a conectividade; a cada transição para online (inclui o 1º online) dispara um drain.
    func start() {
        guard monitorTask == nil else { return }
        let monitor = self.monitor
        monitorTask = Task { [weak self] in
            var wasOnline = false
            for await online in monitor.onlineStates() {
                if online && !wasOnline { await self?.triggerDrain() }
                wasOnline = online
            }
        }
    }

    func stop() { monitorTask?.cancel(); monitorTask = nil }

    /// Dispara um drain se nenhum estiver em andamento (single-flight). Também chamável no foreground/BGTask.
    func triggerDrain() async {
        if isDraining { return }
        isDraining = true
        drainCount += 1
        defer { isDraining = false }
        _ = await replayer.drain()
    }
}
