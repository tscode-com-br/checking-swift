import Foundation

/// Store de senhas por-chave — port de data/local/SecurePasswordStore.kt. Refina o seam de leitura do
/// orquestrador (`SecurePasswordReading`) + escrita. Valida com `isPasswordLengthValid` (via as funções
/// puras multi-conta). §5.
protocol SecurePasswordStore: SecurePasswordReading {
    func setPassword(_ chave: String, _ password: String)
    func removePassword(_ chave: String)
    func getAllPasswords() -> [String: String]
    func clearAll()
}

/// Backend em memória (multi-conta via `resolvePersistedPassword`/`withPersistedPassword`). A persistência
/// no **Keychain** (item por chave, `AfterFirstUnlockThisDeviceOnly`) é um swap deste backend — slice de segurança.
final class InMemorySecurePasswordStore: SecurePasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [String: String] = [:]

    /// "" se chave inválida/ausente ou senha guardada inválida (nunca nil).
    func getPassword(_ chave: String) -> String {
        lock.withLock { resolvePersistedPassword(passwords, chave) }
    }
    func setPassword(_ chave: String, _ password: String) {
        lock.withLock { passwords = withPersistedPassword(passwords, chave, password) }   // inválida → remove
    }
    func removePassword(_ chave: String) {
        lock.withLock { passwords = withPersistedPassword(passwords, chave, nil) }
    }
    func getAllPasswords() -> [String: String] { lock.withLock { passwords } }
    func clearAll() { lock.withLock { passwords.removeAll() } }
}
