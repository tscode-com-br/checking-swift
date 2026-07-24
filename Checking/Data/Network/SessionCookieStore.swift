import Foundation

/// Cookie de sessão persistido — campos EXATOS do `CookieJson` do Android (PersistentCookieJar).
/// `expiresAt` em epoch millis. Ver port_spec_network_contracts §4.
struct CookieRecord: Codable, Equatable, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresAt: Int64
    let secure: Bool
    let httpOnly: Bool
    let hostOnly: Bool
}

/// Jar de cookies de sessão — port de PersistentCookieJar.kt.
/// Um blob por `host`, overwrite na resposta, filtra `expiresAt > now` na leitura, `clear()` no logout.
protocol SessionCookieStore: Sendable {
    /// Header `Cookie` para a requisição (nil se não houver cookie ativo p/ o host).
    func cookieHeader(for url: URL) -> String?
    /// Interpreta `Set-Cookie` da resposta e sobrescreve o blob do host.
    func saveFromResponse(_ url: URL, headerFields: [String: String])
    /// Invalida tudo (logout / troca de conta / exclusão).
    func clear()
}

/// Lógica pura de cookie (testável sem URLSession).
enum SessionCookies {
    /// `HttpDate.MAX_DATE` do OkHttp — o `expiresAt` de um cookie de sessão (e o teto de clamp).
    static let httpDateMaxMillis: Int64 = 253_402_300_799_999

    /// Interpreta `Set-Cookie` via `HTTPCookie`, normalizando domínio/host-only e o `expiresAt` como o OkHttp.
    static func parse(headerFields: [String: String], for url: URL) -> [CookieRecord] {
        HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url).map { cookie in
            let hostOnly = !cookie.domain.hasPrefix(".")            // sem atributo Domain → host-only
            let domain = hostOnly ? cookie.domain : String(cookie.domain.dropFirst())
            // Cookie de sessão (sem expiração) → HttpDate.MAX_DATE (não Long.MAX). Clamp fiel ao OkHttp:
            // > MAX_DATE → MAX_DATE; <= 0 → Long.MIN (já expirado, filtrado na leitura).
            let raw = cookie.expiresDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? httpDateMaxMillis
            let expiresAt: Int64 = raw > httpDateMaxMillis ? httpDateMaxMillis : (raw <= 0 ? Int64.min : raw)
            return CookieRecord(name: cookie.name, value: cookie.value, domain: domain, path: cookie.path,
                                expiresAt: expiresAt, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly, hostOnly: hostOnly)
        }
    }

    /// Filtra expirados — `expiresAt > now` ESTRITO (um cookie com `expiresAt == now` é excluído).
    static func active(_ records: [CookieRecord], nowMillis: Int64) -> [CookieRecord] {
        records.filter { $0.expiresAt > nowMillis }
    }

    /// Monta "name=value; name2=value2" (nil se vazio). Sem filtro de path/secure — igual ao Android.
    static func header(_ records: [CookieRecord], nowMillis: Int64) -> String? {
        let active = active(records, nowMillis: nowMillis)
        guard !active.isEmpty else { return nil }
        return active.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

/// Backend em memória. A persistência CIFRADA (Keychain/arquivo, legível em background) é um swap deste
/// backend — fica no slice de segurança/persistência (§4). A lógica de wire (parse/expiração/host) é final aqui.
final class InMemorySessionCookieStore: SessionCookieStore, @unchecked Sendable {
    private let lock = NSLock()
    private var byHost: [String: [CookieRecord]] = [:]
    private let now: @Sendable () -> Int64

    init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.now = now
    }

    func cookieHeader(for url: URL) -> String? {
        guard let host = url.host else { return nil }
        lock.lock(); let records = byHost[host] ?? []; lock.unlock()
        return SessionCookies.header(records, nowMillis: now())
    }

    func saveFromResponse(_ url: URL, headerFields: [String: String]) {
        guard let host = url.host else { return }
        let records = SessionCookies.parse(headerFields: headerFields, for: url)
        guard !records.isEmpty else { return }          // vazio → no-op (não limpa o existente)
        lock.lock(); byHost[host] = records; lock.unlock() // OVERWRITE do blob do host
    }

    func clear() {
        lock.lock(); byHost.removeAll(); lock.unlock()
    }
}

/// Cookie jar persistente no Keychain. O JSON contém apenas o contrato `CookieRecord` e nunca é logado.
/// Cada host ocupa uma conta separada para preservar o overwrite por host do Android.
final class KeychainSessionCookieStore: SessionCookieStore, @unchecked Sendable {
    static let defaultService = "br.com.tscode.checking.session-cookies"
    private let keychain: KeychainStore
    private let now: @Sendable () -> Int64

    init(service: String = defaultService,
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        keychain = KeychainStore(service: service)
        self.now = now
    }

    func cookieHeader(for url: URL) -> String? {
        guard let host = url.host,
              let data = keychain.data(for: host),
              let records = try? JSONDecoder().decode([CookieRecord].self, from: data) else { return nil }
        return SessionCookies.header(records, nowMillis: now())
    }

    func saveFromResponse(_ url: URL, headerFields: [String: String]) {
        guard let host = url.host else { return }
        let records = SessionCookies.parse(headerFields: headerFields, for: url)
        guard !records.isEmpty, let data = try? JSONEncoder().encode(records) else { return }
        _ = keychain.set(data, for: host)
    }

    func clear() { keychain.removeAll() }
}
