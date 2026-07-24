import SwiftUI

/// Raiz de navegação — port do fluxo `MainActivity`/`CheckingNavHost`: Splash animado → CHECK (§6/§10/§15).
/// Transporte e Acidente NÃO são rotas — são overlays dentro do Check (preservam o estado por baixo, §9).
struct RootView: View {
    @Environment(\.appEnvironment) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var systemDynamicTypeSize
    @State private var showSplash = true
    @State private var checkViewModel: CheckViewModel?
    @State private var accidentViewModel: AccidentViewModel?
    @State private var destination = RootDestination.initial

    var body: some View {
        Group {
            if showSplash {
                AppSplashScreen(
                    onFinished: { showSplash = false },
                    forceReduceMotion: effectiveReduceMotion)
                    .transition(reduceMotion ? .identity : .opacity)
            } else if let checkViewModel, let accidentViewModel {
                destinationView(checkViewModel, accidentViewModel)
            } else {
                ProgressView("Preparando Checking…")
                    .task {
                        checkViewModel = makeCheckViewModel()
                        accidentViewModel = makeAccidentViewModel()
                    }
            }
        }
        .environment(\.dynamicTypeSize, effectiveDynamicTypeSize)
        // O design do Checking usa superfícies claras fixas. Sem esta preferência, textos e controles
        // semânticos do sistema podem mudar para branco quando o iPhone entra no modo escuro, embora os
        // cartões permaneçam brancos.
        .preferredColorScheme(.light)
        .animation(effectiveReduceMotion ? nil : .easeInOut(duration: 0.25), value: showSplash)
    }

