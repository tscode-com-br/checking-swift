import XCTest
@testable import Checking

// Wizard 5 passos — canProceed*/canSubmitConfirm, limite de descrição, effective*, back de PROJECT fecha. §14.
final class WizardTests: XCTestCase {

    // MARK: WizardState derivações puras

    func test_canProceedProject_requires_selection() {
        var ws = WizardState()
        XCTAssertFalse(ws.canProceedProject)
        ws.selectedProjectId = 1
        XCTAssertTrue(ws.canProceedProject)
    }

    func test_canProceedLocation_by_selection_or_custom_nonblank() {
        var ws = WizardState()
        XCTAssertFalse(ws.canProceedLocation)
        ws.selectedLocationId = 1
        XCTAssertTrue(ws.canProceedLocation)
        ws = WizardState()
        ws.useCustomLocation = true
        XCTAssertFalse(ws.canProceedLocation)          // custom mas em branco
        ws.customLocationName = "Portaria 2"
        XCTAssertTrue(ws.canProceedLocation)
    }

    func test_canProceedSituation_requires_zone_and_status() {
        var ws = WizardState()
        XCTAssertFalse(ws.canProceedSituation)
        ws.selectedZone = .safety
        XCTAssertFalse(ws.canProceedSituation)
        ws.selectedStatus = .ok
        XCTAssertTrue(ws.canProceedSituation)
    }

    func test_canSubmitConfirm_requires_all_three_and_not_submitting() {
        var ws = WizardState()
        ws.selectedProjectId = 1; ws.selectedLocationId = 2; ws.selectedZone = .safety; ws.selectedStatus = .ok
        XCTAssertTrue(ws.canSubmitConfirm)
        ws.isSubmitting = true
        XCTAssertFalse(ws.canSubmitConfirm)
    }

    func test_effectiveLocationId_nil_when_custom() {
        var ws = WizardState()
        ws.selectedLocationId = 5; ws.useCustomLocation = true
        XCTAssertNil(ws.effectiveLocationId)
        ws.useCustomLocation = false
        XCTAssertEqual(ws.effectiveLocationId, 5)
    }

    func test_effectiveLocationLabel_whitespace_only_custom_falls_back_to_placeholder() {
        var ws = WizardState()
        ws.useCustomLocation = true
        ws.customLocationName = "   "               // só espaço — trim deve pegar (regressão da revisão)
        XCTAssertEqual(ws.effectiveLocationLabel, "?")
        ws.customLocationName = "Portaria 2"
        XCTAssertEqual(ws.effectiveLocationLabel, "Portaria 2")
    }

    func test_effectiveCustomName_nil_when_not_custom_or_blank() {
        var ws = WizardState()
        ws.customLocationName = "Portaria 2"
        XCTAssertNil(ws.effectiveCustomName)             // not useCustomLocation
        ws.useCustomLocation = true
        XCTAssertEqual(ws.effectiveCustomName, "Portaria 2")
        ws.customLocationName = "   "
        XCTAssertNil(ws.effectiveCustomName)              // em branco → nil
    }

    // MARK: VM — navegação e submit

    @MainActor
    func test_openWizard_starts_at_project_and_loads_catalog() async {
        let repo = FakeAccidentRepository()
        repo.wizardProjectsResult = .success([WizardProject(id: 1, name: "PRJ")])
        let vm = makeAccidentViewModel(repository: repo)
        vm.openWizard()
        XCTAssertTrue(vm.uiState.wizardOpen)
        XCTAssertEqual(vm.uiState.wizardState?.step, .project)
        await settle { !(vm.uiState.wizardState?.projects.isEmpty ?? true) }
        XCTAssertEqual(vm.uiState.wizardState?.projects.first?.name, "PRJ")
    }

    @MainActor
    func test_onWizardDescriptionChanged_limits_to_500_chars() {
        let vm = makeAccidentViewModel()
        vm.openWizard()
        vm.onWizardDescriptionChanged(String(repeating: "a", count: 500))
        XCTAssertEqual(vm.uiState.wizardState?.description.count, 500)
        vm.onWizardDescriptionChanged(String(repeating: "b", count: 501))
        XCTAssertEqual(vm.uiState.wizardState?.description.count, 500)   // rejeitado — permanece o anterior
    }

    @MainActor
    func test_onWizardBack_from_project_closes_wizard() {
        let vm = makeAccidentViewModel()
        vm.openWizard()
        vm.onWizardBack()
        XCTAssertFalse(vm.uiState.wizardOpen)
        XCTAssertNil(vm.uiState.wizardState)
    }

