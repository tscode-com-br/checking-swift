import XCTest
@testable import Checking

// Ciclo de vida (onLogin/onLogout), onCheckWebState (o call-site real do D2), filtro SSE. §11/§14.
@MainActor
final class AccidentLifecycleTests: XCTestCase {

    func test_onLogin_resets_state_and_fetches() async {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([accidentItem(1)]))
        let vm = makeAccidentViewModel(repository: repo)
        vm.onLogin("STSM")
        await settle { repo.getStateCallCount >= 1 }
        XCTAssertEqual(vm.uiState.accidentState?.activeAccidents.first?.accidentId, 1)
    }

    // Regressão da revisão [HIGH]: uma resposta tardia de getState da sessão ANTERIOR (bloqueada por
    // uma corrida real de rede) não pode pisar no estado da sessão NOVA já logada.
    func test_stale_session_response_does_not_clobber_new_login_state() async {
        let gate = AsyncGate()
        let repo = FakeAccidentRepository()
        repo.stateGate = gate
        repo.stateResult = .success(accidentStateWith([accidentItem(1)], projectName: "OLD"))
        let vm = makeAccidentViewModel(repository: repo)

        vm.onLogin("AAAA")                                  // refreshState trava no gate (sessão 1)
        await settle { repo.getStateCallCount >= 1 }

        repo.stateGate = nil                                // sessão 2 não trava
        repo.stateResult = .success(accidentStateWith([accidentItem(2)], projectName: "NEW"))
        vm.onLogin("BBBB")                                   // nova sessão — reset + novo refreshState
        await settle { vm.uiState.accidentState?.projectName == "NEW" }

        await gate.release()                                 // libera a resposta tardia da sessão 1
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.uiState.accidentState?.projectName, "NEW")   // OLD (tardio) não sobrescreveu
    }

    func test_onLogout_resets_state_and_stops_polling() {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([accidentItem(1)]))
        let vm = makeAccidentViewModel(repository: repo)
        vm.onLogin("STSM")
        vm.onLogout()
        XCTAssertEqual(vm.uiState, AccidentUiState())   // reset total
    }

    // D2 — este é o call-site que no Kotlin hardcoda `true`; o Swift recebe o flag REAL.
    func test_onCheckWebState_passes_real_automatic_flag_not_hardcoded_true() async {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([accidentItem(1)]))
        let vm = makeAccidentViewModel(repository: repo)
        vm.onLogin("STSM")
        await settle { !vm.uiState.activeAccidents.isEmpty }

        // check-out (currentAction=nil) + automatic=FALSE ⇒ NÃO deve disparar triggerAutoCheckin
        // (inquiryScenario resolveria .checkedOutAutoOff, não .triggerAutoCheckin — D2).
        vm.onCheckWebState(ucHistory(nil), activeProject: "P80", automaticActivitiesEnabled: false)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(vm.uiState.autoCheckinStatus[1])   // NÃO iniciou (auto OFF real respeitado)
    }

    func test_onCheckWebState_triggers_autoCheckin_when_automatic_is_really_on() async {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([accidentItem(1)]))
        let vm = makeAccidentViewModel(repository: repo)
        vm.onLogin("STSM")
        await settle { !vm.uiState.activeAccidents.isEmpty }

        vm.onCheckWebState(ucHistory(nil), activeProject: "P80", automaticActivitiesEnabled: true)
        await settle { vm.uiState.autoCheckinStatus[1] != nil }
        XCTAssertNotNil(vm.uiState.autoCheckinStatus[1])   // auto ON real → dispara
    }

    func test_onCheckWebState_checkout_to_checkin_transition_refreshes() async {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([]))
        let vm = makeAccidentViewModel(repository: repo)
        vm.onLogin("STSM")
        await settle { repo.getStateCallCount >= 1 }
        let before = repo.getStateCallCount
        vm.onCheckWebState(ucHistory(.checkIn), activeProject: "P80", automaticActivitiesEnabled: true)
        await settle { repo.getStateCallCount > before }   // transição checkout→checkin → refreshState extra
        XCTAssertGreaterThan(repo.getStateCallCount, before)
    }

    // MARK: SSE filter — "accident_" prefixo OU contém "accident"

    func test_sse_accident_prefixed_event_triggers_refresh() async {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([]))
        repo.sseEvents = ["accident_opened"]
        let vm = makeAccidentViewModel(repository: repo)
        vm.onLogin("STSM")
        await settle(timeout: 2) { repo.getStateCallCount >= 2 }   // 1 do onLogin + 1 do SSE
        XCTAssertGreaterThanOrEqual(repo.getStateCallCount, 2)
    }

    func test_sse_event_containing_accident_triggers_refresh() async {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([]))
        repo.sseEvents = ["check_accident_update"]   // contém "accident" mas não começa com "accident_"
        let vm = makeAccidentViewModel(repository: repo)
        vm.onLogin("STSM")
        await settle(timeout: 2) { repo.getStateCallCount >= 2 }
        XCTAssertGreaterThanOrEqual(repo.getStateCallCount, 2)
    }

    func test_sse_unrelated_event_does_not_trigger_extra_refresh() async {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([]))
        repo.sseEvents = ["checkin_updated"]   // não contém "accident"
        let vm = makeAccidentViewModel(repository: repo)
        vm.onLogin("STSM")
        await settle { repo.getStateCallCount >= 1 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(repo.getStateCallCount, 1)   // só o refresh do onLogin
    }
}
