import Foundation

/// Store do blob da fila offline — port de OfflineQueueStore.kt. **SÍNCRONO de propósito** (§3.1):
/// mantém a seção crítica do `actor` sem `await`, garantindo atomicidade read→mutate→write como o Mutex.
protocol OfflineQueueStore: Sendable {
    func read() -> String
    func write(_ json: String)
    func clear()               // D6 — o Android NÃO tem clear(); o iOS DEVE (wipe LGPD limpa a fila)
}
extension OfflineQueueStore {
    func clear() { write("") }
}

/// Agenda o drain (BGTask em produção; no-op em teste). Port de SyncScheduler/SyncPendingChecksWorker.
protocol SyncScheduler: Sendable {
    func scheduleSync()
}
struct NoopSyncScheduler: SyncScheduler {
    func scheduleSync() {}
}

/// Backend em memória. A persistência CIFRADA (Keychain + CryptoKit AES-GCM, `AfterFirstUnlockThisDeviceOnly`,
/// com `clear()` do D6) é um swap deste backend — fica no slice de segurança (§4). A lógica da fila é final aqui.
final class InMemoryOfflineQueueStore: OfflineQueueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func read() -> String { lock.withLock { value } }
    func write(_ json: String) { lock.withLock { value = json } }
    func clear() { lock.withLock { value = "" } }
}
