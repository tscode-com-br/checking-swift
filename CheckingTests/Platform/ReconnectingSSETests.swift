import XCTest
@testable import Checking

// Port de sseFlow (SseDataSource.kt): reconexão só em erro de rede, backoff, fim normal não re-tenta.
final class ReconnectingSSETests: XCTestCase {

    private let url = URL(string: "https://tscode.com.br/api/web/check/stream?chave=HR70")!

    private func collect(_ source: ScriptedSSEConnection, _ sleeper: RecordingSleeper) async -> [String] {
        let stream = reconnectingSSE(url: url, source: source, networkMonitor: FakeNetworkMonitor(online: true), sleeper: sleeper)
        var received: [String] = []
        for await data in stream { received.append(data) }
        return received
    }

    func test_forwards_data_and_reconnects_on_network_error() async {
        let source = ScriptedSSEConnection([
            .dataThenError(["a"], URLError(.networkConnectionLost)),
            .dataThenFinish(["b"]),
        ])
        let sleeper = RecordingSleeper()
        let received = await collect(source, sleeper)
        XCTAssertEqual(received, ["a", "b"])
        XCTAssertEqual(source.connectCount, 2)
        XCTAssertEqual(sleeper.delays, [1000])           // 1 retry após a falha de rede
    }

    func test_http_non_2xx_retries_like_kotlin() async {
        // No Kotlin toda falha de SSE vira IOException (incl. 401/5xx) → retryWhen re-tenta. Espelhamos.
        let source = ScriptedSSEConnection([
            .dataThenError(["a"], HTTPError(status: 500, body: nil)),
            .dataThenFinish(["b"]),
        ])
        let sleeper = RecordingSleeper()
        let received = await collect(source, sleeper)
        XCTAssertEqual(received, ["a", "b"])
        XCTAssertEqual(source.connectCount, 2)           // HTTP não-2xx re-tenta
        XCTAssertEqual(sleeper.delays, [1000])
    }

    func test_non_connection_error_stops_without_retry() async {
        struct LogicError: Error {}
        let source = ScriptedSSEConnection([.dataThenError(["a"], LogicError())])
        let sleeper = RecordingSleeper()
        let received = await collect(source, sleeper)
        XCTAssertEqual(received, ["a"])
        XCTAssertEqual(source.connectCount, 1)           // erro que não é de conexão não re-tenta
        XCTAssertTrue(sleeper.delays.isEmpty)
    }

    func test_backoff_sequence_across_repeated_failures() async {
        let source = ScriptedSSEConnection([
            .dataThenError([], URLError(.timedOut)),
            .dataThenError([], URLError(.timedOut)),
            .dataThenError([], URLError(.timedOut)),
            .dataThenFinish([]),
        ])
        let sleeper = RecordingSleeper()
        _ = await collect(source, sleeper)
        XCTAssertEqual(sleeper.delays, [1000, 2000, 4000])   // cumulativo, não reseta
    }

    func test_normal_close_does_not_retry() async {
        let source = ScriptedSSEConnection([.dataThenFinish(["a"])])
        let sleeper = RecordingSleeper()
        let received = await collect(source, sleeper)
        XCTAssertEqual(received, ["a"])
        XCTAssertEqual(source.connectCount, 1)           // EOF → fim, sem retry
        XCTAssertTrue(sleeper.delays.isEmpty)
    }
}
