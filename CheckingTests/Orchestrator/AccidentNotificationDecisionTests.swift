import XCTest
@testable import Checking

// Port de AccidentNotificationDecisionTest.kt — dedup de notificação de acidente via runAccidentCheck. §12.
final class AccidentNotificationDecisionTests: XCTestCase {

    private let chave = "STSM"

    private func accidentState(_ ids: Int...) -> AppResult<AccidentState> {
        .success(AccidentState(
            isActive: !ids.isEmpty, accidentId: ids.first, accidentNumberLabel: nil, projectId: nil, projectName: nil,
            locationName: nil, description: nil, awarenessStatus: nil, currentUserReport: nil,
            activeAccidents: ids.map { AccidentActiveItem(accidentId: $0, accidentNumberLabel: "AC-\($0)", projectId: 1,
                                                          projectName: "P80", locationName: "L", description: nil,
                                                          awarenessStatus: "open", currentUserReport: nil) }))
    }

    func test_newAccident_postsOnce_andRemembersId() async {
        let prefs = FakeAppPreferences(); prefs.chaveValue = chave; prefs.userSettingsJsonValue = ""; prefs.seenAccidentIdsValue = []
        let accident = FakeAccidentStateRepository(); accident.result = accidentState(42)
        let notifications = SpyNotifications()
        await makeOrchestrator(prefs: prefs, accidentRepository: accident, notifications: notifications).runAccidentCheck()
        XCTAssertEqual(notifications.accidentPosts, ["pt"])          // postAccidentNotification(lang:"pt") 1×
        XCTAssertEqual(prefs.setSeenCalls, [Set([42])])             // persiste o id novo
    }

    func test_alreadySeen_doesNotPostAgain() async {
        let prefs = FakeAppPreferences(); prefs.chaveValue = chave; prefs.userSettingsJsonValue = ""; prefs.seenAccidentIdsValue = [42]
        let accident = FakeAccidentStateRepository(); accident.result = accidentState(42)
        let notifications = SpyNotifications()
        await makeOrchestrator(prefs: prefs, accidentRepository: accident, notifications: notifications).runAccidentCheck()
        XCTAssertTrue(notifications.accidentPosts.isEmpty)
        XCTAssertTrue(prefs.setSeenCalls.isEmpty)                   // set inalterado → não persiste
    }

    func test_notifyDisabled_doesNotPost_norQueriesState() async throws {
        let settings = UserSettings(projects: ["P80"], activeProject: "P80", automaticActivitiesEnabled: false, notifyAccident: false)
        let json = String(data: try JSONCoding.encoder.encode([chave: settings]), encoding: .utf8)!
        let prefs = FakeAppPreferences(); prefs.chaveValue = chave; prefs.userSettingsJsonValue = json; prefs.seenAccidentIdsValue = []
        let accident = FakeAccidentStateRepository(); accident.result = accidentState(42)
        let notifications = SpyNotifications()
        await makeOrchestrator(prefs: prefs, accidentRepository: accident, notifications: notifications).runAccidentCheck()
        XCTAssertTrue(notifications.accidentPosts.isEmpty)
        XCTAssertEqual(accident.getStateCount, 0)                   // toggle-off curto-circuita ANTES da query
    }
}
