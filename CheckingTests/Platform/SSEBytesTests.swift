import XCTest
@testable import Checking

// Regressão do fix HIGH: o split de bytes SSE PRESERVA linhas em branco (o `.lines` da Foundation as
// descarta, e é a linha em branco que despacha o evento). Ver ReconnectingSSE / URLSessionSSEConnection.
final class SSEBytesTests: XCTestCase {

    private func payloads(_ text: String) -> [String] {
        var parser = SSELineParser()
        var out: [String] = []
        for line in splitSSEBytesIntoLines(Array(text.utf8)) {
            if let payload = parser.consume(line) { out.append(payload) }
        }
        return out
    }

    func test_split_preserves_blank_line() {
        XCTAssertEqual(splitSSEBytesIntoLines(Array("data: x\n\n".utf8)), ["data: x", ""])
    }

    func test_single_event_dispatched() {
        XCTAssertEqual(payloads("data: hello\n\n"), ["hello"])
    }

    func test_event_and_id_discarded_only_data() {
        XCTAssertEqual(payloads("event: check\nid: 42\ndata: {\"x\":1}\n\n"), ["{\"x\":1}"])
    }

    func test_multiline_data_concatenated() {
        XCTAssertEqual(payloads("data: a\ndata: b\n\n"), ["a\nb"])
    }

    func test_crlf_line_endings() {
        XCTAssertEqual(payloads("data: hi\r\n\r\n"), ["hi"])   // o parser tira o \r final
    }

    func test_two_events() {
        XCTAssertEqual(payloads("data: one\n\ndata: two\n\n"), ["one", "two"])
    }
}
