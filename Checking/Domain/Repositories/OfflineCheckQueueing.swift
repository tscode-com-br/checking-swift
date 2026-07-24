import Foundation

/// Enfileiramento offline — contrato consumido pelo motor. A implementação (actor + store cifrado)
/// fica na camada Data. Ver port_spec_offline_replay.md §3.
protocol OfflineCheckQueueing: Sendable {
    func enqueue(_ event: PendingCheckEvent) async
    func clear() async
}
