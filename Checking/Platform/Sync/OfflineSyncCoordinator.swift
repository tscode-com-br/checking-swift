import Foundation

/// Drena a fila offline (o `PendingCheckReplayer`). Seam p/ fakear o replayer nos testes do coordenador.
protocol OfflineDraining: Sendable {
    func drain() async -> DrainResult
}
extension PendingCheckReplayer: OfflineDraining {}

/// Handle bounded para o único drain canônico em voo. Callers podem aguardar a mesma `Task` sem que o
/// cancelamento de um waiter seja propagado ao trabalho compartilhado. O cancelamento explícito fica
/// separado para o futuro controller de ownership do BGProcessing: somente ele poderá chamá-lo quando o
/// último orçamento válido expirar.
struct OfflineDrainTicket: Sendable {
    let id: UUID
    private let completionTask: Task<DrainResult, Never>
    private let cancelCanonical: @Sendable () -> Void

    fileprivate init(
        id: UUID,
        completionTask: Task<DrainResult, Never>,
        cancelCanonical: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.completionTask = completionTask
        self.cancelCanonical = cancelCanonical
    }

    func completion() async -> DrainResult {
        await completionTask.value
    }

    /// Não representa o cancelamento de um waiter individual. Deve ser chamado somente quando a camada
    /// de ownership comprovar que nenhum owner do trabalho compartilhado ainda possui orçamento válido.
    func cancelCanonicalWork() {
        cancelCanonical()
    }
}

/// Dispara o drain quando a rede VOLTA — port do gatilho `NetworkType.CONNECTED` do
/// SyncPendingChecksWorker via `NWPathMonitor`. Single-flight: não sobrepõe drains.
/// (O `BGTaskSyncScheduler` complementa com o gatilho oportunista de background.) Ver port_spec_background §9/§10.
actor OfflineSyncCoordinator {
    private struct CanonicalDrain: Sendable {
        let id: UUID
        let task: Task<DrainResult, Never>
    }

    private let replayer: any OfflineDraining
    private let monitor: any NetworkMonitoring

    private var activeDrain: CanonicalDrain?
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
                if online && !wasOnline { _ = await self?.triggerDrain() }
                wasOnline = online
            }
        }
    }

    func stop() { monitorTask?.cancel(); monitorTask = nil }

    /// Retorna um ticket para o drain canônico atual, iniciando-o somente quando necessário. Vários
    /// triggers compartilham exatamente a mesma task/terminal; não existe lista de continuations.
    func drainTicket() -> OfflineDrainTicket {
        if let activeDrain {
            return ticket(for: activeDrain)
        }

        let id = UUID()
        let replayer = self.replayer
        let task = Task { await replayer.drain() }
        let canonical = CanonicalDrain(id: id, task: task)
        activeDrain = canonical
        drainCount += 1

        // A limpeza não depende de algum waiter permanecer vivo. Há somente um observer bounded por
        // drain e ele não altera nem duplica o resultado compartilhado.
        Task { [weak self] in
            _ = await task.value
            await self?.clearFinishedDrain(id: id)
        }
        return ticket(for: canonical)
    }

    /// Entrada conveniente para foreground/reconexão e para o futuro controller de BGProcessing.
    /// Cancelar esta task de espera não cancela o drain canônico.
    @discardableResult
    func triggerDrain() async -> DrainResult {
        let ticket = drainTicket()
        return await ticket.completion()
    }

    private func ticket(for canonical: CanonicalDrain) -> OfflineDrainTicket {
        OfflineDrainTicket(
            id: canonical.id,
            completionTask: canonical.task,
            cancelCanonical: { canonical.task.cancel() }
        )
    }

    private func clearFinishedDrain(id: UUID) {
        guard activeDrain?.id == id else { return }
        activeDrain = nil
    }
}
