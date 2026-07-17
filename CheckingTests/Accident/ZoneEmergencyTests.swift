import XCTest
@testable import Checking

// Relato de zona + emergência. submitReport(HELP) dispara triggerEmergencyCall; emergencyCall .conflict
// ⇒ alreadyCalled (idempotência). §14.
@MainActor
final class ZoneEmergencyTests: XCTestCase {

    func test_onZoneSafetyTap_sets_confirmSafety_step() {
        let vm = makeAccidentViewModel()
        vm.onZoneSafetyTap(1)
        XCTAssertEqual(vm.uiState.zoneConfirmStep, .confirmSafety(1))
    }
    func test_onZoneAccidentTap_expands() {
        let vm = makeAccidentViewModel()
        vm.onZoneAccidentTap()
        XCTAssertEqual(vm.uiState.zoneConfirmStep, .accidentExpanded)
    }

    func test_onZoneConfirm_safety_submits_safety_ok() async {
        let repo = FakeAccidentRepository()
        repo.reportResult = .success(FakeAccidentRepository.emptyState)
        let vm = makeAccidentViewModel(repository: repo)
        vm.onZoneSafetyTap(1)
        vm.onZoneConfirm()
        await settle { repo.reportCallCount >= 1 }
        XCTAssertEqual(vm.uiState.zoneConfirmStep, .none)
        XCTAssertEqual(repo.emergencyCallCount, 0)         // OK não dispara emergência
    }

    func test_onZoneConfirm_accidentHelp_submits_and_triggers_emergency() async {
        let repo = FakeAccidentRepository()
        repo.reportResult = .success(FakeAccidentRepository.emptyState)
        repo.emergencyResult = .success(EmergencyCallResult(callNumber: 190, callNumberLabel: "190", callSid: nil, callStatus: "queued", message: "ok"))
        let vm = makeAccidentViewModel(repository: repo)
        vm.onZoneAccidentHelpTap(1)
        vm.onZoneConfirm()
        await settle { repo.emergencyCallCount >= 1 }      // HELP → triggerEmergencyCall
        XCTAssertEqual(repo.reportCallCount, 1)
        XCTAssertEqual(vm.uiState.reportSentForAccidentId, 1)
    }

    func test_submitReport_failure_is_silent() async {
        let repo = FakeAccidentRepository()
        repo.reportResult = .failure(.network)
        let vm = makeAccidentViewModel(repository: repo)
        vm.onZoneSafetyTap(1)
        vm.onZoneConfirm()
        await settle { repo.reportCallCount >= 1 }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(vm.uiState.reportSentForAccidentId)   // nada mudou — falha silenciosa (§13)
        XCTAssertTrue(vm.uiState.bannerMessage.isEmpty)
    }

    func test_emergencyCall_success_sets_callInitiated_message() async {
        let repo = FakeAccidentRepository()
        repo.emergencyResult = .success(EmergencyCallResult(callNumber: 190, callNumberLabel: "190", callSid: nil, callStatus: "queued", message: "ok"))
        let vm = makeAccidentViewModel(repository: repo)
        vm.triggerEmergencyCall()
        await settle { !vm.uiState.emergencyMessage.isEmpty }
        XCTAssertEqual(vm.uiState.emergencyMessage, t("accident.emergency.callInitiated", ["label": "190"]))
    }

    func test_emergencyCall_conflict_maps_to_alreadyCalled() async {
        let repo = FakeAccidentRepository()
        repo.emergencyResult = .failure(.conflict)
        let vm = makeAccidentViewModel(repository: repo)
        vm.triggerEmergencyCall()
        await settle { !vm.uiState.emergencyMessage.isEmpty }
        XCTAssertEqual(vm.uiState.emergencyMessage, t("accident.emergency.alreadyCalled"))
    }

    func test_emergencyCall_other_failure_maps_to_callFailed() async {
        let repo = FakeAccidentRepository()
        repo.emergencyResult = .failure(.network)
        let vm = makeAccidentViewModel(repository: repo)
        vm.triggerEmergencyCall()
        await settle { !vm.uiState.emergencyMessage.isEmpty }
        XCTAssertEqual(vm.uiState.emergencyMessage, t("accident.emergency.callFailed"))
    }

    // MARK: onReportButtonTap / actionsDialog

