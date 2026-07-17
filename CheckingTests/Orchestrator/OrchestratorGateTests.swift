import XCTest
@testable import Checking

// Port de OrchestratorToggleGateTest.kt — auto OFF registra TOGGLE_OFF e nunca submete. §12.
final class OrchestratorGateTests: XCTestCase {

    func test_auto_off_records_toggle_off_and_never_submits() async {
        EvaluationLog.shared.reset()
        let at = iso("2026-06-18T09:09:09Z")
        let prefs = FakeAppPreferences()
        prefs.chaveValue = "HR70"; prefs.languageValue = "pt"; prefs.userSettingsJsonValue = ""   // "" → default, auto OFF
        let accident = FakeAccidentStateRepository(); accident.result = .failure(.network)          // acidente no-op
        let spy = SpyAutoActivities()
        let checkRepo = FakeCheckRepository()
        let orchestrator = makeOrchestrator(prefs: prefs, checkRepository: checkRepo, autoActivities: spy,
                                            accidentRepository: accident, clock: FixedClock(at))
        await orchestrator.runOnce(.foreground)

        let entry = EvaluationLog.shared.snapshot().first { $0.at == at && $0.trigger == .foreground }
        XCTAssertNotNil(entry, "esperava uma entrada TOGGLE_OFF para esta run")
        XCTAssertEqual(entry?.outcome, .toggleOff)
        XCTAssertEqual(spy.callCount, 0)              // motor não chamado
        XCTAssertEqual(checkRepo.submitCount, 0)
    }
}
