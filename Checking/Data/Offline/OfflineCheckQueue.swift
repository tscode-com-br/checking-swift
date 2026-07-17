import Foundation

/// Leitura da fila para o replayer (permite fake nos testes do replayer). Ver port_spec_offline_replay.md §8.
protocol PendingCheckQueueing: Sendable {
    func peekAll() async -> [PendingCheckEvent]     // sempre ordem de captura (mais antigo primeiro)
    func remove(_ clientEventId: String) async
    func size() async -> Int
}

/// Fila offline — port de OfflineCheckQueue.kt. `actor` sobre um store SÍNCRONO: sem `await` na seção
/// crítica → atomicidade equivalente ao `Mutex.withLock` do Kotlin (§3.1).
actor OfflineCheckQueue: OfflineCheckQueueing, PendingCheckQueueing {
    static let maxEvents = 200

    private let store: any OfflineQueueStore
    private let scheduler: any SyncScheduler

    init(store: any OfflineQueueStore, scheduler: any SyncScheduler) {
        self.store = store
        self.scheduler = scheduler
    }

    func enqueue(_ event: PendingCheckEvent) {
        var list = readList()
        list.removeAll { $0.clientEventId == event.clientEventId }   // dedup: REPLACE por id (o novo vence)
        list.append(event)
        // cap: mantém os 200 MAIS RECENTES por capturedAtEpochMs; descarta os mais antigos.
        let capped = Array(list.sorted { $0.capturedAtEpochMs < $1.capturedAtEpochMs }.suffix(Self.maxEvents))
        writeList(capped)
        scheduler.scheduleSync()                                     // fora da mutação (mas ainda atômico no actor)
    }

    func peekAll() -> [PendingCheckEvent] {
        readList().sorted { $0.capturedAtEpochMs < $1.capturedAtEpochMs }
    }

    func remove(_ clientEventId: String) {
        writeList(readList().filter { $0.clientEventId != clientEventId })
    }

    func size() -> Int { readList().count }

    /// D6 — wipe LGPD limpa também a fila (GPS preciso). O Android deixava isto para trás.
    func clear() { store.clear() }

    private func readList() -> [PendingCheckEvent] {
        let raw = store.read()
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([PendingCheckEvent].self, from: data)) ?? []   // decode falho → vazio (tolerante)
    }

    private func writeList(_ list: [PendingCheckEvent]) {
        if list.isEmpty { store.write(""); return }                 // vazio → "" (contrato de persistência)
        // Falha de encode → NÃO escreve (mantém o blob anterior), fiel ao Kotlin, que lança antes do store.write.
        guard let data = try? JSONEncoder().encode(list),
              let string = String(data: data, encoding: .utf8) else { return }
        store.write(string)
    }
}
