import Foundation
import Security

/// Armazenamento mínimo de blobs no Keychain, isolado por `service` e `account`.
///
/// A acessibilidade `AfterFirstUnlockThisDeviceOnly` permite que cookies/senhas sejam lidos por um wake de
/// background depois do primeiro desbloqueio do aparelho, sem migrar o segredo em backup para outro device.
final class KeychainStore: @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    init(service: String) {
        self.service = service
    }

    func data(for account: String) -> Data? {
        lock.withLock { dataUnlocked(for: account) }
    }

    @discardableResult
    func set(_ data: Data, for account: String) -> Bool {
        lock.withLock {
            let match = baseQuery(account: account)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let update = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
            if update == errSecSuccess { return true }
            guard update == errSecItemNotFound else { return false }

            var add = match
            for (key, value) in attributes { add[key] = value }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
    }

    func remove(account: String) {
        lock.withLock { SecItemDelete(baseQuery(account: account) as CFDictionary) }
    }

    func removeAll() {
        lock.withLock {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ] as CFDictionary)
        }
    }

    /// Retorna os itens do serviço sem expor atributos de outros serviços do app.
    func allData() -> [String: Data] {
        lock.withLock {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else { return [:] }

            let rows: [[String: Any]]
            if let many = result as? [[String: Any]] {
                rows = many
            } else if let one = result as? [String: Any] {
                rows = [one]
            } else {
                return [:]
            }
            return rows.reduce(into: [:]) { output, row in
                guard let account = row[kSecAttrAccount as String] as? String,
                      let data = row[kSecValueData as String] as? Data else { return }
                output[account] = data
            }
        }
    }

    private func dataUnlocked(for account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