    @MainActor
    func test_onWizardBack_from_location_returns_to_project() {
        let vm = makeAccidentViewModel()
        vm.openWizard()
        vm.onWizardProjectSelected(id: 1, name: "PRJ")
        vm.onWizardNextFromProject()
        XCTAssertEqual(vm.uiState.wizardState?.step, .location)
        vm.onWizardBack()
        XCTAssertEqual(vm.uiState.wizardState?.step, .project)
        XCTAssertTrue(vm.uiState.wizardOpen)   // ainda aberto (não fechou)
    }

    /// Preenche até CONFIRM via a sequência real de navegação (prova os métodos de seleção de verdade).
    @MainActor
    private func fillWizardToConfirm(_ vm: AccidentViewModel) {
        vm.openWizard()
        vm.onWizardProjectSelected(id: 1, name: "PRJ")
        vm.onWizardNextFromProject()
        vm.onWizardLocationSelected(id: 2, name: "Portaria 1")
        vm.onWizardNextFromLocation()
        vm.onWizardNextFromDescription()
        vm.onWizardSituationSelected(zone: .safety, status: .ok)
        vm.onWizardNextFromSituation()
    }

    @MainActor
    func test_onWizardConfirmSubmit_sends_blank_description_as_nil_which_repo_turns_to_empty_string() async {
        let repo = FakeAccidentRepository()
        repo.openResult = .success(FakeAccidentRepository.emptyState)
        let vm = makeAccidentViewModel(repository: repo)
        fillWizardToConfirm(vm)                     // description fica "" (default) — não digitada
        vm.onWizardConfirmSubmit()
        await settle { !repo.openCalls.isEmpty }
        XCTAssertNil(repo.openCalls.first?.description)   // VM passa nil p/ descrição em branco (ifBlank{null})
    }

    @MainActor
    func test_onWizardConfirmSubmit_success_closes_wizard_and_updates_state() async {
        let repo = FakeAccidentRepository()
        let newState = accidentStateWith([accidentItem(1)])
        repo.openResult = .success(newState)
        let vm = makeAccidentViewModel(repository: repo)
        fillWizardToConfirm(vm)
        vm.onWizardConfirmSubmit()
        await settle { !vm.uiState.wizardOpen }
        XCTAssertNil(vm.uiState.wizardState)
        XCTAssertEqual(vm.uiState.accidentState?.activeAccidents.first?.accidentId, 1)
    }

    @MainActor
    func test_onWizardConfirmSubmit_conflict_shows_conflictAlreadyActive() async {
        let repo = FakeAccidentRepository()
        repo.openResult = .failure(.conflict)
        let vm = makeAccidentViewModel(repository: repo)
        fillWizardToConfirm(vm)
        vm.onWizardConfirmSubmit()
        await settle { !(vm.uiState.wizardState?.errorMessage.isEmpty ?? true) }
        XCTAssertEqual(vm.uiState.wizardState?.errorMessage, t("accident.wizard.conflictAlreadyActive"))
        XCTAssertTrue(vm.uiState.wizardOpen)   // permanece aberto p/ o usuário corrigir
    }

    @MainActor
    func test_onWizardProjectSelected_and_onWizardSituationSelected_update_state() {
        let vm = makeAccidentViewModel()
        vm.openWizard()
        vm.onWizardProjectSelected(id: 7, name: "PRJ7")
        XCTAssertEqual(vm.uiState.wizardState?.selectedProjectId, 7)
        XCTAssertEqual(vm.uiState.wizardState?.selectedProjectName, "PRJ7")
        vm.onWizardSituationSelected(zone: .accident, status: .help)
        XCTAssertEqual(vm.uiState.wizardState?.selectedZone, .accident)
        XCTAssertEqual(vm.uiState.wizardState?.selectedStatus, .help)
    }

    @MainActor
    func test_onWizardCustomLocationToggled_clears_selection_when_turning_on() {
        let vm = makeAccidentViewModel()
        vm.openWizard()
        vm.onWizardLocationSelected(id: 3, name: "Portaria 3")
        vm.onWizardCustomLocationToggled()   // liga custom → limpa a seleção
        XCTAssertTrue(vm.uiState.wizardState?.useCustomLocation ?? false)
        XCTAssertNil(vm.uiState.wizardState?.selectedLocationId)
        vm.onWizardCustomLocationChanged("Portaria nova")
        XCTAssertEqual(vm.uiState.wizardState?.customLocationName, "Portaria nova")
    }
}
