import XCTest
@testable import Checking

final class SignificantLocationStartupPolicyTests: XCTestCase {
    private func json(automatic: Bool = true, activeProject: String = "P80") throws -> String {
        let settings = UserSettings(
            projects: activeProject.isEmpty ? [] : [activeProject],
            activeProject: activeProject,
            automaticActivitiesEnabled: automatic
        )
        let data = try JSONCoding.encoder.encode(["HR70": settings])
        return String(decoding: data, as: UTF8.self)
    }

    func test_startsOnlyWithAccountConsentAutomaticAndProject() throws {
        XCTAssertTrue(SignificantLocationStartupPolicy.shouldStart(
            chave: "HR70", userSettingsJSON: try json(), consentAt: "2026-07-22T00:00:00Z"))
        XCTAssertFalse(SignificantLocationStartupPolicy.shouldStart(
            chave: "HR70", userSettingsJSON: try json(), consentAt: ""))
        XCTAssertFalse(SignificantLocationStartupPolicy.shouldStart(
            chave: "HR70", userSettingsJSON: try json(automatic: false), consentAt: "2026-07-22T00:00:00Z"))
        XCTAssertFalse(SignificantLocationStartupPolicy.shouldStart(
            chave: "HR70", userSettingsJSON: try json(activeProject: ""), consentAt: "2026-07-22T00:00:00Z"))
        XCTAssertFalse(SignificantLocationStartupPolicy.shouldStart(
            chave: "BAD", userSettingsJSON: try json(), consentAt: "2026-07-22T00:00:00Z"))
    }

    func test_malformedSettingsFailClosed() {
        XCTAssertFalse(SignificantLocationStartupPolicy.shouldStart(
            chave: "HR70", userSettingsJSON: "{invalid", consentAt: "2026-07-22T00:00:00Z"))
    }
}
