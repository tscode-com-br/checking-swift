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
struct SessionCookieRequestSnapshot: Sendable {
    /// Somente em memória: correlaciona a resposta à identidade vigente quando a requisição foi montada.
    /// Não é persistido nem identifica usuário/instalação.
    let generation: UInt64
    let cookieHeader: String?
}

protocol SessionCookieStore: Sendable {
    /// Captura atomicamente o header e a geração para a requisição que está sendo montada.
    func requestSnapshot(for url: URL) -> SessionCookieRequestSnapshot
    /// Interpreta `Set-Cookie` e sobrescreve o host somente se a identidade ainda for a mesma.
    func saveFromResponse(
        _ url: URL,
        headerFields: [String: String],
        requestGeneration: UInt64
    )
    /// Adota (quando presente) o cookie de uma mutação de sessão e avança a geração na mesma seção
    /// crítica. Assim a resposta auth vence respostas comuns anteriores independentemente da ordem em
    /// que os callbacks de rede chegam, mas continua rejeitada após troca/logout de identidade.
    func saveAuthoritativeSessionResponse(
        _ url: URL,
        headerFields: [String: String],
        requestGeneration: UInt64
    )
    /// Invalida respostas já em voo sem remover o cookie que uma operação serial ainda precisa enviar.
    func invalidateInFlightResponses()
    /// Invalida tudo e avança a geração (logout / troca de conta / exclusão).
    func clear()
}

extension SessionCookieStore {
    /// Conveniência para consumidores que apenas leem a sessão atual.
    func cookieHeader(for url: URL) -> String? {
        requestSnapshot(for: url).cookieHeader
    }
}

/// Seam estreito do blob persistente. Produção continua usando `KeychainStore`; a injeção existe
/// para provar deterministicamente a coordenação atômica mesmo quando o Keychain do Simulator não está
/// disponível para um test runner sem assinatura.
protocol SessionCookiePersistence: Sendable {
    func data(for account: String) -> Data?
    @discardableResult func set(_ data: Data, for account: String) -> Bool
    func removeAll()
}

extension KeychainStore: SessionCookiePersistence {}

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
    private var generation: UInt64 = 0
    private let now: @Sendable () -> Int64

    init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.now = now
    }

    func requestSnapshot(for url: URL) -> SessionCookieRequestSnapshot {
        let nowMillis = now()
        return lock.withLock {
            let records = url.host.flatMap { byHost[$0] } ?? []
            return SessionCookieRequestSnapshot(
                generation: generation,
                cookieHeader: SessionCookies.header(records, nowMillis: nowMillis))
        }
    }

    func saveFromResponse(
        _ url: URL,
        headerFields: [String: String],
        requestGeneration: UInt64
    ) {
        guard let host = url.host else { return }
        let records = SessionCookies.parse(headerFields: headerFields, for: url)
        guard !records.isEmpty else { return }          // vazio → no-op (não limpa o existente)
        lock.withLock {
            guard generation == requestGeneration else { return }
            byHost[host] = records                       // OVERWRITE do blob do host
        }
    }

    func saveAuthoritativeSessionResponse(
        _ url: URL,
        headerFields: [String: String],
        requestGeneration: UInt64
    ) {
        guard let host = url.host else { return }
        let records = SessionCookies.parse(headerFields: headerFields, for: url)
        lock.withLock {
            guard generation == requestGeneration else { return }
            if !records.isEmpty { byHost[host] = records }
            generation &+= 1
        }
    }

    func invalidateInFlightResponses() {
        lock.withLock { generation &+= 1 }
    }

    func clear() {
        lock.withLock {
            generation &+= 1
            byHost.removeAll()
        }
    }
}

/// Cookie jar persistente no Keychain. O JSON contém apenas o contrato `CookieRecord` e nunca é logado.
/// Cada host ocupa uma conta separada para preservar o overwrite por host do Android.
final class KeychainSessionCookieStore: SessionCookieStore, @unchecked Sendable {
    static let defaultService = "br.com.tscode.checking.session-cookies"
    private let keychain: any SessionCookiePersistence
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private let now: @Sendable () -> Int64

    init(service: String = defaultService,
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        keychain = KeychainStore(service: service)
        self.now = now
    }

    init(
        persistence: any SessionCookiePersistence,
        now: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000)
        }
    ) {
        keychain = persistence
        self.now = now
    }

    func requestSnapshot(for url: URL) -> SessionCookieRequestSnapshot {
        let nowMillis = now()
        return lock.withLock {
            let records: [CookieRecord]
            if let host = url.host,
               let data = keychain.data(for: host),
               let decoded = try? JSONDecoder().decode([CookieRecord].self, from: data) {
                records = decoded
            } else {
                records = []
            }
            return SessionCookieRequestSnapshot(
                generation: generation,
                cookieHeader: SessionCookies.header(records, nowMillis: nowMillis))
        }
    }

    func saveFromResponse(
        _ url: URL,
        headerFields: [String: String],
        requestGeneration: UInt64
    ) {
        guard let host = url.host else { return }
        let records = SessionCookies.parse(headerFields: headerFields, for: url)
        guard !records.isEmpty, let data = try? JSONEncoder().encode(records) else { return }
        lock.withLock {
            guard generation == requestGeneration else { return }
            _ = keychain.set(data, for: host)
        }
    }

    func saveAuthoritativeSessionResponse(
        _ url: URL,
        headerFields: [String: String],
        requestGeneration: UInt64
    ) {
        guard let host = url.host else { return }
        let records = SessionCookies.parse(headerFields: headerFields, for: url)
        let data = records.isEmpty ? nil : try? JSONEncoder().encode(records)
        lock.withLock {
            guard generation == requestGeneration else { return }
            if let data { _ = keychain.set(data, for: host) }
            generation &+= 1
        }
    }

    func invalidateInFlightResponses() {
        lock.withLock { generation &+= 1 }
    }

    func clear() {
        lock.withLock {
            generation &+= 1
            keychain.removeAll()
        }
    }
}
