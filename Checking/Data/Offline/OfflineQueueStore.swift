import Foundation
import CryptoKit

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

/// Backend em memória usado somente por testes e previews.
final class InMemoryOfflineQueueStore: OfflineQueueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func read() -> String { lock.withLock { value } }
    func write(_ json: String) { lock.withLock { value = json } }
    func clear() { lock.withLock { value = "" } }
}

/// Persistência de produção da fila offline. O JSON nunca é gravado em texto aberto: uma chave AES-256
/// aleatória e o blob AES-GCM ficam em itens distintos do Keychain, ambos disponíveis somente depois do
/// primeiro desbloqueio e vinculados ao aparelho (`AfterFirstUnlockThisDeviceOnly`).
///
/// O store permanece síncrono para preservar a seção crítica read→mutate→write do actor `OfflineCheckQueue`.
final class EncryptedOfflineQueueStore: OfflineQueueStore, @unchecked Sendable {
    static let keyAccount = "aes-256-key"
    static let payloadAccount = "pending-checks"

    private let keychain: KeychainStore
    private let lock = NSLock()

    init(service: String = "\(Bundle.main.bundleIdentifier ?? "br.com.tscode.checking").offline-queue") {
        keychain = KeychainStore(service: service)
    }

    func read() -> String {
        lock.withLock {
            guard let keyData = keychain.data(for: Self.keyAccount),
                  let combined = keychain.data(for: Self.payloadAccount),
                  let box = try? AES.GCM.SealedBox(combined: combined),
                  let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)) else {
                return ""
            }
            return String(data: plaintext, encoding: .utf8) ?? ""
        }
    }

    func write(_ json: String) {
        lock.withLock {
            guard !json.isEmpty else {
                keychain.remove(account: Self.payloadAccount)
                return
            }
            guard let plaintext = json.data(using: .utf8),
                  let key = encryptionKey(),
                  let combined = try? AES.GCM.seal(plaintext, using: key).combined else { return }
            _ = keychain.set(combined, for: Self.payloadAccount)
        }
    }

    /// Wipe LGPD: remove inclusive a chave, tornando qualquer cópia residual do payload indecifrável.
    func clear() {
        lock.withLock { keychain.removeAll() }
    }

    private func encryptionKey() -> SymmetricKey? {
        if let stored = keychain.data(for: Self.keyAccount) {
            return SymmetricKey(data: stored)
        }
        let generated = SymmetricKey(size: .bits256)
        let data = generated.withUnsafeBytes { Data($0) }
        return keychain.set(data, for: Self.keyAccount) ? generated : nil
    }
}
