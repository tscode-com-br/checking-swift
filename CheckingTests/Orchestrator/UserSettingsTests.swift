import XCTest
@testable import Checking

// Regressão dos fixes da revisão: sanitize da chave (strip + take4) e normalização de projetos.
final class UserSettingsTests: XCTestCase {

    func test_sanitize_strips_non_alphanumeric_and_truncates() {
        XCTAssertEqual(sanitizeSettingsChave("hr70"), "HR70")
        XCTAssertEqual(sanitizeSettingsChave("ab cd"), "ABCD")   // espaço interno removido
        XCTAssertEqual(sanitizeSettingsChave("ABCDE"), "ABCD")   // trunca em 4
        XCTAssertEqual(sanitizeSettingsChave("a-b-c-d"), "ABCD")
    }

    func test_resolve_finds_record_for_noisy_chave() {
        let settings = UserSettings(projects: ["P80"], activeProject: "P80", automaticActivitiesEnabled: true)
        let resolved = resolvePersistedUserSettings(["ABCD": settings], "AB CD")   // sanitiza → "ABCD" → acha o record
        XCTAssertTrue(resolved.automaticActivitiesEnabled)                         // não caiu no default (auto OFF)
        XCTAssertEqual(resolved.projects, ["P80"])
    }

    func test_resolve_normalizes_projects() {
        let settings = UserSettings(projects: [" p80 ", "P80", ""], activeProject: "", automaticActivitiesEnabled: true)
        let resolved = resolvePersistedUserSettings(["ABCD": settings], "ABCD")
        XCTAssertEqual(resolved.projects, ["P80"])               // trim + uppercase + dedup + descarta vazio
        XCTAssertEqual(resolved.activeProject, "P80")            // activeProject vazio → primeiro projeto
    }

    func test_missing_record_returns_defaults_auto_off() {
        let resolved = resolvePersistedUserSettings([:], "HR70")
        XCTAssertFalse(resolved.automaticActivitiesEnabled)
        XCTAssertTrue(resolved.notifyAccident)                   // default true
    }

    func test_empty_json_decodes_to_nil_then_defaults() {
        let map = try? JSONCoding.decoder.decode([String: UserSettings].self, from: Data("".utf8))
        XCTAssertNil(map)
        XCTAssertFalse(resolvePersistedUserSettings(map, "HR70").automaticActivitiesEnabled)   // auto OFF
    }
}
