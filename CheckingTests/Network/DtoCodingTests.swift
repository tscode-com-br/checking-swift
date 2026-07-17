import XCTest
@testable import Checking

// Fidelidade de wire: encode com null explícito (§8) + decode com defaults/gotchas (§10).
final class DtoCodingTests: XCTestCase {

    private func encodeToObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONCoding.encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: encode — null explícito

    func test_submit_request_emits_explicit_null_local_and_all_fields() throws {
        let req = WebCheckSubmitRequest(chave: "K", projeto: "P80", action: .checkin, local: nil, informe: .normal,
                                        eventTime: "2026-06-15T01:00:00Z", clientEventId: "cid", fillForms: true)
        let obj = try encodeToObject(req)
        XCTAssertTrue(obj.keys.contains("local"))
        XCTAssertTrue(obj["local"] is NSNull)                    // presente + null (não omitido)
        XCTAssertEqual(obj["fill_forms"] as? Bool, true)
        XCTAssertEqual(obj["event_time"] as? String, "2026-06-15T01:00:00Z")
        XCTAssertEqual(obj["client_event_id"] as? String, "cid")
        XCTAssertEqual(obj["action"] as? String, "checkin")
        XCTAssertEqual(obj["informe"] as? String, "normal")
    }

    func test_submit_request_emits_local_when_present() throws {
        let req = WebCheckSubmitRequest(chave: "K", projeto: "P80", action: .checkout, local: "Unidade P80", informe: .retroativo,
                                        eventTime: "t", clientEventId: "c", fillForms: false)
        let obj = try encodeToObject(req)
        XCTAssertEqual(obj["local"] as? String, "Unidade P80")
        XCTAssertEqual(obj["action"] as? String, "checkout")
        XCTAssertEqual(obj["informe"] as? String, "retroativo")
        XCTAssertEqual(obj["fill_forms"] as? Bool, false)
    }

    func test_locationmatch_request_emits_explicit_null_accuracy() throws {
        let obj = try encodeToObject(WebLocationMatchRequest(latitude: 1.3, longitude: 103.8, accuracyMeters: nil))
        XCTAssertTrue(obj.keys.contains("accuracy_meters"))
        XCTAssertTrue(obj["accuracy_meters"] is NSNull)
        XCTAssertEqual(obj["latitude"] as? Double, 1.3)
        XCTAssertEqual(obj["longitude"] as? Double, 103.8)
    }

    func test_locationmatch_request_emits_accuracy_when_present() throws {
        let obj = try encodeToObject(WebLocationMatchRequest(latitude: 1.3, longitude: 103.8, accuracyMeters: 12.5))
        XCTAssertEqual(obj["accuracy_meters"] as? Double, 12.5)
    }

    // MARK: decode — defaults / gotchas

    func test_submit_response_defaults_when_absent() throws {
        let r = try decode(MobileSubmitResponse.self, #"{"ok":true,"state":{"found":true,"chave":"K"}}"#)
        XCTAssertTrue(r.ok)
        XCTAssertFalse(r.duplicate)
        XCTAssertTrue(r.queuedForms)          // Bool, default true (§10)
        XCTAssertTrue(r.workerHealthy)
        XCTAssertEqual(r.message, "")
    }

    func test_submit_response_queued_forms_is_bool_false() throws {
        let r = try decode(MobileSubmitResponse.self, #"{"ok":true,"queued_forms":false,"worker_healthy":false,"state":{"found":false,"chave":"K"}}"#)
        XCTAssertFalse(r.queuedForms)
        XCTAssertFalse(r.workerHealthy)
    }

    func test_location_match_response_int_vs_double_distinct() throws {
        let json = """
        {"matched":true,"resolved_local":"Unidade P80","label":"Unidade P80","status":"matched","message":"",
         "accuracy_meters":12.5,"accuracy_threshold_meters":50,"minimum_checkout_distance_meters":2000,
         "nearest_workplace_distance_meters":null}
        """
        let r = try decode(WebLocationMatchResponse.self, json)
        XCTAssertEqual(r.accuracyThresholdMeters, 50)          // Int
        XCTAssertEqual(r.minimumCheckoutDistanceMeters, 2000)  // Int
        XCTAssertEqual(r.accuracyMeters, 12.5)                 // Double
        XCTAssertNil(r.nearestWorkplaceDistanceMeters)
        XCTAssertEqual(r.status, .matched)
        XCTAssertEqual(r.resolvedLocal, "Unidade P80")
    }

    func test_all_location_match_status_wire_values() throws {
        let cases: [(String, DtoLocationMatchStatus)] = [
            ("matched", .matched), ("accuracy_too_low", .accuracyTooLow), ("not_in_known_location", .notInKnownLocation),
            ("outside_workplace", .outsideWorkplace), ("no_known_locations", .noKnownLocations),
        ]
        for (wire, expected) in cases {
            let json = """
            {"matched":false,"label":"","status":"\(wire)","message":"","accuracy_threshold_meters":50,"minimum_checkout_distance_meters":2000}
            """
            let r = try decode(WebLocationMatchResponse.self, json)
            XCTAssertEqual(r.status, expected, "wire \(wire)")
        }
    }

    func test_ignores_unknown_keys() throws {
        let r = try decode(WebLocationOptionsResponse.self,
            #"{"items":["A"],"location_accuracy_threshold_meters":50,"mixed_zone_interval_minutes":15,"extra_unknown":123}"#)
        XCTAssertEqual(r.items, ["A"])
        XCTAssertEqual(r.mixedZoneIntervalMinutes, 15)
    }

    func test_history_list_defaults_empty_items_when_absent() throws {
        let r = try decode(WebCheckHistoryListResponseDto.self, "{}")
        XCTAssertTrue(r.items.isEmpty)
    }

    func test_accented_literal_round_trips_utf8() throws {
        let r = try decode(WebCheckHistoryListResponseDto.self,
            #"{"items":[{"action":"checkin","projeto":"P80","local":"Área X","time":"2026-06-15T01:00:00Z","informe":"normal"}]}"#)
        XCTAssertEqual(r.items.first?.local, "Área X")
    }
}
