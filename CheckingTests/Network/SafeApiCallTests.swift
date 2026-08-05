import XCTest
@testable import Checking

// Taxonomia de erro EXATA do Android (ApiCallUtils.safeApiCall). Ver port_spec_network_contracts §2.
final class SafeApiCallTests: XCTestCase {

    func test_success_wraps_value() async {
        let r: AppResult<Int> = await safeApiCall { 42 }
        XCTAssertEqual(r.value, 42)
    }
    func test_http_401_maps_unauthorized() async {
        let r: AppResult<Int> = await safeApiCall { throw HTTPError(status: 401, body: "nope") }
        XCTAssertEqual(r.error, .unauthorized)
    }
    func test_http_403_maps_unauthorized() async {
        let r: AppResult<Int> = await safeApiCall { throw HTTPError(status: 403, body: nil) }
        XCTAssertEqual(r.error, .unauthorized)
    }
    func test_http_409_maps_conflict() async {
        let r: AppResult<Int> = await safeApiCall { throw HTTPError(status: 409, body: "already") }
        XCTAssertEqual(r.error, .conflict)
    }
    func test_http_500_maps_http_with_raw_detail() async {
        let r: AppResult<Int> = await safeApiCall { throw HTTPError(status: 500, body: "boom") }
        XCTAssertEqual(r.error, .http(status: 500, detail: "boom"))
    }
    func test_http_422_maps_http_with_nil_detail() async {
        let r: AppResult<Int> = await safeApiCall { throw HTTPError(status: 422, body: nil) }
        XCTAssertEqual(r.error, .http(status: 422, detail: nil))
    }
    func test_other_4xx_preserves_status_and_raw_detail() async {
        let r: AppResult<Int> = await safeApiCall { throw HTTPError(status: 400, body: "bad-request") }
        XCTAssertEqual(r.error, .http(status: 400, detail: "bad-request"))
    }
    func test_urlerror_timeout_maps_network() async {
        let r: AppResult<Int> = await safeApiCall { throw URLError(.timedOut) }
        XCTAssertEqual(r.error, .network)
    }
    func test_urlerror_not_connected_maps_network() async {
        let r: AppResult<Int> = await safeApiCall { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(r.error, .network)
    }
    func test_other_error_maps_unknown() async {
        struct SomeError: Error {}
        let r: AppResult<Int> = await safeApiCall { throw SomeError() }
        XCTAssertEqual(r.error, .unknown(description: nil))
    }
    func test_decoding_error_maps_unknown() async {
        let r: AppResult<Int> = await safeApiCall {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        }
        XCTAssertEqual(r.error, .unknown(description: nil))
    }
    func test_unknown_retains_diagnostic_description() async {
        struct BoomError: Error {}
        let r: AppResult<Int> = await safeApiCall { throw BoomError() }
        guard case .unknown(let description) = r.error else { return XCTFail("expected .unknown") }
        XCTAssertNotNil(description)
        XCTAssertTrue(description!.contains("BoomError"))   // a causa é retida p/ diagnóstico
    }
    func test_cancellation_maps_unknown_not_network() async {
        let r: AppResult<Int> = await safeApiCall { throw CancellationError() }
        XCTAssertEqual(r.error, .unknown(description: nil))   // NÃO .network (evita retry de cancelado)
    }
    func test_urlerror_cancelled_maps_unknown_not_network() async {
        let r: AppResult<Int> = await safeApiCall { throw URLError(.cancelled) }
        XCTAssertEqual(r.error, .unknown(description: nil))
    }
}
