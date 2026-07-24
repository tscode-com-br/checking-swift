import SwiftUI

/// Primeira fatia funcional da tela definitiva: ordem inicial exata do CheckCard (histórico,
/// notificação e autenticação) + overlays de conta. As seções autenticadas de registro entram na próxima
/// fatia e não são simuladas aqui.
@MainActor
struct CheckMainScreen: View {
    @Bindable var viewModel: CheckViewModel
    @Bindable var accidentViewModel: AccidentViewModel
    let environment: AppEnvironment
    let onNavigateToManual: () -> Void
    let onNavigateToAbout: () -> Void
    let onNavigateToPrivacy: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var showPhysicalValidation = false
    @State private var permissionRequester = PermissionRequestCoordinator()

    var body: some View {
        ZStack {
            CheckScreenShell(
                accidentActive: accidentViewModel.uiState.isActive,
                banner: { AccidentBannerView(message: accidentViewModel.uiState.bannerMessage) },
                cardBody: {
                    VStack(alignment: .leading, spacing: Tokens.sectionGap) {
                        HistoryCard(
                            history: viewModel.uiState.historyState,
                            languageCode: viewModel.languageCode,
                            onCheckInTap: { viewModel.openHistory(.checkIn) },
                            onCheckOutTap: { viewModel.openHistory(.checkOut) })
                        accidentInquiry
                        if viewModel.uiState.notificationTone != .none || !viewModel.uiState.notificationPrimary.isEmpty {
                            NotificationCard(
                                primary: viewModel.uiState.notificationPrimary,
                                secondary: viewModel.uiState.isLocationLoading
                                    ? t("status.updatingApp", lang: viewModel.languageCode)
                                    : viewModel.uiState.notificationSecondary,
                                tone: viewModel.uiState.notificationTone)
                        }
                        if viewModel.uiState.automaticActivitiesEnabled && viewModel.uiState.locationPermissionSufficient {
                            LocationCard(
                                locationMatch: viewModel.uiState.locationMatch,
                                isLoading: viewModel.uiState.isLocationLoading,
                                languageCode: viewModel.languageCode,
                                onRefresh: viewModel.onRefreshLocation)
                        }
                        if !viewModel.uiState.isInitializing {
                            AuthRow(
                                chave: Binding(
                                    get: { viewModel.uiState.chave },
                                    set: { viewModel.onChaveChanged($0) }),
                                password: Binding(
                                    get: { viewModel.uiState.password },
                                    set: { viewModel.onPasswordChanged($0) }),
                                isFound: viewModel.uiState.isFound,
                                isAuthenticated: viewModel.uiState.isAuthenticated,
                                isStatusLoading: viewModel.uiState.isStatusLoading,
                                isStatusAvailable: viewModel.uiState.authStatus != nil && !viewModel.uiState.isStatusLoading,
                                awaitingApproval: viewModel.uiState.isAwaitingApproval,
                                prompt: viewModel.uiState.prompt,
                                languageCode: viewModel.languageCode,
                                autoActivitiesGlow: automaticGlow,
                                onSettingsTap: viewModel.openSettings,
                                onRequestRegistrationTap: viewModel.openSelfRegistrationDialog)
                        }
                        if viewModel.uiState.isAuthenticated {
                            if viewModel.uiState.showAutoActivitiesNudge {
                                AutoActivitiesNudgeCard(
                                    languageCode: viewModel.languageCode,
                                    onActivate: viewModel.openAutoActivitiesDialog,
                                    onDismiss: viewModel.dismissAutoActivitiesNudge)
                            }
                            RegistrationFieldset(
                                selectedAction: viewModel.uiState.selectedAction,
                                transportEnabled: viewModel.uiState.transportEnabled,
                                languageCode: viewModel.languageCode,
                                onActionSelected: viewModel.onActionSelected,
                                onTransportTap: nil)
                            InformeFieldset(
                                selected: viewModel.uiState.selectedInforme,
                                languageCode: viewModel.languageCode,
                                onSelected: viewModel.onInformeSelected)
                            ProjectsFieldset(
                                catalog: viewModel.uiState.mainProjectCatalog,
                                memberships: viewModel.uiState.userProjects?.projects ?? [],
                                isLoading: viewModel.uiState.isProjectsLoading,
                                languageCode: viewModel.languageCode,
                                initiallyExpanded: projectsInitiallyExpanded,
                                onMembershipToggled: viewModel.onProjectMembershipToggled)
                            if viewModel.uiState.requiresManualLocation && !viewModel.uiState.availableLocations.isEmpty {
                                LocationSelectField(
                                    locations: viewModel.uiState.availableLocations,
                                    selected: viewModel.uiState.selectedManualLocation,
                                    languageCode: viewModel.languageCode,
                                    onSelected: viewModel.onManualLocationSelected)
                            }
                            PrimaryButton(
                                text: "\(t("registration.submitButton", lang: viewModel.languageCode)) \(submitActionLabel)",
                                action: viewModel.onSubmit,
                                enabled: viewModel.uiState.canSubmit)
                                .accessibilityIdentifier("registration.submit")
                            AccidentReportButton(
                                isActive: accidentViewModel.uiState.isActive,
                                languageCode: viewModel.languageCode,
                                action: accidentViewModel.onReportButtonTap)
                        }
                    }
                })
                .accessibilityHidden(isModalPresentationActive)

            dialogOverlay
            AccidentOverlayStack(
                viewModel: accidentViewModel,
                languageCode: viewModel.languageCode,
                settingsOpener: environment.settingsOpener)
        }
        .onChange(of: viewModel.uiState.dialogOpen) { _, dialog in
            if dialog == .selfRegistration { viewModel.loadProjectCatalogForRegistration() }
        }
        .onAppear {
            permissionRequester.onAuthorizationChange = viewModel.finishPermissionReview
            viewModel.onForegroundResume()
            synchronizeAccidentState()
        }
        .onChange(of: accidentCheckContext) { _, _ in synchronizeAccidentState() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.onForegroundResume()
                viewModel.finishPermissionReview()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .checkingOpenAccident)) { _ in
            accidentViewModel.onAccidentNotificationOpened()
        }
#if DEBUG
        .fullScreenCover(isPresented: $showPhysicalValidation) {
            NavigationStack {
                PhysicalValidationScreen(viewModel: viewModel, environment: environment)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Fechar") { showPhysicalValidation = false }
                        }
                    }
            }
        }
