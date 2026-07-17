import XCTest
@testable import Checking

// Port de SelfRegistrationApprovalTest.kt (8). §9.3. Testes @MainActor; `settle` = "roda o pronto".
@MainActor
final class SelfRegistrationApprovalTests: XCTestCase {

    private func fillFormAndSubmit(_ vm: CheckViewModel) async {
        vm.loadProjectCatalogForRegistration()
        await settle { !vm.uiState.selfRegistrationFields.projectCatalog.isEmpty }
        vm.onRegProjectToggled(1)
        vm.onRegNomeChanged("Full Name")
        vm.onRegPasswordChanged("abc123")
        vm.onRegConfirmPwChanged("abc123")
        vm.submitSelfRegistration()
    }

    func test_submit_pending_enters_awaiting_password_stored_not_authenticated() async {
        let h = VMHarness()
        h.auth.statusResults["NEW1"] = .success(status(found: false))
        h.projects.result = .success([Project(id: 1, name: "PRJ", transportEnabled: false)])
        h.auth.selfRegisterResult = .success(status(found: false, pendingApproval: true))
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }
        vm.onChaveChanged("NEW1")
        await settle { vm.uiState.dialogOpen == .selfRegistration }
        await fillFormAndSubmit(vm)
        await settle { vm.uiState.isAwaitingApproval }

        XCTAssertTrue(vm.uiState.isAwaitingApproval)
        XCTAssertEqual(vm.uiState.notificationPrimary, t("auth.awaitingApproval", lang: "pt"))
        XCTAssertEqual(vm.uiState.notificationTone, .error)
        XCTAssertFalse(vm.uiState.isAuthenticated)
        XCTAssertFalse(vm.uiState.canSubmit)
        XCTAssertTrue(h.passwords.setPasswordCalls.contains { $0.chave == "NEW1" && $0.password == "abc123" })
        XCTAssertEqual(h.auth.getHistoryCallCount, 0)              // onAuthenticationSucceeded NÃO chamado
        XCTAssertTrue(h.orchestrator.runOnceCalls.isEmpty)

