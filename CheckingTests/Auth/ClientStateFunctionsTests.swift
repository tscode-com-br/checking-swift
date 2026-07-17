import XCTest
@testable import Checking

// Port de ClientStateFunctionsTest.kt (puro). §9.1.
final class ClientStateFunctionsTests: XCTestCase {

    // sanitizeSettingsChave
    func test_sanitize_uppercases_and_strips() { XCTAssertEqual(sanitizeSettingsChave("ab12"), "AB12") }
    func test_sanitize_strips_special() { XCTAssertEqual(sanitizeSettingsChave("AB-12!"), "AB12") }
    func test_sanitize_truncates_to_four() { XCTAssertEqual(sanitizeSettingsChave("ABCDEFGH"), "ABCD") }
    func test_sanitize_nil_empty() {
        XCTAssertEqual(sanitizeSettingsChave(nil), "")
        XCTAssertEqual(sanitizeSettingsChave(""), "")
    }
    func test_sanitize_mixed_case_and_symbols() { XCTAssertEqual(sanitizeSettingsChave("a1-b2#"), "A1B2") }

    // splitNotificationMessage
    func test_split_short_entirely_primary() {
        let r = splitNotificationMessage("Hello"); XCTAssertEqual(r.primary, "Hello"); XCTAssertEqual(r.secondary, "")
    }
    func test_split_nil_returns_empty() {
        let r = splitNotificationMessage(nil); XCTAssertEqual(r.primary, ""); XCTAssertEqual(r.secondary, "")
    }
    func test_split_multiline_first_is_primary() {
        let r = splitNotificationMessage("Line one\nLine two\nLine three")
        XCTAssertEqual(r.primary, "Line one"); XCTAssertEqual(r.secondary, "Line two Line three")
    }
    func test_split_long_single_line_at_word_boundary() {
        let msg = "This is a moderately long message that exceeds the sixty-two character limit"
        let r = splitNotificationMessage(msg)
        XCTAssertLessThanOrEqual(r.primary.count, 62)
        XCTAssertFalse(r.primary.isEmpty)
        XCTAssertFalse(r.secondary.isEmpty)
        XCTAssertEqual((r.primary + " " + r.secondary).trimmingCharacters(in: .whitespaces),
                       msg.trimmingCharacters(in: .whitespaces))   // nada perdido, só dividido
    }
    func test_split_empty_returns_empty() {
        let r = splitNotificationMessage(""); XCTAssertEqual(r.primary, ""); XCTAssertEqual(r.secondary, "")
    }
    func test_split_exactly_at_limit() {
        let msg = String(repeating: "A", count: 62)
        let r = splitNotificationMessage(msg); XCTAssertEqual(r.primary, msg); XCTAssertEqual(r.secondary, "")
    }

    // normalizeProjectValue
    func test_normalizeProject_valid_returns_uppercase() { XCTAssertEqual(normalizeProjectValue("alpha", ["ALPHA", "BETA"], "ALPHA"), "ALPHA") }
    func test_normalizeProject_unknown_returns_fallback() { XCTAssertEqual(normalizeProjectValue("GAMMA", ["ALPHA", "BETA"], "ALPHA"), "ALPHA") }
    func test_normalizeProject_nil_returns_fallback() { XCTAssertEqual(normalizeProjectValue(nil, ["ALPHA"], "ALPHA"), "ALPHA") }

    // isPasswordLengthValid (3..10 + trim)
    func test_passwordLength_valid_range() {
        XCTAssertTrue(isPasswordLengthValid("abc")); XCTAssertTrue(isPasswordLengthValid("abcdefghij"))
    }
    func test_passwordLength_too_short() {
        XCTAssertFalse(isPasswordLengthValid("ab")); XCTAssertFalse(isPasswordLengthValid(nil)); XCTAssertFalse(isPasswordLengthValid(""))
    }
    func test_passwordLength_too_long() { XCTAssertFalse(isPasswordLengthValid("abcdefghijk")) }

    // isPasswordVerificationInputValid (1..10)
    func test_passwordVerification_nonEmpty_upTo10() {
        XCTAssertTrue(isPasswordVerificationInputValid("x")); XCTAssertTrue(isPasswordVerificationInputValid("abcdefghij"))
    }
    func test_passwordVerification_empty_or_nil() {
        XCTAssertFalse(isPasswordVerificationInputValid("")); XCTAssertFalse(isPasswordVerificationInputValid(nil))
    }
}
