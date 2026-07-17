import XCTest
@testable import Checking

// Port de OfflineFallbackLocationOptionsTest.kt (função pura). §12.
// Nota: o Kotlin usa assertSame (identidade); LocationOptions no Swift é struct (valor) → igualdade por valor.
final class OfflineFallbackLocationOptionsTests: XCTestCase {

    private let cached = LocationOptions(items: ["Unidade P80"], accuracyThresholdMeters: 45, mixedZoneIntervalMinutes: 20)

    func test_offline_reuses_last_cached() {
        XCTAssertEqual(offlineFallbackLocationOptions(cached, .network), cached)
    }

    func test_offline_no_cache_falls_back_to_defaults() {
        let result = offlineFallbackLocationOptions(nil, .network)
        XCTAssertEqual(result?.accuracyThresholdMeters, DEFAULT_ACCURACY_THRESHOLD_METERS)
        XCTAssertEqual(result?.mixedZoneIntervalMinutes, 0)
        XCTAssertEqual(result?.items, [])
    }

    func test_unauthorized_bails_nil() {
        XCTAssertNil(offlineFallbackLocationOptions(cached, .unauthorized))
    }

    func test_server_error_bails_nil() {
        XCTAssertNil(offlineFallbackLocationOptions(cached, .http(status: 500, detail: "boom")))
        XCTAssertNil(offlineFallbackLocationOptions(cached, .conflict))
        XCTAssertNil(offlineFallbackLocationOptions(cached, .unknown(description: "x")))
    }
}
