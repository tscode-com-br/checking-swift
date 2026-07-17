import XCTest
@testable import Checking

// Parser de linhas SSE + backoff de reconexão. Ver port_spec_network_contracts §3.
final class SSEParserTests: XCTestCase {

    /// Alimenta o texto linha a linha e coleta os payloads despachados.
    private func feed(_ text: String) -> [String] {
        var parser = SSELineParser()
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let payload = parser.consume(line) { out.append(payload) }
        }
        return out
    }

    func test_single_data_event() {
        XCTAssertEqual(feed("data: hello\n\n"), ["hello"])
    }
    func test_multiline_data_concatenated_with_newline() {
        XCTAssertEqual(feed("data: a\ndata: b\n\n"), ["a\nb"])
    }
    func test_comment_line_ignored() {
        XCTAssertEqual(feed(": keep-alive\n\n"), [])
    }
    func test_event_and_id_discarded_only_data_forwarded() {
        XCTAssertEqual(feed("event: check\nid: 42\ndata: {\"x\":1}\n\n"), ["{\"x\":1}"])
    }
    func test_crlf_terminators_handled() {
        XCTAssertEqual(feed("data: hi\r\n\r\n"), ["hi"])
    }
    func test_two_consecutive_events() {
        XCTAssertEqual(feed("data: one\n\ndata: two\n\n"), ["one", "two"])
    }
    func test_no_leading_space_after_colon() {
        XCTAssertEqual(feed("data:tight\n\n"), ["tight"])
    }
    func test_empty_data_value_dispatches_empty_string() {
        XCTAssertEqual(feed("data:\n\n"), [""])
    }
    func test_blank_line_without_data_dispatches_nothing() {
        XCTAssertEqual(feed("\n\n"), [])
    }

    func test_backoff_sequence_1_to_30_seconds_capped() {
        let delays = [0, 1, 2, 3, 4, 5, 6, 10].map { sseReconnectDelayMillis(attempt: $0) }
        XCTAssertEqual(delays, [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000])
    }
}
