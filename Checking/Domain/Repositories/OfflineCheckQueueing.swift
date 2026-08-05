import Foundation

/// Enfileiramento offline — contrato consumido pelo motor. A implementação (actor + store cifrado)
/// fica na camada Data. Ver port_spec_offline_replay.md §3.
protocol OfflineCheckQueueing: Sendable {
    func enqueue(_ event: PendingCheckEvent) async
    /// Avalia o fence no executor que efetivamente possui a fila e lineariza validação + mutação. Cada
    /// conformer implementa esta operação porque uma implementação default não pode manter atomicidade ao
    /// atravessar o `await` de `enqueue`.
    func enqueueIfCurrent(
        _ event: PendingCheckEvent,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> Bool
    func clear() async
}
