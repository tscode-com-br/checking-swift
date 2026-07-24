import Foundation

// Estado da tela de check (fatia auth) — port de presentation/check/CheckUiState.kt. §2.
// (Campos de main-screen incluídos com defaults só para as derivações; o slice de main-screen os preenche.)

enum CheckDialog: Sendable, Equatable {
    case passwordChange, selfRegistration, settings, autoActivities, scheduledPause, notifications, evaluationLog, history, activities
}

enum NotificationTone: Sendable, Equatable {
    case none, info, success, error, teal
}

enum UiInformeType: Sendable, Equatable {
    case normal, retroativo
}

struct PasswordChangeFields: Sendable, Equatable {
    var oldPw = ""
    var newPw = ""
    var confirmPw = ""
    var errorMessage = ""
    var isBusy = false
}

struct SelfRegistrationFields: Sendable, Equatable {
    var chave = ""
    var nome = ""
    var email = ""
    var password = ""
    var confirmPw = ""
    var selectedProjectIds: [Int] = []
    var errorMessage = ""
    var isBusy = false
    var projectCatalog: [Project] = []
    var isLoadingProjects = false
}

struct CheckHistoryDialogState: Sendable, Equatable {
    var action: CheckAction = .checkIn
    var entries: [CheckHistoryEntry] = []
    var isLoading = false
    var isError = false
}

struct CheckUiState: Sendable, Equatable {
    // Startup
    var isInitializing = true

    // Auth
    var chave = ""
    var password = ""
    var authStatus: AuthStatus?
    var isStatusLoading = false
    var prompt = ""
    var statusErrored = false
    var dismissedAssistanceForChave = ""

    // Notificação
    var notificationPrimary = ""
    var notificationSecondary = ""
    var notificationTone: NotificationTone = .none

    // Dialogs
    var dialogOpen: CheckDialog?
    var passwordChangeFields = PasswordChangeFields()
    var selfRegistrationFields = SelfRegistrationFields()
    var historyDialog = CheckHistoryDialogState()
    var activityEntries: [ActivityLogEntry] = []
    var activityNextOffset = 0
    var activityCanLoadMore = false
    var isActivitiesLoading = false

    // Settings espelhadas (do userSettingsJson)
    var automaticActivitiesEnabled = false
    var scheduledPauseEnabled = true
    var scheduledPauseFrom = "20:00"
    var scheduledPauseTo = "07:00"
    var suspendSaturdays = true
    var suspendSundays = true
    var notifyActivities = true
    var notifyScheduledPause = true
    var notifyAccident = true
    var backgroundLocationConsentGranted = false

    // Main-screen (defaults; preenchidos pelo slice de main-screen)
    var isHistoryLoading = false
    var historyState: HistoryState?
    var transportEnabled = false
    var selectedManualLocation: String?
    var userProjects: UserProjects?
    var isProjectsLoading = false
    var mainProjectCatalog: [Project] = []
    var isLocationLoading = false
    var locationPermissionSufficient = false
    var permissionsStatus: PermissionsStatus?
    var availableLocations: [String] = []
    var showAutoActivitiesNudge = false
    var isSubmitting = false
    var locationMatch: LocationMatch?
    var selectedAction: CheckAction = .checkIn
    var selectedInforme: UiInformeType = .normal

    // Derivações
    var isAuthenticated: Bool { authStatus?.authenticated == true }
    var isFound: Bool { authStatus?.found == true }
    var hasPassword: Bool { authStatus?.hasPassword == true }
    var isAwaitingApproval: Bool { authStatus?.pendingApproval == true }
    var isAccuracyTooLow: Bool { locationMatch?.status == .accuracyTooLow }
    var requiresManualLocation: Bool { !automaticActivitiesEnabled || isAccuracyTooLow }

    var canSubmit: Bool {
        guard isAuthenticated && !isSubmitting else { return false }
        if !requiresManualLocation { return locationMatch != nil }
        if selectedAction == .checkOut { return true }
        return selectedManualLocation != nil
    }
}
