import XCTest
@testable import Checking

private final class SessionCookieGenerationURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (HTTPURLResponse, Data)

    private final class HandlerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: Handler?
        private var startedRequests: [URLRequest] = []

        func replace(with handler: Handler?) {
            lock.withLock { self.handler = handler }
        }

        func current() -> Handler? {
            lock.withLock { handler }
        }

        func recordStart(_ request: URLRequest) {
            var recordedRequest = request
            if recordedRequest.httpBody == nil,
               let stream = recordedRequest.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 1_024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(buffer, count: count)
                }
                recordedRequest.httpBodyStream = nil
                recordedRequest.httpBody = body
            }
            lock.withLock { startedRequests.append(recordedRequest) }
        }

        func requests() -> [URLRequest] {
            lock.withLock { startedRequests }
        }

        func clearRequests() {
            lock.withLock { startedRequests.removeAll(keepingCapacity: false) }
        }
    }

    private static let handlerBox = HandlerBox()

    static func install(_ handler: @escaping Handler) {
        handlerBox.replace(with: handler)
    }

    static func reset() {
        handlerBox.replace(with: nil)
        handlerBox.clearRequests()
    }

    static var requests: [URLRequest] { handlerBox.requests() }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.handlerBox.recordStart(request)
        guard let handler = Self.handlerBox.current() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class InMemorySessionCookiePersistence: SessionCookiePersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(for account: String) -> Data? {
        lock.withLock { values[account] }
    }

    func set(_ data: Data, for account: String) -> Bool {
        lock.withLock { values[account] = data }
        return true
    }

    func removeAll() {
        lock.withLock { values.removeAll(keepingCapacity: false) }
    }
}

// Jar de cookie de sessão — filtro de expiração estrito, host-blob, overwrite, clear. §4.
final class CookieStoreTests: XCTestCase {

    override func tearDown() {
        SessionCookieGenerationURLProtocol.reset()
        super.tearDown()
    }

    private func record(_ name: String, _ value: String, expiresAt: Int64, host: String = "tscode.com.br") -> CookieRecord {
        CookieRecord(name: name, value: value, domain: host, path: "/", expiresAt: expiresAt, secure: true, httpOnly: true, hostOnly: true)
    }

    private func saveCurrentResponse(
        _ store: any SessionCookieStore,
        url: URL,
        headerFields: [String: String]
    ) {
        let snapshot = store.requestSnapshot(for: url)
        store.saveFromResponse(
            url,
            headerFields: headerFields,
            requestGeneration: snapshot.generation)
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
        saveCurrentResponse(
            store,
            url: url,
            headerFields: ["Set-Cookie": "session=abc; Path=/; Secure; HttpOnly"])
        XCTAssertEqual(store.cookieHeader(for: url), "session=abc")

        saveCurrentResponse(
            store,
            url: url,
            headerFields: ["Set-Cookie": "session=xyz; Path=/"])   // OVERWRITE
        XCTAssertEqual(store.cookieHeader(for: url), "session=xyz")

        store.clear()
        XCTAssertNil(store.cookieHeader(for: url))
    }

    func test_empty_setcookie_is_noop_keeps_existing() {
        let store = InMemorySessionCookieStore(now: { 1_000 })
        let url = URL(string: "https://tscode.com.br/x")!
        saveCurrentResponse(store, url: url, headerFields: ["Set-Cookie": "session=abc"])
        saveCurrentResponse(store, url: url, headerFields: [:])   // sem Set-Cookie → no-op
        XCTAssertEqual(store.cookieHeader(for: url), "session=abc")
    }

    func test_host_isolation() {
        let store = InMemorySessionCookieStore(now: { 1_000 })
        saveCurrentResponse(
            store,
            url: URL(string: "https://tscode.com.br/x")!,
            headerFields: ["Set-Cookie": "s=1"])
        XCTAssertNil(store.cookieHeader(for: URL(string: "https://other.com/x")!))
    }

    func test_authoritativeResponseWinsAtomicallyWhenOlderOrdinaryResponseArrivesFirst() {
        assertOnInMemoryAndKeychainStores { store, label in
            assertAuthoritativeResponseWins(
                store,
                authoritativeArrivesFirst: false,
                label: label)
        }
    }

