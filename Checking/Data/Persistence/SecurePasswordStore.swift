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

/// Backend real do app. Um item Keychain por chave, sem senha em UserDefaults/arquivo/log.
final class KeychainSecurePasswordStore: SecurePasswordStore, @unchecked Sendable {
    static let defaultService = "br.com.tscode.checking.passwords"
    private let keychain: KeychainStore

    init(service: String = defaultService) {
        keychain = KeychainStore(service: service)
    }

    func getPassword(_ chave: String) -> String {
        resolvePersistedPassword(getAllPasswords(), chave)
    }

    func setPassword(_ chave: String, _ password: String) {
        let normalized = withPersistedPassword([:], chave, password)
        guard let valid = normalized[sanitizeSettingsChave(chave)],
              let data = valid.data(using: .utf8) else {
            removePassword(chave)
            return
        }
        _ = keychain.set(data, for: sanitizeSettingsChave(chave))
    }

    func removePassword(_ chave: String) {
        let account = sanitizeSettingsChave(chave)
        guard account.count == 4 else { return }
        keychain.remove(account: account)
    }

    func getAllPasswords() -> [String: String] {
        keychain.allData().reduce(into: [:]) { output, item in
            guard let value = String(data: item.value, encoding: .utf8),
                  isPasswordLengthValid(value), sanitizeSettingsChave(item.key).count == 4 else { return }
            output[item.key] = value
        }
    }

    func clearAll() { keychain.removeAll() }
}
