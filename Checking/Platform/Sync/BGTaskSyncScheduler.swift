import Foundation
import BackgroundTasks

/// Agenda o drain via `BGProcessingTaskRequest` — port de SyncPendingChecksWorker (WorkManager→BGTask).
/// `requiresNetworkConnectivity = true` ≈ `NetworkType.CONNECTED`. Best-effort: o iOS NÃO garante cadência (§6/§9).
/// Integração: o registro do handler (que chama `coordinator.triggerDrain()`) fica no AppDelegate.
/// O identificador precisa estar em `BGTaskSchedulerPermittedIdentifiers` (Info.plist).
final class BGTaskSyncScheduler: SyncScheduler, @unchecked Sendable {
    static let taskIdentifier = "br.com.tscode.checking.processing"

    private let lock = NSLock()
    private var drainTrigger: (@Sendable () -> Void)?

    /// Liga o drain imediato (late-bind — o coordenador é criado depois da fila). Chamado uma vez no setup.
    func setDrainTrigger(_ trigger: @escaping @Sendable () -> Void) {
        lock.withLock { drainTrigger = trigger }
    }

    func scheduleSync() {
        // BGTask para o caso de background (best-effort).
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)   // falha se não registrado/permitido — best-effort
        // Drain imediato se online (paridade com o WorkManager NetworkType.CONNECTED, que roda já ao conectar).
        // O `triggerDrain` é single-flight e auto-aborta (RETRY) se ainda offline.
        let trigger = lock.withLock { drainTrigger }
        trigger?()
    }
}
