import XCTest
@testable import Checking

// D2 — inquiryScenario recebe o flag REAL de automático (nunca true/userProjects!=null hardcoded). §14.
final class InquiryScenarioTests: XCTestCase {

    private func state(currentActionIsCheckin: Bool, autoCheckinStatus: [Int: AutoCheckinStatus] = [:]) -> AccidentUiState {
        var s = AccidentUiState()
        s.currentActionIsCheckin = currentActionIsCheckin
        s.autoCheckinStatus = autoCheckinStatus
        return s
    }

    func test_already_reported_yields_postReport() {
        let accident = accidentItem(1, projectName: "P80", reportedAt: Date())
        let scenario = state(currentActionIsCheckin: false).inquiryScenario(accident, userActiveProject: "P80", automaticActivitiesEnabled: true)
        XCTAssertEqual(scenario, .postReport)
    }

    func test_checkin_same_project_shows_zone_buttons() {
        let accident = accidentItem(1, projectName: "P80")
        let scenario = state(currentActionIsCheckin: true).inquiryScenario(accident, userActiveProject: "P80", automaticActivitiesEnabled: true)
        XCTAssertEqual(scenario, .showZoneButtons)
    }

    func test_checkin_different_project_hides_card() {
        let accident = accidentItem(1, projectName: "P80")
        let scenario = state(currentActionIsCheckin: true).inquiryScenario(accident, userActiveProject: "OTHER", automaticActivitiesEnabled: true)
        XCTAssertEqual(scenario, .hideCard)
    }

    func test_checkout_auto_off_yields_checkedOutAutoOff() {
        let accident = accidentItem(1)
        let scenario = state(currentActionIsCheckin: false).inquiryScenario(accident, userActiveProject: "P80", automaticActivitiesEnabled: false)
        XCTAssertEqual(scenario, .checkedOutAutoOff)
    }

    func test_checkout_auto_on_no_status_yields_triggerAutoCheckin() {
        let accident = accidentItem(1)
        let scenario = state(currentActionIsCheckin: false).inquiryScenario(accident, userActiveProject: "P80", automaticActivitiesEnabled: true)
        XCTAssertEqual(scenario, .triggerAutoCheckin)
    }

    func test_checkout_auto_on_pending_yields_autoCheckinRunning() {
        let accident = accidentItem(1)
        let scenario = state(currentActionIsCheckin: false, autoCheckinStatus: [1: .pending])
            .inquiryScenario(accident, userActiveProject: "P80", automaticActivitiesEnabled: true)
        XCTAssertEqual(scenario, .autoCheckinRunning)
    }

    func test_checkout_auto_on_success_yields_showZoneButtons() {
        let accident = accidentItem(1)
        let scenario = state(currentActionIsCheckin: false, autoCheckinStatus: [1: .success])
            .inquiryScenario(accident, userActiveProject: "P80", automaticActivitiesEnabled: true)
        XCTAssertEqual(scenario, .showZoneButtons)
    }

    func test_checkout_auto_on_failed_yields_autoCheckinFailed() {
        let accident = accidentItem(1)
        let scenario = state(currentActionIsCheckin: false, autoCheckinStatus: [1: .failed])
            .inquiryScenario(accident, userActiveProject: "P80", automaticActivitiesEnabled: true)
        XCTAssertEqual(scenario, .autoCheckinFailed)
    }
}
