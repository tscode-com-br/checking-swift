import XCTest
@testable import Checking

// D3 — auto-checkin passivo (nunca submete check-in, só polling do estado); D1 — automático permanece
// ligado após falha (hook é no-op na prática). §14.
@MainActor
final class AutoCheckinTests: XCTestCase {

    func test_never_calls_a_check_submission_endpoint() async {
        // O fake de acidente não tem NENHUM método de submissão de check — a única leitura é getState.
        // Este teste prova por CONSTRUÇÃO: triggerAutoCheckin só chama repository.getState (acidente),
        // nunca um CheckRepository.submit — não há CheckRepository injetado na AccidentViewModel.
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([accidentItem(1)]))
        let vm = makeAccidentViewModel(repository: repo)
        vm.triggerAutoCheckin(1)
        await settle { repo.getStateCallCount >= 1 }
        // getState (acidente) foi chamado — mas AccidentRepository não tem `submit`, então é
        // estruturalmente impossível a VM submeter check-in por aqui.
        XCTAssertGreaterThanOrEqual(repo.getStateCallCount, 1)
    }

    func test_three_polls_then_fails_if_never_checked_in() async {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([]))   // getState sempre sucesso, mas currentActionIsCheckin nunca vira true
        let vm = makeAccidentViewModel(repository: repo)
        vm.triggerAutoCheckin(1)
        await settle(timeout: 3) { vm.uiState.autoCheckinStatus[1] == .failed }
        XCTAssertEqual(vm.uiState.autoCheckinStatus[1], .failed)
        // AUTO_CHECKIN_RETRIES=3 tentativas; CADA sucesso de leitura TAMBÉM dispara `refreshState()`
        // (fire-and-forget, fiel ao Kotlin), que faz sua PRÓPRIA chamada a getState → 2 chamadas/tentativa.
        XCTAssertEqual(repo.getStateCallCount, 6)
    }

    func test_succeeds_once_currentActionIsCheckin_flips_true() async {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([]))
        let vm = makeAccidentViewModel(repository: repo)
        // D3: o módulo Check já virou o estado compartilhado ANTES do auto-checkin rodar — a 1ª
        // tentativa já enxerga currentActionIsCheckin=true e resolve (nunca submete nada — só lê).
        vm.onCheckWebState(ucHistory(.checkIn), activeProject: "P80", automaticActivitiesEnabled: true)
        vm.triggerAutoCheckin(1)
        await settle(timeout: 3) { vm.uiState.autoCheckinStatus[1] == .success }
        XCTAssertEqual(vm.uiState.autoCheckinStatus[1], .success)
        // 1 (onCheckWebState: transição checkout→checkin dispara seu PRÓPRIO refreshState) +
        // 2 (triggerAutoCheckin, 1ª tentativa: direto + via seu refreshState) = 3.
        XCTAssertEqual(repo.getStateCallCount, 3)
    }

    func test_reentrancy_guard_ignores_second_trigger_for_same_accident() async {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([]))
        let vm = makeAccidentViewModel(repository: repo)
        vm.triggerAutoCheckin(1)
        await settle { vm.uiState.autoCheckinStatus[1] == .pending }
        vm.triggerAutoCheckin(1)   // já em andamento — deve ser ignorado (guarda de reentrância)
        await settle(timeout: 3) { vm.uiState.autoCheckinStatus[1] == .failed }
        XCTAssertEqual(repo.getStateCallCount, 6)   // não dobrou (seria 12 se re-disparasse)
    }

    // D1 — após falha, o automático PERMANECE ligado: nenhum stop/persistência ocorre; o hook, mesmo
    // setado, é o único ponto de "desligar" e por design (fiel à produção) não afeta nada real.
    func test_after_failure_automatic_activities_remain_on_hook_is_inert() async {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([]))
        let vm = makeAccidentViewModel(repository: repo)
        let hookCalls = LockedCounter()
        vm.onDisableAutoActivities = { hookCalls.increment() }   // mesmo setado, não persiste nem para nada
        vm.triggerAutoCheckin(1)
        await settle(timeout: 3) { vm.uiState.autoCheckinStatus[1] == .failed }
        // O hook É chamado (fiel à invocação do Kotlin `onDisableAutoActivities?.invoke()`)...
        XCTAssertEqual(hookCalls.value, 1)
        // ...mas nada no estado da VM reflete "desligado" — não há persistência de flag aqui.
        XCTAssertFalse(vm.uiState.needsDisableAutoActivities)   // este campo nunca é setado (D1: morto)
    }

    func test_hook_unset_by_default_never_crashes_on_failure() async {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([]))
        let vm = makeAccidentViewModel(repository: repo)
        // onDisableAutoActivities nunca setado (nil) — espelha CheckScreen.kt não conectar de verdade.
        vm.triggerAutoCheckin(1)
        await settle(timeout: 3) { vm.uiState.autoCheckinStatus[1] == .failed }
        XCTAssertEqual(vm.uiState.autoCheckinStatus[1], .failed)   // não crasha, resolve normalmente
    }
}