    func test_authoritativeResponseWinsAtomicallyWhenOlderOrdinaryResponseArrivesLast() {
        assertOnInMemoryAndKeychainStores { store, label in
            assertAuthoritativeResponseWins(
                store,
                authoritativeArrivesFirst: true,
                label: label)
        }
    }

    func test_authoritativeResponseFromPreviousIdentityIsRejected() {
        assertOnInMemoryAndKeychainStores { store, label in
            let url = URL(string: "https://example.invalid/api/web/auth/login")!
            let previousIdentity = store.requestSnapshot(for: url)

            store.clear()
            let currentIdentity = store.requestSnapshot(for: url)
            store.saveAuthoritativeSessionResponse(
                url,
                headerFields: [
                    "Set-Cookie": "session=previous-identity; Path=/; Secure; HttpOnly",
                ],
                requestGeneration: previousIdentity.generation
            )
            let afterRejectedResponse = store.requestSnapshot(for: url)

            XCTAssertNotEqual(
                previousIdentity.generation,
                currentIdentity.generation,
                label)
            XCTAssertEqual(
                afterRejectedResponse.generation,
                currentIdentity.generation,
                "\(label): uma resposta auth stale também não pode avançar a geração atual")
            XCTAssertNil(afterRejectedResponse.cookieHeader, label)
        }
    }

    func test_authoritativeResponseWithoutSetCookieStillSealsOlderResponses() {
        assertOnInMemoryAndKeychainStores { store, label in
            let url = URL(string: "https://example.invalid/api/web/auth/login")!
            saveCurrentResponse(
                store,
                url: url,
                headerFields: [
                    "Set-Cookie": "session=current-session; Path=/; Secure; HttpOnly",
                ])
            let olderOrdinaryRequest = store.requestSnapshot(for: url)

            store.saveAuthoritativeSessionResponse(
                url,
                headerFields: [:],
                requestGeneration: olderOrdinaryRequest.generation
            )
            let afterAuthResponse = store.requestSnapshot(for: url)
            store.saveFromResponse(
                url,
                headerFields: [
                    "Set-Cookie": "session=late-ordinary; Path=/; Secure; HttpOnly",
                ],
                requestGeneration: olderOrdinaryRequest.generation
            )

            XCTAssertNotEqual(
                afterAuthResponse.generation,
                olderOrdinaryRequest.generation,
                label)
            XCTAssertEqual(
                store.cookieHeader(for: url),
                "session=current-session",
                "\(label): auth sem Set-Cookie preserva o blob atual e rejeita resposta antiga")
        }
    }

    func test_authApiLoginAppliesAuthoritativePolicyAtURLSessionBoundary() async throws {
        let baseURL = URL(string: "https://example.invalid/api/web/")!
        let requestURL = baseURL.appendingPathComponent("auth/login")
        let store = InMemorySessionCookieStore(now: { 1_000 })
        saveCurrentResponse(
            store,
            url: requestURL,
            headerFields: [
                "Set-Cookie": "session=original-session; Path=/; Secure; HttpOnly",
            ])
        let olderOrdinaryRequest = store.requestSnapshot(for: requestURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionCookieGenerationURLProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        SessionCookieGenerationURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "Set-Cookie": "session=authenticated-session; Path=/; Secure; HttpOnly",
                ])!
            let body = Data(#"{"ok":true,"authenticated":true,"has_password":true,"message":"ok"}"#.utf8)
            return (response, body)
        }

        let client = URLSessionHTTPClient(
            baseURL: baseURL,
            xClient: "checking-ios",
            session: session,
            cookieStore: store)
        let api = AuthApiLive(http: client)
        let response = try await api.login(WebPasswordLoginRequest(
            chave: "COOKIE-BOUNDARY",
            senha: "fixture-password"
        ))

        XCTAssertTrue(response.ok)
        store.saveFromResponse(
            requestURL,
            headerFields: [
                "Set-Cookie": "session=late-ordinary-response; Path=/; Secure; HttpOnly",
            ],
            requestGeneration: olderOrdinaryRequest.generation
        )

