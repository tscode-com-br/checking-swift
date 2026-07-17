import XCTest
@testable import Checking

// Fidelidade de wire dos DTOs de projeto: snake_case, os 8 campos privados de ProjectRow com default
// (não populados pelo GET /projects público — nunca usar em lógica de domínio). §7 do spec de rede.
final class ProjectDTOCodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.decoder.decode(type, from: Data(json.utf8))
    }
    private func encodeToObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(value)) as! [String: Any]
    }

    func test_projectRow_decodes_public_fields_snake_case() throws {
        let json = """
        {"id":1,"name":"P80","country_code":"BR","country_name":"Brasil","timezone_name":"America/Sao_Paulo",
         "timezone_label":"BRT","address":"Rua X","zip_code":"00000-000","forms_enabled":true,
         "transport_enabled":true,"emergency_phone":"190"}
        """
        let row = try decode(ProjectRow.self, json)
        XCTAssertEqual(row.id, 1)
        XCTAssertEqual(row.name, "P80")
        XCTAssertEqual(row.countryCode, "BR")
        XCTAssertEqual(row.zipCode, "00000-000")
        XCTAssertTrue(row.formsEnabled)
        XCTAssertTrue(row.transportEnabled)
    }

    func test_projectRow_private_fields_default_when_absent() throws {
        // Espelha o GET /projects público: os 8 campos privados NÃO vêm — defaults só p/ decode seguro.
        let json = """
        {"id":1,"name":"P80","country_code":"BR","country_name":"Brasil","timezone_name":"America/Sao_Paulo",
         "timezone_label":"BRT","address":"Rua X","zip_code":"00000-000","forms_enabled":true,
         "transport_enabled":true,"emergency_phone":"190"}
        """
        let row = try decode(ProjectRow.self, json)
        XCTAssertEqual(row.twilioAccountSid, "")
        XCTAssertEqual(row.twilioAuthToken, "")
        XCTAssertEqual(row.twilioPhoneNumber, "")
        XCTAssertEqual(row.mobileAdmin, "")
        XCTAssertEqual(row.emailLocalEmergency, "")
        XCTAssertEqual(row.emergencyCallMessage, "")
        XCTAssertEqual(row.inactivityDaysThreshold, 60)
        XCTAssertEqual(row.mixedZoneIntervalMinutes, 30)
    }

    func test_projectRow_private_fields_decode_when_present() throws {
        let json = """
        {"id":1,"name":"P80","country_code":"BR","country_name":"Brasil","timezone_name":"America/Sao_Paulo",
         "timezone_label":"BRT","address":"Rua X","zip_code":"00000-000","forms_enabled":true,
         "transport_enabled":true,"emergency_phone":"190","inactivity_days_threshold":90,"mixed_zone_interval_minutes":15}
        """
        let row = try decode(ProjectRow.self, json)
        XCTAssertEqual(row.inactivityDaysThreshold, 90)
        XCTAssertEqual(row.mixedZoneIntervalMinutes, 15)
    }

    func test_webUserProjectsResponse_snake_case() throws {
        let r = try decode(WebUserProjectsResponse.self, #"{"projects":["P80","P81"],"active_project":"P80"}"#)
        XCTAssertEqual(r.projects, ["P80", "P81"])
        XCTAssertEqual(r.activeProject, "P80")
    }

    func test_webUserProjectsUpdateResponse_snake_case() throws {
        let r = try decode(WebUserProjectsUpdateResponse.self, #"{"projects":["P80"],"active_project":"P80","ok":true,"message":"ok"}"#)
        XCTAssertEqual(r.activeProject, "P80")
        XCTAssertTrue(r.ok)
    }

    func test_webProjectUpdateResponse_snake_case_with_project_field() throws {
        let r = try decode(WebProjectUpdateResponse.self, #"{"projects":["P80","P81"],"active_project":"P81","ok":true,"message":"ok","project":"P81"}"#)
        XCTAssertEqual(r.project, "P81")
        XCTAssertEqual(r.activeProject, "P81")
    }

    func test_userProjectsUpdateRequest_encodes_projects_array() throws {
        let obj = try encodeToObject(WebUserProjectsUpdateRequest(projects: ["P80", "P81"]))
        XCTAssertEqual(obj["projects"] as? [String], ["P80", "P81"])
    }

    func test_projectUpdateRequest_encodes_project_field() throws {
        let obj = try encodeToObject(WebProjectUpdateRequest(project: "P80"))
        XCTAssertEqual(obj["project"] as? String, "P80")
    }
}
