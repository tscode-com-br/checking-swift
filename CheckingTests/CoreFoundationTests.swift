import XCTest
@testable import Checking

/// Smoke test da fundação — prova que o harness de testes compila e roda (a "rede" para os ~256
/// testes portados das specs). Substituir/expandir conforme cada camada é implementada.
final class CoreFoundationTests: XCTestCase {

    func test_appResult_map_propagatesSuccess() {
        let result = AppResult<Int>.success(2).map { $0 * 21 }
        XCTAssertEqual(result.value, 42)
    }

    func test_appResult_map_propagatesFailure() {
        let result = AppResult<Int>.failure(.unauthorized).map { $0 * 2 }
        XCTAssertEqual(result.error, .unauthorized)
    }

    func test_apiError_equatable() {
        XCTAssertEqual(ApiError.http(status: 422, detail: "x"), .http(status: 422, detail: "x"))
        XCTAssertNotEqual(ApiError.network, .unknown(description: nil))
        // `unknown` compara por tipo — a descrição (diagnóstica) não influencia igualdade.
        XCTAssertEqual(ApiError.unknown(description: "a"), .unknown(description: "b"))
    }

    func test_apiConfig_baseURL_matchesAndroid() {
        XCTAssertEqual(ApiConfig.preview.baseURL.absoluteString, "https://tscode.com.br/api/web/")
    }

    func test_fixedClock_returnsInjectedInstant() {
        let instant = Date(timeIntervalSince1970: 1_781_863_200) // 2026-06-19T10:00:00Z
        XCTAssertEqual(FixedClock(instant).now(), instant)
    }
}