    private var effectiveDynamicTypeSize: DynamicTypeSize {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-dynamic-type-xxxl") {
            return .accessibility5
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-dynamic-type-default") {
            return .large
        }
#endif
        return systemDynamicTypeSize
    }

    private var effectiveReduceMotion: Bool {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-reduce-motion") { return true }
#endif
        return reduceMotion
    }

    @ViewBuilder
    private func destinationView(_ viewModel: CheckViewModel, _ accidentViewModel: AccidentViewModel) -> some View {
        switch destination {
        case .check:
            CheckMainScreen(
                viewModel: viewModel,
                accidentViewModel: accidentViewModel,
                environment: env,
                onNavigateToManual: { destination = .manual },
                onNavigateToAbout: { destination = .about },
                onNavigateToPrivacy: { destination = .privacy })
        case .manual:
            ManualScreen(languageCode: viewModel.languageCode, onBack: { destination = .check })
        case .about:
            AboutScreen(languageCode: viewModel.languageCode, onBack: { destination = .check })
        case .privacy:
            PrivacyScreen(
                chave: viewModel.uiState.chave,
                languageCode: viewModel.languageCode,
                onBack: { destination = .check },
                onDeleteLocalData: { await viewModel.deleteLocalData() })
        }
    }

    @MainActor
    private func makeAccidentViewModel() -> AccidentViewModel {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        var initialState: AccidentUiState?
        if arguments.contains("--ui-test-accident-active") {
            let accident = AccidentActiveItem(
                accidentId: 42, accidentNumberLabel: "AC-42", projectId: 1, projectName: "P80",
                locationName: "Unidade P80", description: "Ocorrência simulada para validação da interface.",
                awarenessStatus: "open", currentUserReport: nil)
            initialState = AccidentUiState(
                accidentState: AccidentState(
                    isActive: true, accidentId: 42, accidentNumberLabel: "AC-42", projectId: 1,
                    projectName: "P80", locationName: "Unidade P80",
                    description: accident.description, awarenessStatus: "open",
                    currentUserReport: nil, activeAccidents: [accident]),
                hasCurrentDayCheckin: true, currentActionIsCheckin: true,
                bannerMessage: t("accident.notification.bannerTemplate", ["project": "P80"]))
        } else if arguments.contains("--ui-test-accident-wizard") {
            initialState = AccidentUiState(
                wizardOpen: true,
                wizardState: WizardState(
                    projects: [WizardProject(id: 1, name: "P80"), WizardProject(id: 2, name: "P81")]))
        }
#else
        let initialState: AccidentUiState? = nil
#endif
        return AccidentViewModel(
            repository: env.accidentRepository,
            videoRecorder: AVFoundationVideoRecorder(),
            initialState: initialState)
    }

    @MainActor
    private func makeCheckViewModel() -> CheckViewModel {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        var initialState: CheckUiState?
        if arguments.contains("--ui-test-first-use") {
            initialState = .firstUseUITestFixture
        } else if arguments.contains("--ui-test-no-password") {
            initialState = .noPasswordUITestFixture
        } else {
            initialState = arguments.contains("--ui-test-authenticated")
                ? .authenticatedUITestFixture
                : nil
        }
        if arguments.contains("--ui-test-no-projects") {
            initialState?.userProjects = UserProjects(projects: [], activeProject: "")
        }
        if arguments.contains("--ui-test-accident-active") {
            initialState?.historyState = HistoryState(
                found: true, chave: "HR70", projeto: "P80", currentAction: .checkIn,
                currentLocal: "Unidade P80", hasCurrentDayCheckin: true,
                lastCheckinAt: Date(timeIntervalSince1970: 1_753_153_200),
                lastCheckoutAt: nil, transportEnabled: false)
        }
        if arguments.contains("--ui-test-location-card") {
            initialState?.automaticActivitiesEnabled = true
            initialState?.locationPermissionSufficient = true
            initialState?.backgroundLocationConsentGranted = true
            initialState?.permissionsStatus = PermissionsStatus(
                locationAuthorization: .always,
                preciseAccuracy: true,
                cameraMicGranted: false,
                notificationAuthorization: .authorized,
                lowPowerMode: false,
                backgroundRefresh: .available)
            initialState?.locationMatch = LocationMatch(
                matched: true,
                resolvedLocal: "Escritório Principal",
                label: "Escritório Principal",
                status: .matched,
                message: "",
                accuracyMeters: 8,
                accuracyThresholdMeters: 30,
                minimumCheckoutDistanceMeters: 2_000,
                nearestWorkplaceDistanceMeters: 0)
        }
        if arguments.contains("--ui-test-automatic-dialog") {
            initialState?.dialogOpen = .autoActivities
        }
        if arguments.contains("--ui-test-notifications-dialog") {
            initialState?.dialogOpen = .notifications
        }
        if arguments.contains("--ui-test-scheduled-pause-dialog") {
            initialState?.dialogOpen = .scheduledPause
        }
        if arguments.contains("--ui-test-settings-dialog") {
            initialState?.dialogOpen = .settings
        }
        if arguments.contains("--ui-test-self-registration-dialog") {
            initialState?.dialogOpen = .selfRegistration
            initialState?.selfRegistrationFields = SelfRegistrationFields(
                chave: "AB12",
                nome: "",
                email: "",
                password: "",
                confirmPw: "",
                selectedProjectIds: [],
                errorMessage: "",
                isBusy: false,
                projectCatalog: [
                    Project(id: 1, name: "P80", transportEnabled: false),
                    Project(id: 2, name: "P81", transportEnabled: false),
                ],
                isLoadingProjects: false)
        }
        if arguments.contains("--ui-test-password-dialog") {
            initialState?.dialogOpen = .passwordChange
        }
        if arguments.contains("--ui-test-history-dialog") {
            initialState?.dialogOpen = .history
            initialState?.historyDialog = CheckHistoryDialogState(
                action: .checkIn,
                entries: (0 ..< 30).map { index in
                    CheckHistoryEntry(
                        action: .checkIn,
                        projeto: "P80",
                        local: index.isMultiple(of: 2) ? "Escritório Principal" : "Escritório Avançado da P80",
                        time: Date(timeIntervalSince1970: 1_753_153_200 - Double(index * 3_600)),
                        informe: .normal)
                })
        }
        if arguments.contains("--ui-test-activities-dialog") {
            initialState?.dialogOpen = .activities
            initialState?.activityEntries = (0 ..< 36).map { index in
                ActivityLogEntry(
                    at: Date(timeIntervalSince1970: 1_753_153_200 - Double(index * 900)),
                    actor: index.isMultiple(of: 5) ? .user : .sys,
                    kind: index.isMultiple(of: 4) ? .checkIn : .trigger,
                    severity: index.isMultiple(of: 4) ? .success : .info,
                    description: index.isMultiple(of: 4)
                        ? "Check-in at Escritório Principal."
                        : "Background evaluation (SIGNIFICANT_LOCATION).",
                    location: index.isMultiple(of: 4) ? "Escritório Principal" : nil)
            }
            initialState?.activityNextOffset = 36
            initialState?.activityCanLoadMore = false
            initialState?.isActivitiesLoading = false
        }
        let initialLanguageCode = arguments.compactMap { argument -> String? in
            let prefix = "--ui-test-language-"
            return argument.hasPrefix(prefix) ? String(argument.dropFirst(prefix.count)) : nil
        }.first ?? (arguments.contains("--ui-test-english") ? "en" : nil)
#else
        let initialState: CheckUiState? = nil
        let initialLanguageCode: String? = nil
#endif
        return CheckViewModel(
            appPreferences: env.appPreferences,
            securePasswordStore: env.securePasswordStore,
            authRepository: env.authRepository,
            projectRepository: env.projectRepository,
            checkRepository: env.checkRepository,
            captureLocationUseCase: env.captureLocationUseCase,
            offlineQueue: env.offlineQueue,
            permissionsInspector: env.permissionsInspector,
            orchestrator: env.orchestrator,
            significantLocationMonitor: env.significantLocationMonitor,
            checkEventStream: env.checkEventStream,
            activityLogger: env.activityLogger,
            clock: env.clock,
            activityLog: env.activityLog,
            geofenceRegionManager: env.geofenceRegionManager,
            initialState: initialState,
            initialLanguageCode: initialLanguageCode)
    }
}

