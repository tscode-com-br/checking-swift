import Foundation

// Estado da tela de acidente — port de presentation/accident/AccidentUiState.kt. §1.

enum WizardStep: Sendable, Equatable { case project, location, description, situation, confirm }
enum AutoCheckinStatus: Sendable, Equatable { case pending, success, failed }
enum InquiryScenario: Sendable, Equatable {
    case showZoneButtons, postReport, hideCard, checkedOutAutoOff, autoCheckinRunning, autoCheckinFailed, triggerAutoCheckin
}

/// Sub-estado de confirmação de zona (duas etapas) — port do `sealed class ZoneConfirmStep`.
enum ZoneConfirmStep: Sendable, Equatable {
    case none
    case accidentExpanded                 // 1º tap em "acidente" expande em ok/help
    case confirmSafety(Int)
    case confirmAccidentOk(Int)
    case confirmAccidentHelp(Int)
}

struct WizardState: Sendable, Equatable {
    var step: WizardStep = .project
    var projects: [WizardProject] = []
    var selectedProjectId: Int?
    var selectedProjectName: String = ""
    var isLoadingProjects = false
    var locations: [WizardLocation] = []
    var selectedLocationId: Int?
    var selectedLocationName: String = ""
    var customLocationName: String = ""
    var useCustomLocation = false
    var isLoadingLocations = false
    var description: String = ""
    var selectedZone: AccidentZone?
    var selectedStatus: AccidentSafetyStatus?
    var isSubmitting = false
    var errorMessage: String = ""

    var effectiveLocationId: Int? { useCustomLocation ? nil : selectedLocationId }
    var effectiveCustomName: String? {
        guard useCustomLocation else { return nil }
        let trimmed = customLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : customLocationName
    }
    var effectiveLocationLabel: String {
        if useCustomLocation {
            return customLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "?" : customLocationName
        }
        if !selectedLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return selectedLocationName }
        return "?"
    }
    var canProceedProject: Bool { selectedProjectId != nil }
    var canProceedLocation: Bool {
        selectedLocationId != nil || (useCustomLocation && !customLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var canProceedSituation: Bool { selectedZone != nil && selectedStatus != nil }
    var canSubmitConfirm: Bool { canProceedProject && canProceedLocation && canProceedSituation && !isSubmitting }
}

struct AccidentUiState: Sendable, Equatable {
    var accidentState: AccidentState?
    // Rastreadores de ciência de SESSÃO (reset no login/logout).
    var ackShownForAccidentIds: Set<Int> = []
    var ackDialogQueue: [AccidentActiveItem] = []
    var ackDialogShowing: AccidentActiveItem?
    // Entradas do estado web de check (dirigem canReportAccident)
    var hasCurrentDayCheckin = false
    var currentActionIsCheckin = false
    // Status de retry de auto-checkin por id de acidente
    var autoCheckinStatus: [Int: AutoCheckinStatus] = [:]
    var zoneConfirmStep: ZoneConfirmStep = .none
    var wizardOpen = false
    var wizardState: WizardState?
    var reportSentForAccidentId: Int?
    var actionsDialogOpen = false
    var videoScreenOpen = false
    var emergencyMessage: String = ""
    var isLoading = false
    var bannerMessage: String = ""
    var needsDisableAutoActivities = false

    var isActive: Bool { accidentState?.isActive == true }
    var activeAccidents: [AccidentActiveItem] { accidentState?.activeAccidents ?? [] }
    var primaryActiveAccident: AccidentActiveItem? { activeAccidents.first }
    var canReportAccident: Bool { hasCurrentDayCheckin && currentActionIsCheckin }

    /// Cenário do cartão de inquérito p/ um acidente — port de `inquiryScenario` (D2: recebe o flag
    /// REAL de automático em todo call-site, nunca `true`/`userProjects != null` hardcoded).
    func inquiryScenario(_ accident: AccidentActiveItem, userActiveProject: String, automaticActivitiesEnabled: Bool) -> InquiryScenario {
        if accident.currentUserReport?.reportedAt != nil { return .postReport }                          // já relatou
        if currentActionIsCheckin && userActiveProject == accident.projectName { return .showZoneButtons } // check-in no projeto do acidente
        if currentActionIsCheckin { return .hideCard }                                                    // check-in em OUTRO projeto
        if !automaticActivitiesEnabled { return .checkedOutAutoOff }                                       // check-out + auto OFF (D2)
        switch autoCheckinStatus[accident.accidentId] {                                                   // check-out + auto ON
        case .pending: return .autoCheckinRunning
        case .success: return .showZoneButtons
        case .failed:  return .autoCheckinFailed
        case nil:      return .triggerAutoCheckin
        }
    }
}
