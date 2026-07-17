import XCTest
@testable import Checking

// Round-trip do PendingCheckEvent com discriminador achatado "type". Ver port_spec_offline_replay.md §2.
final class PendingCheckEventCodableTests: XCTestCase {

    private func roundTrip(_ event: PendingCheckEvent) throws -> PendingCheckEvent {
        let data = try JSONEncoder().encode(event)
        return try JSONDecoder().decode(PendingCheckEvent.self, from: data)
    }

    func test_raw_round_trips() throws {
        let event = PendingCheckEvent.raw(.init(chave: "HR70", projeto: "P80", capturedAtEpochMs: 100,
                                                clientEventId: "r", latitude: 1.2345, longitude: 103.0, accuracyMeters: 10.0))
        XCTAssertEqual(try roundTrip(event), event)
    }

    func test_decided_round_trips() throws {
        let event = PendingCheckEvent.decided(.init(chave: "HR70", projeto: "P80", capturedAtEpochMs: 200,
                                                    clientEventId: "d", action: "checkout", local: "Zona Mista", informe: "normal"))
        XCTAssertEqual(try roundTrip(event), event)
    }

    func test_decided_with_nil_local_round_trips() throws {
        let event = PendingCheckEvent.decided(.init(chave: "HR70", projeto: "P80", capturedAtEpochMs: 200,
                                                    clientEventId: "d", action: "checkin", local: nil, informe: "retroativo"))
        XCTAssertEqual(try roundTrip(event), event)
    }

    func test_discriminator_is_flattened_type_key() throws {
        let event = PendingCheckEvent.raw(.init(chave: "HR70", projeto: "P80", capturedAtEpochMs: 100,
                                                clientEventId: "r", latitude: 1.2, longitude: 103.0, accuracyMeters: 12.5))
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "raw")          // achatado no mesmo nível dos campos
        XCTAssertEqual(obj["clientEventId"] as? String, "r")
        XCTAssertEqual(obj["latitude"] as? Double, 1.2)
        XCTAssertEqual(obj["accuracyMeters"] as? Double, 12.5)
    }

    func test_nil_optional_is_omitted_and_reads_back_nil() throws {
        // Blob INTERNO (round-trip local): opcional nil é omitido e volta nil — auto-consistente.
        let event = PendingCheckEvent.raw(.init(chave: "HR70", projeto: "P80", capturedAtEpochMs: 100,
                                                clientEventId: "r", latitude: 1.2, longitude: 103.0, accuracyMeters: nil))
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
        XCTAssertNil(obj["accuracyMeters"])                    // chave ausente (omitido)
        XCTAssertEqual(try roundTrip(event), event)            // ...mas volta idêntico
    }

    func test_list_round_trips_both_variants() throws {
        let events: [PendingCheckEvent] = [
            .raw(.init(chave: "HR70", projeto: "P80", capturedAtEpochMs: 100, clientEventId: "r",
                       latitude: 1.2345, longitude: 103.0, accuracyMeters: 10.0)),
            .decided(.init(chave: "HR70", projeto: "P80", capturedAtEpochMs: 200, clientEventId: "d",
                           action: "checkout", local: "Zona Mista", informe: "normal")),
        ]
        let data = try JSONEncoder().encode(events)
        XCTAssertEqual(try JSONDecoder().decode([PendingCheckEvent].self, from: data), events)
    }

    func test_unknown_type_throws() {
        let json = #"{"type":"mystery","chave":"HR70"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PendingCheckEvent.self, from: Data(json.utf8)))
    }

    func test_common_fields_read_through_both_variants() {
        let raw = PendingCheckEvent.raw(.init(chave: "A", projeto: "P", capturedAtEpochMs: 7, clientEventId: "id-r",
                                              latitude: 0, longitude: 0, accuracyMeters: nil))
        XCTAssertEqual(raw.chave, "A"); XCTAssertEqual(raw.capturedAtEpochMs, 7); XCTAssertEqual(raw.clientEventId, "id-r")
        let decided = PendingCheckEvent.decided(.init(chave: "B", projeto: "Q", capturedAtEpochMs: 9, clientEventId: "id-d",
                                                      action: "checkin", local: nil, informe: "normal"))
        XCTAssertEqual(decided.projeto, "Q"); XCTAssertEqual(decided.capturedAtEpochMs, 9); XCTAssertEqual(decided.clientEventId, "id-d")
    }
}
