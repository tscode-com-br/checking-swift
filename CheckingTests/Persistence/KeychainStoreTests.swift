import XCTest
@testable import Checking

final class KeychainStoreTests: XCTestCase {
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

    func test_password_roundTrip_survivesNewStoreInstance_andClearWipes() {
        let service = "br.com.tscode.checking.tests.passwords.\(UUID().uuidString)"
        let first = KeychainSecurePasswordStore(service: service)
        defer { first.clearAll() }

        first.setPassword("AB12", "test123")
        XCTAssertEqual(first.getPassword("AB12"), "test123")

        let reopened = KeychainSecurePasswordStore(service: service)
        XCTAssertEqual(reopened.getPassword("AB12"), "test123")
        reopened.clearAll()
        XCTAssertEqual(first.getPassword("AB12"), "")
    }

    func test_password_invalidValue_removesExistingItem() {
        let service = "br.com.tscode.checking.tests.passwords.\(UUID().uuidString)"
        let store = KeychainSecurePasswordStore(service: service)
        defer { store.clearAll() }

        store.setPassword("AB12", "test123")
        store.setPassword("AB12", "x")
        XCTAssertEqual(store.getPassword("AB12"), "")
    }

    func test_cookie_roundTrip_survivesNewStoreInstance_andClearWipes() {
        let service = "br.com.tscode.checking.tests.cookies.\(UUID().uuidString)"
        let url = URL(string: "https://example.invalid/api")!
        let first = KeychainSessionCookieStore(service: service, now: { 1_000 })
        defer { first.clear() }

        saveCurrentResponse(
            first,
            url: url,
            headerFields: ["Set-Cookie": "session=test-value; Path=/; Secure; HttpOnly"])
        XCTAssertEqual(first.cookieHeader(for: url), "session=test-value")

        let reopened = KeychainSessionCookieStore(service: service, now: { 1_000 })
        XCTAssertEqual(reopened.cookieHeader(for: url), "session=test-value")
        reopened.clear()
        XCTAssertNil(first.cookieHeader(for: url))
    }

    func test_cookieResponseFromGenerationBeforeClearIsRejected() {
        let service = "br.com.tscode.checking.tests.cookie-generation.\(UUID().uuidString)"
        let url = URL(string: "https://example.invalid/api")!
        let store = KeychainSessionCookieStore(service: service, now: { 1_000 })
        defer { store.clear() }

        let staleSnapshot = store.requestSnapshot(for: url)
        store.clear()
        store.saveFromResponse(
            url,
            headerFields: ["Set-Cookie": "session=stale-keychain-response; Path=/"],
            requestGeneration: staleSnapshot.generation)

        XCTAssertNil(store.cookieHeader(for: url))
    }

    func test_cookieInvalidationPreservesCurrentCookieAndRejectsOldResponse() {
        let service = "br.com.tscode.checking.tests.cookie-invalidation.\(UUID().uuidString)"
        let url = URL(string: "https://example.invalid/api")!
        let store = KeychainSessionCookieStore(service: service, now: { 1_000 })
        defer { store.clear() }
        saveCurrentResponse(
            store,
            url: url,
            headerFields: ["Set-Cookie": "session=current-keychain-session; Path=/"])
        let staleSnapshot = store.requestSnapshot(for: url)

        store.invalidateInFlightResponses()
        let currentSnapshot = store.requestSnapshot(for: url)
        store.saveFromResponse(
            url,
            headerFields: ["Set-Cookie": "session=stale-keychain-response; Path=/"],
            requestGeneration: staleSnapshot.generation)

        XCTAssertNotEqual(staleSnapshot.generation, currentSnapshot.generation)
        XCTAssertEqual(currentSnapshot.cookieHeader, "session=current-keychain-session")
        XCTAssertEqual(store.cookieHeader(for: url), "session=current-keychain-session")
    }

    func test_offlineQueueRoundTrip_isDurableEncrypted_andClearWipesKeyAndPayload() {
        let service = "br.com.tscode.checking.tests.offline-queue.\(UUID().uuidString)"
        let first = EncryptedOfflineQueueStore(service: service)
        defer { first.clear() }

        let json = #"[{"client_event_id":"private-event","lat":-22.9,"lon":-43.2}]"#
        first.write(json)

        let reopened = EncryptedOfflineQueueStore(service: service)
        XCTAssertEqual(reopened.read(), json)

        let rawKeychain = KeychainStore(service: service)
        let encrypted = rawKeychain.data(for: EncryptedOfflineQueueStore.payloadAccount)
        XCTAssertNotNil(encrypted)
        XCTAssertFalse(String(data: encrypted ?? Data(), encoding: .utf8)?.contains("private-event") == true)

        reopened.clear()
        XCTAssertEqual(first.read(), "")
        XCTAssertNil(rawKeychain.data(for: EncryptedOfflineQueueStore.keyAccount))
        XCTAssertNil(rawKeychain.data(for: EncryptedOfflineQueueStore.payloadAccount))
    }
}