#endif
        .provideAccidentTheme(active: accidentViewModel.uiState.isActive)
    }

    @ViewBuilder private var accidentInquiry: some View {
        if viewModel.uiState.isAuthenticated,
           let accident = accidentViewModel.uiState.primaryActiveAccident {
            let scenario = accidentViewModel.uiState.inquiryScenario(
                accident,
                userActiveProject: viewModel.uiState.userProjects?.activeProject ?? "",
                automaticActivitiesEnabled: viewModel.uiState.automaticActivitiesEnabled)
            if scenario != .hideCard && scenario != .checkedOutAutoOff {
                AccidentInquiryCard(
                    accident: accident,
                    scenario: scenario,
                    state: accidentViewModel.uiState,
                    languageCode: viewModel.languageCode,
                    onSafety: { accidentViewModel.onZoneSafetyTap(accident.accidentId) },
                    onAccident: accidentViewModel.onZoneAccidentTap,
                    onAccidentOK: { accidentViewModel.onZoneAccidentOkTap(accident.accidentId) },
                    onAccidentHelp: { accidentViewModel.onZoneAccidentHelpTap(accident.accidentId) },
                    onEmergency: accidentViewModel.triggerEmergencyCall,
                    onDismissEmergency: accidentViewModel.onEmergencyMessageDismiss)
            }
        }
    }

    private var accidentCheckContext: AccidentCheckContext {
        AccidentCheckContext(
            chave: viewModel.uiState.chave,
            authenticated: viewModel.uiState.isAuthenticated,
            action: viewModel.uiState.historyState?.currentAction,
            hasCurrentDayCheckin: viewModel.uiState.historyState?.hasCurrentDayCheckin ?? false,
            activeProject: viewModel.uiState.userProjects?.activeProject ?? "",
            automaticActivitiesEnabled: viewModel.uiState.automaticActivitiesEnabled,
            languageCode: viewModel.languageCode)
    }

    private func synchronizeAccidentState() {
        accidentViewModel.setLanguageCode(viewModel.languageCode)
        accidentViewModel.synchronizeSession(
            chave: viewModel.uiState.chave,
            authenticated: viewModel.uiState.isAuthenticated)
        if let history = viewModel.uiState.historyState, viewModel.uiState.isAuthenticated {
            accidentViewModel.onCheckWebState(
                history,
                activeProject: viewModel.uiState.userProjects?.activeProject ?? "",
                automaticActivitiesEnabled: viewModel.uiState.automaticActivitiesEnabled)
        }
    }

    private var automaticGlow: FieldGlow {
        guard viewModel.uiState.automaticActivitiesEnabled else { return .none }
        return viewModel.uiState.permissionsStatus?.automationHealthLevel == .operational
            ? .authenticated
            : .pending
    }

    private var submitActionLabel: String {
        t(viewModel.uiState.selectedAction == .checkIn
            ? "registration.checkinLabel"
            : "registration.checkoutLabel", lang: viewModel.languageCode)
    }

    private var projectsInitiallyExpanded: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-test-projects-expanded")
