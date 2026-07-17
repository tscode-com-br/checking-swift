import XCTest
@testable import Checking

// Jar de cookie de sessão — filtro de expiração estrito, host-blob, overwrite, clear. §4.
final class CookieStoreTests: XCTestCase {

    private func record(_ name: String, _ value: String, expiresAt: Int64, host: String = "tscode.com.br") -> CookieRecord {
        CookieRecord(name: name, value: value, domain: host, path: "/", expiresAt: expiresAt, secure: true, httpOnly: true, hostOnly: true)
    }

    func test_active_filters_expired_strictly() {
        let now: Int64 = 1_000_000
        let records = [
            record("a", "1", expiresAt: now + 1),   // ativo
            record("b", "2", expiresAt: now),       // == now → EXCLUÍDO (estrito >)
            record("c", "3", expiresAt: now - 1),   // expirado
        ]
        XCTAssertEqual(SessionCookies.active(records, nowMillis: now).map(\.name), ["a"])
    }

    func test_header_builds_pairs_and_is_nil_when_all_expired() {
        let now: Int64 = 1_000
        XCTAssertEqual(SessionCookies.header([record("s", "abc", expiresAt: now + 1), record("t", "def", expiresAt: now + 1)], nowMillis: now), "s=abc; t=def")
        XCTAssertNil(SessionCookies.header([record("s", "abc", expiresAt: now - 1)], nowMillis: now))
    }

    func test_parse_setcookie_session_cookie_never_expires_within_session() {
        let url = URL(string: "https://tscode.com.br/api/web/check/state")!
        let parsed = SessionCookies.parse(headerFields: ["Set-Cookie": "session=abc; Path=/; Secure; HttpOnly"], for: url)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "session")
        XCTAssertEqual(parsed.first?.value, "abc")
        XCTAssertEqual(parsed.first?.hostOnly, true)                          // sem atributo Domain
        XCTAssertEqual(parsed.first?.expiresAt, SessionCookies.httpDateMaxMillis) // sessão → HttpDate.MAX_DATE (não Long.MAX)
    }

    func test_store_save_load_overwrite_clear() {
        let store = InMemorySessionCookieStore(now: { 1_000 })
        let url = URL(string: "https://tscode.com.br/api/web/check")!
        store.saveFromResponse(url, headerFields: ["Set-Cookie": "session=abc; Path=/; Secure; HttpOnly"])
        XCTAssertEqual(store.cookieHeader(for: url), "session=abc")

        store.saveFromResponse(url, headerFields: ["Set-Cookie": "session=xyz; Path=/"])   // OVERWRITE
        XCTAssertEqual(store.cookieHeader(for: url), "session=xyz")

        store.clear()
        XCTAssertNil(store.cookieHeader(for: url))
    }

    func test_empty_setcookie_is_noop_keeps_existing() {
        let store = InMemorySessionCookieStore(now: { 1_000 })
        let url = URL(string: "https://tscode.com.br/x")!
        store.saveFromResponse(url, headerFields: ["Set-Cookie": "session=abc"])
        store.saveFromResponse(url, headerFields: [:])   // sem Set-Cookie → no-op
        XCTAssertEqual(store.cookieHeader(for: url), "session=abc")
    }

    func test_host_isolation() {
        let store = InMemorySessionCookieStore(now: { 1_000 })
        store.saveFromResponse(URL(string: "https://tscode.com.br/x")!, headerFields: ["Set-Cookie": "s=1"])
        XCTAssertNil(store.cookieHeader(for: URL(string: "https://other.com/x")!))
    }
}
