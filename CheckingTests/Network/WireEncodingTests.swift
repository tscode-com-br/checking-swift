import XCTest
@testable import Checking

// Regressões dos fixes da revisão: encoding de query ('+' → %2B) e frações de segundo no event_time.
final class WireEncodingTests: XCTestCase {

    // MARK: query encoding (§10 — '+' não pode virar espaço no Starlette)

    func test_query_encodes_plus_as_percent2B() {
        XCTAssertEqual(percentEncodedQuery(["chave": "tok+en"]), "chave=tok%2Ben")
    }
    func test_query_encodes_space_and_sub_delims() {
        XCTAssertEqual(percentEncodedQuery(["chave": "a b&c=d"]), "chave=a%20b%26c%3Dd")
    }
    func test_query_plain_worker_code_unchanged() {
        XCTAssertEqual(percentEncodedQuery(["chave": "STSM"]), "chave=STSM")
    }
    func test_query_sorted_by_key_and_nil_when_empty() {
        XCTAssertNil(percentEncodedQuery([:]))
        XCTAssertEqual(percentEncodedQuery(["b": "2", "a": "1"]), "a=1&b=2")
    }

    // MARK: ISOInstant.string — frações só quando não-zero (espelha Instant.toString())

    func test_whole_second_has_no_fraction() {
        XCTAssertEqual(ISOInstant.string(iso("2026-06-15T01:00:00Z")), "2026-06-15T01:00:00Z")
    }
    func test_subsecond_emits_millis() {
        let date = Date(timeIntervalSince1970: 1_780_000_000.123)
        let s = ISOInstant.string(date)
        XCTAssertTrue(s.contains(".123"), "esperava milissegundos em \(s)")
        XCTAssertTrue(s.hasSuffix("Z"))
    }
    func test_string_round_trips_through_parse() {
        let whole = iso("2026-06-15T01:00:00Z")
        XCTAssertEqual(ISOInstant.parse(ISOInstant.string(whole)), whole)
    }
}