#else
        false
#endif
    }

    private var isModalPresentationActive: Bool {
        if viewModel.uiState.dialogOpen != nil { return true }
        if accidentViewModel.uiState.ackDialogShowing != nil
            || accidentViewModel.uiState.actionsDialogOpen
            || accidentViewModel.uiState.wizardOpen
            || accidentViewModel.uiState.videoScreenOpen { return true }
        switch accidentViewModel.uiState.zoneConfirmStep {
        case .confirmSafety, .confirmAccidentOk, .confirmAccidentHelp: return true
        case .none, .accidentExpanded: return false
        }
    }

    @ViewBuilder private var dialogOverlay: some View {
        switch viewModel.uiState.dialogOpen {
        case .settings:
            SettingsDialog(
                isAuthenticated: viewModel.uiState.isAuthenticated,
                hasPassword: viewModel.uiState.hasPassword,
                automaticActivitiesEnabled: viewModel.uiState.automaticActivitiesEnabled,
                permissionsStatus: viewModel.uiState.permissionsStatus,
                languageCode: viewModel.languageCode,
                onLanguageChanged: viewModel.selectLanguage,
                onAutoActivitiesTap: {
                    Task { @MainActor in
                        await Task.yield()
                        viewModel.openAutoActivitiesDialog()
                    }
                },
                onScheduledPauseTap: {
                    Task { @MainActor in
                        await Task.yield()
                        viewModel.openScheduledPauseDialog()
                    }
                },
                onNotificationsTap: {
                    Task { @MainActor in
                        await Task.yield()
                        viewModel.openNotificationsDialog()
                    }
                },
                onManualTap: {
                    viewModel.dismissDialog()
                    onNavigateToManual()
                },
                onSupportTap: {
                    viewModel.dismissDialog()
                    if let url = SupportLinkBuilder.url(
                        chave: viewModel.uiState.chave,
                        languageCode: viewModel.languageCode) {
                        openURL(url)
                    }
                },
                onAboutTap: {
                    viewModel.dismissDialog()
                    onNavigateToAbout()
                },
                onPrivacyTap: {
                    viewModel.dismissDialog()
                    onNavigateToPrivacy()
                },
                onActivitiesTap: {
                    Task { @MainActor in
                        await Task.yield()
                        viewModel.openActivitiesDialog()
                    }
                },
                onPasswordTap: {
                    viewModel.dismissDialog()
                    viewModel.openPasswordChangeDialog()
                },
                onDeleteAccount: {
                    viewModel.dismissDialog()
                    viewModel.deleteAccount()
                },
                onPhysicalValidationTap: {
                    viewModel.dismissDialog()
                    showPhysicalValidation = true
                },
                onDismiss: viewModel.dismissDialog)
        case .passwordChange:
            PasswordChangeDialog(
                fields: viewModel.uiState.passwordChangeFields,
                hasPassword: viewModel.uiState.hasPassword,
                languageCode: viewModel.languageCode,
                onOldChanged: viewModel.onPasswordChangeOldPwChanged,
                onNewChanged: viewModel.onPasswordChangeNewPwChanged,
                onConfirmChanged: viewModel.onPasswordChangeConfirmPwChanged,
                onSubmit: viewModel.submitPasswordChange,
                onDismiss: viewModel.dismissDialog)
        case .selfRegistration:
            SelfRegistrationDialog(
                fields: viewModel.uiState.selfRegistrationFields,
                languageCode: viewModel.languageCode,
                onChaveChanged: viewModel.onRegChaveChanged,
                onNameChanged: viewModel.onRegNomeChanged,
                onEmailChanged: viewModel.onRegEmailChanged,
                onPasswordChanged: viewModel.onRegPasswordChanged,
                onConfirmChanged: viewModel.onRegConfirmPwChanged,
                onProjectToggled: viewModel.onRegProjectToggled,
                onSubmit: viewModel.submitSelfRegistration,
                onDismiss: viewModel.dismissDialog)
        case .autoActivities:
            AutoActivitiesDialog(
                enabled: viewModel.uiState.automaticActivitiesEnabled,
                permissions: viewModel.uiState.permissionsStatus,
                consentGranted: viewModel.uiState.backgroundLocationConsentGranted,
                languageCode: viewModel.languageCode,
                onToggle: viewModel.toggleAutomaticActivities,
                onRequestNotifications: {
                    Task {
                        await permissionRequester.requestNotifications()
                        viewModel.finishPermissionReview()
                    }
                },
                onRequestLocation: {
                    permissionRequester.requestWhenInUseLocation()
                },
                onRequestAlways: {
                    permissionRequester.requestAlwaysLocation()
                },
                onOpenSettings: environment.settingsOpener.openAppSettings,
                onConsent: viewModel.recordBackgroundLocationConsent,
                onDismiss: viewModel.dismissDialog)
        case .scheduledPause:
            ScheduledPauseDialog(
                enabled: viewModel.uiState.scheduledPauseEnabled,
                from: viewModel.uiState.scheduledPauseFrom,
                to: viewModel.uiState.scheduledPauseTo,
                suspendSaturdays: viewModel.uiState.suspendSaturdays,
                suspendSundays: viewModel.uiState.suspendSundays,
                languageCode: viewModel.languageCode,
                onChanged: viewModel.onScheduledPauseSettingChanged,
                onDismiss: viewModel.dismissDialog)
        case .notifications:
            NotificationsDialog(
                activities: viewModel.uiState.notifyActivities,
                scheduledPause: viewModel.uiState.notifyScheduledPause,
                accident: viewModel.uiState.notifyAccident,
                languageCode: viewModel.languageCode,
                onChanged: viewModel.onNotificationSettingsChanged,
                onDismiss: viewModel.dismissDialog)
        case .history:
            CheckHistoryDialog(
                state: viewModel.uiState.historyDialog,
                languageCode: viewModel.languageCode,
                onRetry: viewModel.retryHistoryDialog,
                onDismiss: viewModel.dismissDialog)
        case .activities:
            ActivityLogDialog(
                entries: viewModel.uiState.activityEntries,
                isLoading: viewModel.uiState.isActivitiesLoading,
                canLoadMore: viewModel.uiState.activityCanLoadMore,
                onLoadMore: viewModel.loadMoreActivities,
                onClear: viewModel.clearActivities,
                onDismiss: viewModel.dismissDialog)
        default:
            EmptyView()
        }
    }
}

private struct AccidentCheckContext: Equatable {
    let chave: String
    let authenticated: Bool
    let action: CheckAction?
    let hasCurrentDayCheckin: Bool
    let activeProject: String
    let automaticActivitiesEnabled: Bool
    let languageCode: String
}