        let current = store.requestSnapshot(for: requestURL)
        XCTAssertNotEqual(current.generation, olderOrdinaryRequest.generation)
        XCTAssertEqual(current.cookieHeader, "session=authenticated-session")
    }

    func test_authResponseFromPreviousIdentityCannotRestoreCookieAfterClear() async throws {
        try await assertResponseFromPreviousIdentityIsRejected(
            path: "auth/login",
            method: .post,
            staleCookieValue: "stale-auth-response")
    }

    func test_nonAuthResponseFromPreviousIdentityCannotRestoreCookieAfterClear() async throws {
        try await assertResponseFromPreviousIdentityIsRejected(
            path: "check/state",
            method: .get,
            staleCookieValue: "stale-check-response")
    }

    func test_responseFromCurrentIdentityCanPersistCookie() async throws {
        let baseURL = URL(string: "https://example.invalid/api/web/")!
        let store = InMemorySessionCookieStore(now: { 1_000 })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionCookieGenerationURLProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        SessionCookieGenerationURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Set-Cookie": "session=current-response; Path=/; Secure; HttpOnly"])!
            return (response, Data("{}".utf8))
        }

        let client = URLSessionHTTPClient(
            baseURL: baseURL,
            xClient: "checking-ios",
            session: session,
            cookieStore: store)
        _ = try await client.data(for: HTTPRequest(method: .get, path: "check/state"))

        XCTAssertEqual(
            store.cookieHeader(for: baseURL.appendingPathComponent("check/state")),
            "session=current-response")
    }

    func test_clearAdvancesGenerationAndRejectsDirectOldResponse() {
        let store = InMemorySessionCookieStore(now: { 1_000 })
        let url = URL(string: "https://example.invalid/api/web/check/state")!
        let staleSnapshot = store.requestSnapshot(for: url)

        store.clear()
        let currentSnapshot = store.requestSnapshot(for: url)
        store.saveFromResponse(
            url,
            headerFields: ["Set-Cookie": "session=stale-direct; Path=/"],
            requestGeneration: staleSnapshot.generation)

        XCTAssertNotEqual(staleSnapshot.generation, currentSnapshot.generation)
        XCTAssertNil(store.cookieHeader(for: url))
    }

    func test_invalidateInFlightResponsesPreservesCookieAndRejectsOldResponse() {
        let store = InMemorySessionCookieStore(now: { 1_000 })
        let url = URL(string: "https://example.invalid/api/web/auth/logout")!
        saveCurrentResponse(
            store,
            url: url,
            headerFields: ["Set-Cookie": "session=current-session; Path=/"])
        let staleSnapshot = store.requestSnapshot(for: url)

        store.invalidateInFlightResponses()
        let currentSnapshot = store.requestSnapshot(for: url)
        store.saveFromResponse(
            url,
            headerFields: ["Set-Cookie": "session=stale-response; Path=/"],
            requestGeneration: staleSnapshot.generation)

        XCTAssertNotEqual(staleSnapshot.generation, currentSnapshot.generation)
        XCTAssertEqual(currentSnapshot.cookieHeader, "session=current-session")
        XCTAssertEqual(store.cookieHeader(for: url), "session=current-session")
    }

    // MARK: - Dispatch linearizado do motor automático

    func test_guardedCheckRequestsRevokedBeforeResumeNeverReachURLProtocol() async {
        let (client, session) = makeProtocolBackedClient()
        defer { session.invalidateAndCancel() }
        SessionCookieGenerationURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("must-not-dispatch".utf8))
        }
        let repository = CheckRepositoryLive(
            api: CheckApiLive(http: client),
            clock: FixedClock(Date(timeIntervalSince1970: 1_000))
        )
        let revoked = AutomaticActivitiesEffectGuard(operationIsCurrent: { false })

        let match = await repository.matchLocation(
            1.301,
            103.812,
            12,
            effectGuard: revoked
        )
        let submit = await repository.submit(
            chave: "STSM",
            projeto: "P80",
            action: .checkIn,
            local: "Unidade P80",
            informe: .normal,
            eventTime: Date(timeIntervalSince1970: 1_000),
            clientEventId: "guarded-not-dispatched",
            fillForms: true,
            effectGuard: revoked
        )

        guard case .notDispatched = match else {
            return XCTFail("revoked match must be typed notDispatched")
        }
        guard case .notDispatched = submit else {
            return XCTFail("revoked submit must be typed notDispatched")
        }
        XCTAssertTrue(
            SessionCookieGenerationURLProtocol.requests.isEmpty,
            "a URLProtocol start proves the URLSessionDataTask was resumed"
        )
    }

    func test_guardedCheckRequestsPreserveExactWireShapeWhenAuthorized() async throws {
        let (client, session) = makeProtocolBackedClient()
        defer { session.invalidateAndCancel() }
        SessionCookieGenerationURLProtocol.install { request in
            let isMatch = request.url?.path.hasSuffix("/check/location") == true
            let body = isMatch
                ? Data(#"{"matched":true,"resolved_local":"Unidade P80","label":"","status":"matched","message":"","accuracy_meters":12,"accuracy_threshold_meters":50,"minimum_checkout_distance_meters":2000,"nearest_workplace_distance_meters":0}"#.utf8)
                : Data(#"{"ok":true,"state":{"found":true,"chave":"STSM","projeto":"P80","current_action":"checkin","current_local":"Unidade P80","last_checkin_at":"1970-01-01T00:16:40.000Z"}}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        let repository = CheckRepositoryLive(
            api: CheckApiLive(http: client),
            clock: FixedClock(Date(timeIntervalSince1970: 1_000))
        )
        let current = AutomaticActivitiesEffectGuard(operationIsCurrent: { true })

        let match = await repository.matchLocation(
            1.301,
            103.812,
            12,
            effectGuard: current
        )
        let submit = await repository.submit(
            chave: "STSM",
            projeto: "P80",
            action: .checkIn,
            local: "Unidade P80",
            informe: .normal,
            eventTime: Date(timeIntervalSince1970: 1_000),
            clientEventId: "guarded-wire-event",
            fillForms: true,
            effectGuard: current
        )

        guard case .dispatched(let matchResult) = match,
              case .success = matchResult else {
            return XCTFail("authorized match must dispatch and decode")
        }
        guard case .dispatched(let submitResult) = submit,
              case .success = submitResult else {
            return XCTFail("authorized submit must dispatch and decode")
        }
        let requests = SessionCookieGenerationURLProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/web/check/location")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Client"), "checking-ios")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        let matchBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].httpBody))
                as? [String: Any]
        )
        XCTAssertEqual(matchBody["latitude"] as? Double, 1.301)
        XCTAssertEqual(matchBody["longitude"] as? Double, 103.812)
        XCTAssertEqual(matchBody["accuracy_meters"] as? Double, 12)

        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].url?.path, "/api/web/check")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Client"), "checking-ios")
        let submitBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests[1].httpBody))
                as? [String: Any]
        )
        XCTAssertEqual(submitBody["chave"] as? String, "STSM")
        XCTAssertEqual(submitBody["projeto"] as? String, "P80")
        XCTAssertEqual(submitBody["action"] as? String, "checkin")
        XCTAssertEqual(submitBody["local"] as? String, "Unidade P80")
        XCTAssertEqual(submitBody["client_event_id"] as? String, "guarded-wire-event")
        XCTAssertEqual(submitBody["fill_forms"] as? Bool, true)
    }

    func test_guardedCheckRequestsKeep401403And422Taxonomy() async {
        let (client, session) = makeProtocolBackedClient()
        defer { session.invalidateAndCancel() }
        let repository = CheckRepositoryLive(
            api: CheckApiLive(http: client),
            clock: FixedClock(Date(timeIntervalSince1970: 1_000))
        )
        let current = AutomaticActivitiesEffectGuard(operationIsCurrent: { true })

        for status in [401, 403] {
            SessionCookieGenerationURLProtocol.install { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data("unauthorized-fixture".utf8))
            }
            let guarded = await repository.matchLocation(
                1.301,
                103.812,
                12,
                effectGuard: current
            )
            guard case .dispatched(let result) = guarded else {
                XCTFail("HTTP \(status) was dispatched")
                continue
            }
            XCTAssertEqual(result.error, .unauthorized, "HTTP \(status)")
        }

        SessionCookieGenerationURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 422,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("unprocessable-fixture".utf8))
        }
        let guardedSubmit = await repository.submit(
            chave: "STSM",
            projeto: "P80",
            action: .checkIn,
            local: nil,
            informe: .normal,
            eventTime: Date(timeIntervalSince1970: 1_000),
            clientEventId: "guarded-422-event",
            fillForms: true,
            effectGuard: current
        )
        guard case .dispatched(let submitResult) = guardedSubmit else {
            return XCTFail("HTTP 422 was dispatched")
        }
        XCTAssertEqual(
            submitResult.error,
            .http(status: 422, detail: "unprocessable-fixture")
        )
    }

    private func makeProtocolBackedClient() -> (URLSessionHTTPClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionCookieGenerationURLProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        let client = URLSessionHTTPClient(
            baseURL: URL(string: "https://example.invalid/api/web/")!,
            xClient: "checking-ios",
            session: session,
            cookieStore: nil
        )
        return (client, session)
    }

    private func assertOnInMemoryAndKeychainStores(
        _ assertion: (any SessionCookieStore, String) -> Void
    ) {
        assertion(InMemorySessionCookieStore(now: { 1_000 }), "InMemorySessionCookieStore")

        let persistence = InMemorySessionCookiePersistence()
        let keychain = KeychainSessionCookieStore(
            persistence: persistence,
            now: { 1_000 })
        assertion(keychain, "KeychainSessionCookieStore")
    }

    private func assertAuthoritativeResponseWins(
        _ store: any SessionCookieStore,
        authoritativeArrivesFirst: Bool,
        label: String
    ) {
        let url = URL(string: "https://example.invalid/api/web/auth/login")!
        saveCurrentResponse(
            store,
            url: url,
            headerFields: [
                "Set-Cookie": "session=original-session; Path=/; Secure; HttpOnly",
            ])
        // As duas requisições nasceram sob a mesma identidade. A ordem das respostas é o único
        // fator que varia entre os dois testes.
        let ordinaryRequest = store.requestSnapshot(for: url)
        let authoritativeRequest = store.requestSnapshot(for: url)
        XCTAssertEqual(ordinaryRequest.generation, authoritativeRequest.generation, label)

        let saveOrdinary = {
            store.saveFromResponse(
                url,
                headerFields: [
                    "Set-Cookie": "session=older-ordinary; Path=/; Secure; HttpOnly",
                ],
                requestGeneration: ordinaryRequest.generation
            )
        }
        let saveAuthoritative = {
            store.saveAuthoritativeSessionResponse(
                url,
                headerFields: [
                    "Set-Cookie": "session=authoritative-auth; Path=/; Secure; HttpOnly",
                ],
                requestGeneration: authoritativeRequest.generation
            )
        }

        if authoritativeArrivesFirst {
            saveAuthoritative()
            saveOrdinary()
        } else {
            saveOrdinary()
            saveAuthoritative()
        }

        let current = store.requestSnapshot(for: url)
        XCTAssertNotEqual(current.generation, ordinaryRequest.generation, label)
        XCTAssertEqual(current.cookieHeader, "session=authoritative-auth", label)
    }

    private func assertResponseFromPreviousIdentityIsRejected(
        path: String,
        method: HTTPMethod,
        staleCookieValue: String
    ) async throws {
        let baseURL = URL(string: "https://example.invalid/api/web/")!
        let store = InMemorySessionCookieStore(now: { 1_000 })
        let requestURL = baseURL.appendingPathComponent(path)
        saveCurrentResponse(
            store,
            url: requestURL,
            headerFields: ["Set-Cookie": "session=original-session; Path=/; Secure; HttpOnly"])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionCookieGenerationURLProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        SessionCookieGenerationURLProtocol.install { request in
            // A requisição já foi montada com a identidade anterior. A troca acontece antes da resposta.
            store.clear()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "Set-Cookie": "session=\(staleCookieValue); Path=/; Secure; HttpOnly"
                ])!
            return (response, Data("{}".utf8))
        }

        let client = URLSessionHTTPClient(
            baseURL: baseURL,
            xClient: "checking-ios",
            session: session,
            cookieStore: store)

        _ = try await client.data(for: HTTPRequest(method: method, path: path))

        XCTAssertNil(
            store.cookieHeader(for: requestURL),
            "uma resposta da geração anterior não pode repor o cookie depois de clear/replace identity")
    }
}