private enum RootDestination {
    case check, manual, about, privacy

    static var initial: RootDestination {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-manual") { return .manual }
        if arguments.contains("--ui-test-about") { return .about }
        if arguments.contains("--ui-test-privacy") { return .privacy }
#endif
        return .check
    }
}

#if DEBUG
private extension CheckUiState {
    static var firstUseUITestFixture: CheckUiState {
        CheckUiState(isInitializing: false)
    }

    static var noPasswordUITestFixture: CheckUiState {
        var state = CheckUiState(isInitializing: false)
        state.chave = "HR70"
        state.authStatus = AuthStatus(
            found: true, chave: "HR70", hasPassword: false, authenticated: false,
            message: "", pendingApproval: false, queueFull: false)
        state.prompt = t("auth.createPasswordPrompt", lang: "pt")
        return state
    }

    static var authenticatedUITestFixture: CheckUiState {
        var state = CheckUiState(isInitializing: false)
        state.chave = "HR70"
        state.password = "fixture"
        state.authStatus = AuthStatus(
            found: true, chave: "HR70", hasPassword: true, authenticated: true,
            message: "", pendingApproval: false, queueFull: false)
        state.historyState = HistoryState(
            found: true, chave: "HR70", projeto: "P80", currentAction: .checkOut,
            currentLocal: "Escritório Principal", hasCurrentDayCheckin: false,
            lastCheckinAt: Date(timeIntervalSince1970: 1_753_153_200),
            lastCheckoutAt: Date(timeIntervalSince1970: 1_753_185_600),
            transportEnabled: false)
        state.userProjects = UserProjects(projects: ["P80"], activeProject: "P80")
        state.mainProjectCatalog = [
            Project(id: 1, name: "P80", transportEnabled: false),
            Project(id: 2, name: "P81", transportEnabled: false),
        ]
        state.availableLocations = ["Escritório Principal", "Escritório Avançado da P80", "Unidade P80"]
        state.selectedManualLocation = "Escritório Principal"
        state.notificationPrimary = t("status.authenticationCompleted", lang: "pt")
        state.notificationTone = .teal
        return state
    }
}
#endif

#Preview("Splash") {
    AppSplashScreen(onFinished: {})
}

#Preview("Shell") {
    RootView()
        .environment(\.appEnvironment, .preview)
}

#Preview("Root") {
    RootView().environment(\.appEnvironment, .preview)
}
