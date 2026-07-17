import XCTest
@testable import Checking

// Store de senha multi-conta (resolvePersistedPassword/withPersistedPassword). §5.
final class SecurePasswordStoreTests: XCTestCase {

    func test_set_and_get_by_chave() {
        let store = InMemorySecurePasswordStore()
        store.setPassword("HR70", "pw1234")
        XCTAssertEqual(store.getPassword("HR70"), "pw1234")
    }

    func test_get_invalid_chave_returns_empty() {
        let store = InMemorySecurePasswordStore()
        XCTAssertEqual(store.getPassword(""), "")
        XCTAssertEqual(store.getPassword("ABC"), "")     // 3 chars → count != 4 → ""
    }

    func test_set_invalid_length_removes_entry() {
        let store = InMemorySecurePasswordStore()
        store.setPassword("HR70", "pw1234")
        store.setPassword("HR70", "ab")                  // < 3 → remove
        XCTAssertEqual(store.getPassword("HR70"), "")
    }

    func test_multi_account_independent() {
        let store = InMemorySecurePasswordStore()
        store.setPassword("HR70", "pwHR70")
        store.setPassword("ST01", "pwST01")
        XCTAssertEqual(store.getPassword("HR70"), "pwHR70")
        XCTAssertEqual(store.getPassword("ST01"), "pwST01")
    }

    func test_clearAll_wipes() {
        let store = InMemorySecurePasswordStore()
        store.setPassword("HR70", "pw1234")
        store.clearAll()
        XCTAssertEqual(store.getPassword("HR70"), "")
    }
}
