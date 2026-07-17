import XCTest
@testable import Checking

// Fidelidade de wire dos DTOs de acidente: wizard options em camelCase (sem @SerialName no Kotlin,
// AO CONTRÁRIO do resto que é snake_case), requests com null explícito. §7/§10 do spec de rede.
final class AccidentDTOCodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.decoder.decode(type, from: Data(json.utf8))
    }
    private func encodeToObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(value)) as! [String: Any]
    }

    func test_wizard_project_option_decodes_camelCase_no_serial_name() throws {
        let option = try decode(AccidentProjectOption.self, #"{"id":1,"name":"P80"}"#)
        XCTAssertEqual(option.id, 1)
        XCTAssertEqual(option.name, "P80")
    }

    func test_wizard_location_option_decodes_camelCase_including_registered() throws {
        let option = try decode(AccidentLocationOption.self, #"{"id":2,"name":"Portaria","registered":true}"#)
        XCTAssertEqual(option.id, 2)
        XCTAssertTrue(option.registered)
    }

    func test_state_response_decodes_snake_case() throws {
        let json = """
        {"is_active":true,"accident_id":1,"accident_number_label":"AC-1","project_id":9,"project_name":"P80",
         "location_name":"Portaria","description":null,"awareness_status":"open","current_user_report":null,
         "active_accidents":[]}
        """
        let r = try decode(WebAccidentStateResponse.self, json)
        XCTAssertTrue(r.isActive)
        XCTAssertEqual(r.accidentId, 1)
        XCTAssertEqual(r.accidentNumberLabel, "AC-1")
        XCTAssertEqual(r.projectName, "P80")
    }

    func test_active_item_decodes_snake_case_required_fields() throws {
        let json = """
        {"accident_id":1,"accident_number_label":"AC-1","project_id":9,"project_name":"P80",
         "location_name":"Portaria","awareness_status":"open"}
        """
        let item = try decode(WebAccidentActiveItem.self, json)
        XCTAssertEqual(item.accidentId, 1)
        XCTAssertNil(item.description)               // default nil
        XCTAssertNil(item.currentUserReport)          // default nil
    }

    func test_video_upload_response_snake_case() throws {
        let r = try decode(AccidentVideoUploadResponse.self, #"{"video_id":1,"public_url":"u","captured_at":"2026-06-15T01:00:00Z"}"#)
        XCTAssertEqual(r.videoId, 1)
        XCTAssertEqual(r.publicUrl, "u")
    }

    func test_emergency_call_response_snake_case_with_defaults() throws {
        let r = try decode(EmergencyCallResponse.self, #"{"call_number":190,"call_number_label":"190","call_status":"queued","message":"ok"}"#)
        XCTAssertEqual(r.callNumber, 190)
        XCTAssertNil(r.callSid)                       // default nil
    }

    func test_open_request_emits_explicit_null_location_and_description() throws {
        let req = WebAccidentOpenRequest(chave: "STSM", projectId: 1, locationId: nil, customLocationName: nil,
                                         zone: .safety, status: .ok, description: nil)
        let obj = try encodeToObject(req)
        XCTAssertTrue(obj.keys.contains("location_id"))
        XCTAssertTrue(obj["location_id"] is NSNull)
        XCTAssertTrue(obj.keys.contains("custom_location_name"))
        XCTAssertTrue(obj["custom_location_name"] is NSNull)
        XCTAssertTrue(obj.keys.contains("description"))
        XCTAssertTrue(obj["description"] is NSNull)
        XCTAssertEqual(obj["zone"] as? String, "safety")
        XCTAssertEqual(obj["status"] as? String, "ok")
    }

    func test_open_request_emits_values_when_present() throws {
        let req = WebAccidentOpenRequest(chave: "STSM", projectId: 1, locationId: 5, customLocationName: "Portaria X",
                                         zone: .accident, status: .help, description: "Queda")
        let obj = try encodeToObject(req)
        XCTAssertEqual(obj["location_id"] as? Int, 5)
        XCTAssertEqual(obj["custom_location_name"] as? String, "Portaria X")
        XCTAssertEqual(obj["description"] as? String, "Queda")
    }

    func test_acknowledge_request_emits_explicit_null_accidentId() throws {
        let obj = try encodeToObject(WebAccidentAcknowledgeRequest(chave: "STSM", accidentId: nil))
        XCTAssertTrue(obj["accident_id"] is NSNull)
    }

    func test_acknowledge_request_emits_accidentId_when_present() throws {
        let obj = try encodeToObject(WebAccidentAcknowledgeRequest(chave: "STSM", accidentId: 7))
        XCTAssertEqual(obj["accident_id"] as? Int, 7)
    }

    func test_zone_and_status_wire_values() throws {
        XCTAssertEqual(DtoAccidentZone.safety.rawValue, "safety")
        XCTAssertEqual(DtoAccidentZone.accident.rawValue, "accident")
        XCTAssertEqual(DtoAccidentSafetyStatus.ok.rawValue, "ok")
        XCTAssertEqual(DtoAccidentSafetyStatus.help.rawValue, "help")
    }
}