    func test_onReportButtonTap_opens_actionsDialog_when_active() async {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([accidentItem(1)]))
        let vm = makeAccidentViewModel(repository: repo)
        vm.onLogin("STSM")
        await settle { vm.uiState.isActive }   // refreshState() do onLogin é assíncrono
        vm.onReportButtonTap()
        XCTAssertTrue(vm.uiState.actionsDialogOpen)
        XCTAssertFalse(vm.uiState.wizardOpen)
    }

    func test_onReportButtonTap_opens_wizard_when_not_active() {
        let vm = makeAccidentViewModel()   // sem acidente ativo (estado default)
        vm.onReportButtonTap()
        XCTAssertTrue(vm.uiState.wizardOpen)
        XCTAssertFalse(vm.uiState.actionsDialogOpen)
    }

    // MARK: onAckConfirm / onAckDismiss

    func test_onAckConfirm_noop_when_nothing_showing() {
        let vm = makeAccidentViewModel()      // sem login → nada na fila
        vm.onAckConfirm()
        XCTAssertNil(vm.uiState.ackDialogShowing)
    }

    func test_onAckConfirm_acknowledges_drains_queue_and_triggers_autoCheckin() async {
        let repo = FakeAccidentRepository()
        // onLogin→refreshState→getState traz 1 acidente ativo novo → reconcileAckQueue o coloca em ackDialogShowing.
        repo.stateResult = .success(accidentStateWith([accidentItem(1)]))
        let vm = makeAccidentViewModel(repository: repo)
        vm.onLogin("STSM")
        await settle { vm.uiState.ackDialogShowing?.accidentId == 1 }

        vm.onAckConfirm()
        await settle { !repo.acknowledgeCalls.isEmpty }
        XCTAssertEqual(repo.acknowledgeCalls, [1])
        await settle { vm.uiState.autoCheckinStatus[1] != nil }   // triggerAutoCheckin(1) disparado
        XCTAssertNotNil(vm.uiState.autoCheckinStatus[1])
        XCTAssertNil(vm.uiState.ackDialogShowing)                 // fila drenada (vazia)
    }

    func test_onAckDismiss_does_not_call_acknowledge() {
        let repo = FakeAccidentRepository()
        let vm = makeAccidentViewModel(repository: repo)
        vm.onAckDismiss()
        XCTAssertTrue(repo.acknowledgeCalls.isEmpty)
    }

    // MARK: Métodos de dismiss (regressão da revisão — #2/#4/#5)

    func test_onWizardDismiss_closes_from_any_step_without_submitting() {
        let repo = FakeAccidentRepository()
        let vm = makeAccidentViewModel(repository: repo)
        vm.openWizard()
        vm.onWizardProjectSelected(id: 1, name: "PRJ")
        vm.onWizardNextFromProject()   // agora em .location, não .project
        vm.onWizardDismiss()
        XCTAssertFalse(vm.uiState.wizardOpen)
        XCTAssertNil(vm.uiState.wizardState)
        XCTAssertEqual(repo.openCalls.count, 0)   // não submeteu nada
    }

    func test_onZoneConfirmDismiss_cancels_without_submitting() {
        let repo = FakeAccidentRepository()
        let vm = makeAccidentViewModel(repository: repo)
        vm.onZoneAccidentHelpTap(1)
        XCTAssertEqual(vm.uiState.zoneConfirmStep, .confirmAccidentHelp(1))
        vm.onZoneConfirmDismiss()
        XCTAssertEqual(vm.uiState.zoneConfirmStep, .none)
        XCTAssertEqual(repo.reportCallCount, 0)
        XCTAssertEqual(repo.emergencyCallCount, 0)
    }

    func test_onEmergencyMessageDismiss_clears_message() async {
        let repo = FakeAccidentRepository()
        repo.emergencyResult = .failure(.network)
        let vm = makeAccidentViewModel(repository: repo)
        vm.triggerEmergencyCall()
        await settle { !vm.uiState.emergencyMessage.isEmpty }
        vm.onEmergencyMessageDismiss()
        XCTAssertTrue(vm.uiState.emergencyMessage.isEmpty)
    }

    // MARK: openVideoScreen — transição combinada (regressão #3)

    func test_openVideoScreen_also_closes_actionsDialog() async {
        let repo = FakeAccidentRepository()
        repo.stateResult = .success(accidentStateWith([accidentItem(1)]))
        let vm = makeAccidentViewModel(repository: repo)
        vm.onLogin("STSM")
        await settle { vm.uiState.isActive }
        vm.onReportButtonTap()                     // abre actionsDialog (acidente ativo)
        XCTAssertTrue(vm.uiState.actionsDialogOpen)
        vm.openVideoScreen()
        XCTAssertTrue(vm.uiState.videoScreenOpen)
        XCTAssertFalse(vm.uiState.actionsDialogOpen)   // fechado junto (fiel ao Kotlin onVideoRecordOpen)
    }
}