        vm.onChaveChanged(""); await settle { vm.uiState.chave.isEmpty }
        h.teardown()
    }

    func test_submit_queue_full_red_message_not_awaiting_not_authenticated() async {
        let h = VMHarness()
        h.auth.statusResults["NEW1"] = .success(status(found: false))
        h.projects.result = .success([Project(id: 1, name: "PRJ", transportEnabled: false)])
        h.auth.selfRegisterResult = .success(status(found: false, queueFull: true))
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }
        vm.onChaveChanged("NEW1")
        await settle { vm.uiState.dialogOpen == .selfRegistration }
        await fillFormAndSubmit(vm)
        await settle { vm.uiState.notificationPrimary == t("auth.registrationQueueFull", lang: "pt") }

        XCTAssertEqual(vm.uiState.notificationPrimary, t("auth.registrationQueueFull", lang: "pt"))
        XCTAssertEqual(vm.uiState.notificationTone, .error)
        XCTAssertFalse(vm.uiState.isAwaitingApproval)
        XCTAssertFalse(vm.uiState.isAuthenticated)
        h.teardown()
    }

    func test_probe_pending_enters_awaiting_and_blocks_submit() async {
        let h = VMHarness()
        h.auth.statusResults["PND1"] = .success(status(found: false, pendingApproval: true, chave: "PND1"))
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }
        vm.onChaveChanged("PND1")
        await settle { vm.uiState.isAwaitingApproval }

        XCTAssertTrue(vm.uiState.isAwaitingApproval)
        XCTAssertEqual(vm.uiState.notificationPrimary, t("auth.awaitingApproval", lang: "pt"))
        XCTAssertEqual(vm.uiState.notificationTone, .error)
        XCTAssertFalse(vm.uiState.canSubmit)

        vm.onChaveChanged(""); await settle { vm.uiState.chave.isEmpty }
        h.teardown()
    }

    func test_approval_found_true_triggers_login_with_stored_password() async {
        let h = VMHarness()
        h.passwords.seed("APR1", "pw1234")
        h.auth.statusResults["APR1"] = .success(status(found: true, hasPassword: true, chave: "APR1"))
        h.auth.loginResults["APR1"] = .success(status(found: true, hasPassword: true, authenticated: false, chave: "APR1"))
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }
        vm.onChaveChanged("APR1")
        await settle { !h.auth.loginCalls.isEmpty }

        XCTAssertTrue(h.auth.loginCalls.contains { $0.chave == "APR1" && $0.password == "pw1234" })
        XCTAssertFalse(vm.uiState.isAwaitingApproval)
        h.teardown()
    }

    func test_unknown_key_autoopens_registration_silently() async {
        let h = VMHarness()
        h.auth.statusResults["UNK1"] = .success(status(found: false, chave: "UNK1"))
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }
        vm.onChaveChanged("UNK1")
        await settle { vm.uiState.dialogOpen == .selfRegistration }

        XCTAssertEqual(vm.uiState.dialogOpen, .selfRegistration)
        XCTAssertFalse(vm.uiState.isAwaitingApproval)
        XCTAssertEqual(vm.uiState.notificationTone, .none)
        XCTAssertEqual(vm.uiState.notificationPrimary, "")
        h.teardown()
    }

    func test_dismiss_sets_guard_and_does_not_reopen_on_foreground() async {
        let h = VMHarness()
        h.auth.statusResults["UNK2"] = .success(status(found: false, chave: "UNK2"))
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }
        vm.onChaveChanged("UNK2")
        await settle { vm.uiState.dialogOpen == .selfRegistration }

        vm.dismissDialog()
        XCTAssertNil(vm.uiState.dialogOpen)

        vm.onForegroundResume()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(vm.uiState.dialogOpen)                        // não reabre (nem auth nem awaiting)
        h.teardown()
    }

    func test_restart_with_stored_pending_key_reconstructs_awaiting() async {
        let h = VMHarness()
        await h.prefs.setChave("RST1")
        h.auth.statusResults["RST1"] = .success(status(found: false, pendingApproval: true, chave: "RST1"))
        let vm = h.build()
        await settle { vm.uiState.isAwaitingApproval }              // init → probe → pending → awaiting

        XCTAssertTrue(vm.uiState.isAwaitingApproval)

        vm.onChaveChanged(""); await settle { vm.uiState.chave.isEmpty }
        h.teardown()
    }

    func test_awaiting_foreground_resume_reprobes_without_running_orchestrator() async {
        let h = VMHarness()
        h.auth.statusResults["AWF1"] = .success(status(found: false, pendingApproval: true, chave: "AWF1"))
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }
        vm.onChaveChanged("AWF1")
        await settle { vm.uiState.isAwaitingApproval }

        vm.onForegroundResume()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(h.orchestrator.runOnceCalls.isEmpty)         // ramo awaiting → só re-probe

        vm.onChaveChanged(""); await settle { vm.uiState.chave.isEmpty }
        h.teardown()
    }

    // Regressão da revisão: autofill de domínio Petrobras + guard de catálogo já carregado.
    func test_onRegEmailChanged_applies_petrobras_autofill() async {
        let h = VMHarness()
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }
        vm.onRegEmailChanged("john@")
        XCTAssertEqual(vm.uiState.selfRegistrationFields.email, "john@petrobras.com.br")
        h.teardown()
    }

    // Regressão da revisão [HIGH]: o probe de uma chave abandonada não pode pisar no estado da chave atual.
    func test_stale_chave_probe_does_not_clobber_newer_chave_state() async {
        let h = VMHarness()
        let gateA = AsyncGate()
        h.auth.statusGates["AAAA"] = gateA
        h.auth.statusResults["AAAA"] = .success(status(found: true, hasPassword: true, chave: "AAAA"))
        h.auth.statusResults["BBBB"] = .success(status(found: false, chave: "BBBB"))
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }

        vm.onChaveChanged("AAAA")                    // probe de AAAA começa e trava em gateA
        try? await Task.sleep(for: .milliseconds(20))  // dá tempo de chegar no getStatus e travar
        vm.onChaveChanged("BBBB")                     // troca ANTES do probe de AAAA resolver
        await settle { vm.uiState.chave == "BBBB" && vm.uiState.authStatus?.chave == "BBBB" }

        await gateA.release()                         // libera a resposta tardia de AAAA
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.uiState.chave, "BBBB")
        XCTAssertEqual(vm.uiState.authStatus?.chave, "BBBB")   // AAAA (tardio) NÃO deve ter sobrescrito
        h.teardown()
    }

    func test_loadProjectCatalogForRegistration_skips_refetch_when_already_loaded() async {
        let h = VMHarness()
        h.projects.result = .success([Project(id: 1, name: "PRJ", transportEnabled: false)])
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }
        vm.loadProjectCatalogForRegistration()
        await settle { !vm.uiState.selfRegistrationFields.projectCatalog.isEmpty }
        XCTAssertEqual(vm.uiState.selfRegistrationFields.projectCatalog.count, 1)

        h.projects.result = .success([])   // se re-buscar, o catálogo seria zerado
        vm.loadProjectCatalogForRegistration()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(vm.uiState.selfRegistrationFields.projectCatalog.count, 1)   // inalterado — guard funcionou
        h.teardown()
    }
}
