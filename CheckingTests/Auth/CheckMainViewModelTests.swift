import XCTest
@testable import Checking

@MainActor
final class CheckMainViewModelTests: XCTestCase {
    private let authenticated = AuthStatus(
        found: true, chave: "HR70", hasPassword: true, authenticated: true,
        message: "", pendingApproval: false, queueFull: false)

    private func history(
        action: CheckAction? = .checkOut,
        local: String? = "Escritório Principal",
        transport: Bool = false
    ) -> HistoryState {
        HistoryState(
            found: true, chave: "HR70", projeto: "P80", currentAction: action, currentLocal: local,
            hasCurrentDayCheckin: action == .checkIn,
            lastCheckinAt: action == .checkIn ? Date(timeIntervalSince1970: 10) : nil,
            lastCheckoutAt: action == .checkOut ? Date(timeIntervalSince1970: 20) : nil,
            transportEnabled: transport)
    }

    private func authenticatedHarness(
        autoEnabled: Bool = false,
        consentGranted: Bool = false,
        captureResult: LocationCaptureResult = .noPermission,
        submitResult: AppResult<HistoryState>? = nil
    ) async -> (VMHarness, CheckViewModel) {
        let h = VMHarness()
        if autoEnabled {
            let settings = UserSettings(
                projects: ["P80"], activeProject: "P80", automaticActivitiesEnabled: true)
            let data = try! JSONCoding.encoder.encode(["HR70": settings])
            await h.prefs.setUserSettingsJson(String(data: data, encoding: .utf8)!)
        }
        if consentGranted {
            await h.prefs.setBackgroundLocationConsentAt("2026-07-24T00:00:00Z")
        }
        h.auth.statusResults["HR70"] = .success(authenticated)
        h.auth.loginResults["HR70"] = .success(authenticated)
        h.auth.historyResult = .success(history())
        h.projects.result = .success([
            Project(id: 1, name: "P80", transportEnabled: false),
            Project(id: 2, name: "P81", transportEnabled: false),
        ])
        h.projects.userProjectsResult = .success(UserProjects(projects: ["P80"], activeProject: "P80"))
        h.checkRepository.getLocationsResult = .success(LocationOptions(
            items: ["Escritório Principal", "Unidade P80"],
            accuracyThresholdMeters: 50,
            mixedZoneIntervalMinutes: 15))
        h.captureLocation.result = captureResult
        if let submitResult { h.checkRepository.submitResult = submitResult }
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }
        vm.onChaveChanged("HR70")
        await settle { vm.uiState.authStatus != nil }
        vm.onPasswordChanged("abc123")
        vm.submitLogin()
        await settle { vm.uiState.isAuthenticated && vm.uiState.userProjects != nil && !vm.uiState.availableLocations.isEmpty }
        return (h, vm)
    }

    func test_authenticationLoadsProjectsCatalogLocationsAndPersistsActiveProject() async {
        let (h, vm) = await authenticatedHarness()

        XCTAssertEqual(vm.uiState.userProjects, UserProjects(projects: ["P80"], activeProject: "P80"))
        XCTAssertEqual(vm.uiState.mainProjectCatalog.map(\.name), ["P80", "P81"])
        XCTAssertEqual(vm.uiState.availableLocations, ["Escritório Principal", "Unidade P80"])
        let map = try? JSONCoding.decoder.decode(
            [String: UserSettings].self,
            from: Data((await h.prefs.userSettingsJson()).utf8))
        XCTAssertEqual(map?["HR70"]?.projects, ["P80"])
        XCTAssertEqual(map?["HR70"]?.activeProject, "P80")
        h.teardown()
    }

    func test_manualCheckInRequiresLocationButCheckoutDoesNot() {
        var state = CheckUiState(isInitializing: false)
        state.authStatus = authenticated
        state.automaticActivitiesEnabled = false
        state.selectedAction = .checkIn
        XCTAssertTrue(state.requiresManualLocation)
        XCTAssertFalse(state.canSubmit)

        state.selectedManualLocation = "Unidade P80"
        XCTAssertTrue(state.canSubmit)
        state.selectedManualLocation = nil
        state.selectedAction = .checkOut
        XCTAssertTrue(state.canSubmit)
    }

    func test_removingLastProjectIsRejectedBeforeRepositoryCall() async {
        let (h, vm) = await authenticatedHarness()
        vm.onProjectMembershipToggled("P80")

        XCTAssertEqual(vm.uiState.notificationPrimary, t("projects.selectAtLeastOne", lang: "pt"))
        XCTAssertEqual(vm.uiState.notificationTone, .error)
        XCTAssertTrue(h.projects.updateUserProjectsCalls.isEmpty)
        h.teardown()
    }

    func test_addingMembershipUpdatesServerStateAndClearsManualLocation() async {
        let (h, vm) = await authenticatedHarness()
        vm.onManualLocationSelected("Escritório Principal")
        h.projects.updateUserProjectsResult = .success(UserProjects(projects: ["P80", "P81"], activeProject: "P80"))
        vm.onProjectMembershipToggled("P81")
        await settle { vm.uiState.userProjects?.projects == ["P80", "P81"] && !vm.uiState.isProjectsLoading }

        XCTAssertEqual(h.projects.updateUserProjectsCalls, [["P80", "P81"]])
        XCTAssertNil(vm.uiState.selectedManualLocation)
        h.teardown()
    }

    func test_manualRetroactiveCheckInSubmitsSelectedLocationAndUpdatesHistory() async {
        let newHistory = history(action: .checkIn, local: "Unidade P80")
        let (h, vm) = await authenticatedHarness(submitResult: .success(newHistory))
        h.checkRepository.getStateResult = .success(newHistory)
        vm.onManualLocationSelected("Unidade P80")
        vm.onInformeSelected(.retroativo)
        vm.onSubmit()
        await settle { !vm.uiState.isSubmitting && h.checkRepository.submitCount == 1 }

        let call = h.checkRepository.submitCalls.first
        XCTAssertEqual(call?.projeto, "P80")
        XCTAssertEqual(call?.action, .checkIn)
        XCTAssertEqual(call?.local, "Unidade P80")
        XCTAssertEqual(call?.informe, .retroativo)
        XCTAssertEqual(vm.uiState.notificationPrimary, t("status.checkinCompleted", lang: "pt"))
        XCTAssertEqual(vm.uiState.notificationTone, .success)
        h.teardown()
    }

    func test_manualCheckoutWithoutSelectionUsesUnknownLocation() async {
        let (h, vm) = await authenticatedHarness(submitResult: .success(history()))
        vm.onManualLocationSelected("Escritório Principal")
        vm.onProjectMembershipToggled("P81")
        await settle { !vm.uiState.isProjectsLoading }
        vm.onActionSelected(.checkOut)
        vm.onSubmit()
        await settle { h.checkRepository.submitCount == 1 }

        XCTAssertEqual(h.checkRepository.submitCalls.first?.local, "Desconhecido")
        h.teardown()
    }

    func test_networkFailureQueuesSameDecidedEventIdentityAndTimestamp() async {
        let (h, vm) = await authenticatedHarness(submitResult: .failure(.network))
        vm.onManualLocationSelected("Unidade P80")
        vm.onSubmit()
        await settle { !h.offlineQueue.enqueued.isEmpty }

        let submitted = try! XCTUnwrap(h.checkRepository.submitCalls.first)
        guard case .decided(let queued) = try! XCTUnwrap(h.offlineQueue.enqueued.first) else {
            return XCTFail("Expected decided event")
        }
        XCTAssertEqual(queued.clientEventId, submitted.clientEventId)
        XCTAssertEqual(queued.capturedAtEpochMs, Int64((submitted.eventTime.timeIntervalSince1970 * 1000).rounded()))
        XCTAssertEqual(queued.action, "checkin")
        XCTAssertEqual(queued.local, "Unidade P80")
        XCTAssertEqual(vm.uiState.notificationPrimary, t("status.savedOffline", lang: "pt"))
        h.teardown()
    }

    func test_manualSubmitIsBlockedWhileAutomaticModeHasNormalMatch() async {
        let (h, vm) = await authenticatedHarness(
            autoEnabled: true,
            captureResult: .matched(ucMatch(.matched, "Escritório Principal")))
        await settle { vm.uiState.locationMatch != nil }
        vm.onSubmit()

        XCTAssertEqual(h.checkRepository.submitCount, 0)
        XCTAssertEqual(
            vm.uiState.notificationPrimary,
            t("registration.disableAutomaticActivitiesForManualSubmit", lang: "pt"))
        h.teardown()
    }

    func test_nudgeCanBeDismissedPermanentlyForCurrentAccount() async {
        let (h, vm) = await authenticatedHarness()
        await settle { vm.uiState.showAutoActivitiesNudge }

        vm.dismissAutoActivitiesNudge()
        await settle { !vm.uiState.showAutoActivitiesNudge }
        try? await Task.sleep(for: .milliseconds(50))

        let dismissed = await h.prefs.getFlag("auto_activities_prompt_dismissed_HR70")
        XCTAssertTrue(dismissed)
        h.teardown()
    }

    func test_settingsCanNavigateToAutomaticActivitiesDialog() async {
        let (h, vm) = await authenticatedHarness()
        vm.openSettings()
        XCTAssertEqual(vm.uiState.dialogOpen, .settings)

        vm.openAutoActivitiesDialog()
        XCTAssertEqual(vm.uiState.dialogOpen, .autoActivities)
        h.teardown()
    }

    func test_scheduledPauseAndNotificationChangesPersistWithoutLosingProjects() async {
        let (h, vm) = await authenticatedHarness()

        vm.onScheduledPauseSettingChanged(
            enabled: true, from: "21:15", to: "06:45", suspendSat: false, suspendSun: true)
        vm.onNotificationSettingsChanged(activities: false, scheduledPause: true, accident: false)
        try? await Task.sleep(for: .milliseconds(100))

        let map = try! JSONCoding.decoder.decode(
            [String: UserSettings].self, from: Data((await h.prefs.userSettingsJson()).utf8))
        XCTAssertEqual(map["HR70"]?.projects, ["P80"])
        XCTAssertEqual(map["HR70"]?.scheduledPauseTo, "06:45")
        XCTAssertEqual(map["HR70"]?.suspendSaturdays, false)
        XCTAssertEqual(map["HR70"]?.notifyAccident, false)
        h.teardown()
    }

    func test_historyDialogFiltersTappedActivity() async {
        let (h, vm) = await authenticatedHarness()
        h.checkRepository.getHistoryResult = .success([
            CheckHistoryEntry(action: .checkIn, projeto: "P80", local: "Escritório", time: Date(), informe: .normal),
            CheckHistoryEntry(action: .checkOut, projeto: "P80", local: "Zona", time: Date(), informe: .normal),
        ])

        vm.openHistory(.checkIn)
        await settle { !vm.uiState.historyDialog.isLoading }

        XCTAssertEqual(vm.uiState.historyDialog.entries.map(\.action), [.checkIn])
        XCTAssertEqual(vm.uiState.dialogOpen, .history)
        h.teardown()
    }

    func test_activitiesDialogPagesNewestFirstAndClearsStore() async throws {
        let (h, vm) = await authenticatedHarness()
        for index in 0 ..< 35 {
            try h.activityLog.record(ActivityLogEntry(
                at: Date(timeIntervalSince1970: Double(index)), actor: .sys, kind: .trigger,
                severity: .info, description: "event-\(index)", location: nil))
        }

        vm.openActivitiesDialog()
        await settle { !vm.uiState.isActivitiesLoading && vm.uiState.activityEntries.count == 30 }
        XCTAssertEqual(vm.uiState.activityEntries.first?.description, "event-34")
        XCTAssertTrue(vm.uiState.activityCanLoadMore)

        vm.loadMoreActivities()
        await settle { !vm.uiState.isActivitiesLoading && vm.uiState.activityEntries.count == 35 }
        XCTAssertFalse(vm.uiState.activityCanLoadMore)

        vm.clearActivities()
        await settle { !vm.uiState.isActivitiesLoading && vm.uiState.activityEntries.isEmpty }
        XCTAssertEqual(h.activityLog.count(), 0)
        h.teardown()
    }

    func test_consentThenEnableStartsSignificantLocationMonitor() async {
        let (h, vm) = await authenticatedHarness()
        vm.recordBackgroundLocationConsent()

        let enabled = await vm.setAutomaticActivitiesEnabled(true)
        let monitorActive = await h.significantLocationMonitor.isActive()
        let registrations = await h.geofenceRegionManager.registrations
        XCTAssertTrue(enabled)
        XCTAssertTrue(monitorActive)
        XCTAssertTrue(registrations.contains {
            $0.chave == "HR70"
                && $0.hints.currentLocalName == "Escritório Principal"
                && $0.forceRefresh
        })
        XCTAssertTrue(vm.uiState.backgroundLocationConsentGranted)
        h.teardown()
    }

    func test_freshAuthenticatedSessionRestoresGeofencesWithoutTechnicalValidationScreen() async {
        let (h, _) = await authenticatedHarness(autoEnabled: true, consentGranted: true)
        try? await Task.sleep(for: .milliseconds(50))
        let registrations = await h.geofenceRegionManager.registrations

        XCTAssertFalse(registrations.isEmpty)
        XCTAssertEqual(registrations.last?.chave, "HR70")
        XCTAssertTrue(registrations.last?.forceRefresh == true)
        h.teardown()
    }

    func test_foregroundResumeReconcilesGeofences() async {
        let (h, vm) = await authenticatedHarness()
        vm.recordBackgroundLocationConsent()
        _ = await vm.setAutomaticActivitiesEnabled(true)
        let registrationsBefore = await h.geofenceRegionManager.registrations.count

        vm.onForegroundResume()
        try? await Task.sleep(for: .milliseconds(80))
        let registrationsAfter = await h.geofenceRegionManager.registrations.count

        XCTAssertGreaterThan(registrationsAfter, registrationsBefore)
        h.teardown()
    }

    func test_accountKeyChangeRemovesPreviousGeofences() async {
        let (h, vm) = await authenticatedHarness()
        vm.recordBackgroundLocationConsent()
        _ = await vm.setAutomaticActivitiesEnabled(true)
        let unregistersBefore = await h.geofenceRegionManager.unregisterCount

        vm.onChaveChanged("AB")
        try? await Task.sleep(for: .milliseconds(50))
        let unregistersAfter = await h.geofenceRegionManager.unregisterCount

        XCTAssertGreaterThan(unregistersAfter, unregistersBefore)
        h.teardown()
    }

    func test_disablingAutomaticActivitiesStopsBothNativeLocationServices() async {
        let (h, vm) = await authenticatedHarness()
        vm.recordBackgroundLocationConsent()
        _ = await vm.setAutomaticActivitiesEnabled(true)
        let unregistersBefore = await h.geofenceRegionManager.unregisterCount

        let disabled = await vm.setAutomaticActivitiesEnabled(false)
        let monitorActive = await h.significantLocationMonitor.isActive()
        let unregistersAfter = await h.geofenceRegionManager.unregisterCount

        XCTAssertTrue(disabled)
        XCTAssertFalse(monitorActive)
        XCTAssertGreaterThan(unregistersAfter, unregistersBefore)
        h.teardown()
    }

    func test_projectMembershipChangeReregistersGeofences() async {
        let (h, vm) = await authenticatedHarness()
        vm.recordBackgroundLocationConsent()
        _ = await vm.setAutomaticActivitiesEnabled(true)
        let registrationsBefore = await h.geofenceRegionManager.registrations.count
        h.projects.updateUserProjectsResult = .success(
            UserProjects(projects: ["P80", "P81"], activeProject: "P80"))

        vm.onProjectMembershipToggled("P81")
        await settle { !vm.uiState.isProjectsLoading }
        try? await Task.sleep(for: .milliseconds(50))
        let registrationsAfter = await h.geofenceRegionManager.registrations.count
        let lastRegistration = await h.geofenceRegionManager.registrations.last

        XCTAssertGreaterThan(registrationsAfter, registrationsBefore)
        XCTAssertTrue(lastRegistration?.forceRefresh == true)
        h.teardown()
    }

    func test_privacyLocalDeletionStopsMonitoringAndWipesDeviceStores() async throws {
        let (h, vm) = await authenticatedHarness()
        await h.offlineQueue.enqueue(.decided(PendingCheckEvent.Decided(
            chave: "HR70", projeto: "P80", capturedAtEpochMs: 1,
            clientEventId: "private-pending-event", action: "checkin",
            local: "Escritório Principal", informe: "normal")))
        try h.activityLog.record(ActivityLogEntry(
            at: Date(), actor: .user, kind: .trigger, severity: .info,
            description: "private local event", location: "Escritório Principal"))
        vm.recordBackgroundLocationConsent()
        _ = await vm.setAutomaticActivitiesEnabled(true)

        await vm.deleteLocalData()

        let monitoringActive = await h.significantLocationMonitor.isActive()
        let storedChave = await h.prefs.chave()
        let settingsJSON = await h.prefs.userSettingsJson()
        XCTAssertFalse(monitoringActive)
        XCTAssertEqual(storedChave, "")
        XCTAssertEqual(settingsJSON, "")
        XCTAssertTrue(h.passwords.getAllPasswords().isEmpty)
        XCTAssertEqual(h.offlineQueue.clearCount, 1)
        XCTAssertTrue(h.offlineQueue.enqueued.isEmpty)
        XCTAssertEqual(h.activityLog.count(), 0)
        XCTAssertEqual(vm.uiState.chave, "")
        XCTAssertFalse(vm.uiState.isAuthenticated)
        let geofenceUnregisterCount = await h.geofenceRegionManager.unregisterCount
        XCTAssertGreaterThan(geofenceUnregisterCount, 0)
        h.teardown()
    }

    func test_successfulAccountDeletionWipesOfflineQueue() async {
        let (h, vm) = await authenticatedHarness()
        await h.offlineQueue.enqueue(.decided(PendingCheckEvent.Decided(
            chave: "HR70", projeto: "P80", capturedAtEpochMs: 1,
            clientEventId: "private-pending-event", action: "checkin",
            local: "Escritório Principal", informe: "normal")))

        vm.deleteAccount()
        await settle { vm.uiState.chave.isEmpty }

        XCTAssertEqual(h.offlineQueue.clearCount, 1)
        XCTAssertTrue(h.offlineQueue.enqueued.isEmpty)
        XCTAssertFalse(vm.uiState.isAuthenticated)
        h.teardown()
    }

    func test_conflictedAccountDeletionPreservesOfflineQueueAndSession() async {
        let (h, vm) = await authenticatedHarness()
        h.auth.deleteResult = .failure(.conflict)
        await h.offlineQueue.enqueue(.decided(PendingCheckEvent.Decided(
            chave: "HR70", projeto: "P80", capturedAtEpochMs: 1,
            clientEventId: "private-pending-event", action: "checkin",
            local: "Escritório Principal", informe: "normal")))

        vm.deleteAccount()
        await settle { vm.uiState.notificationTone == .error }

        XCTAssertEqual(h.offlineQueue.clearCount, 0)
        XCTAssertEqual(h.offlineQueue.enqueued.count, 1)
        XCTAssertTrue(vm.uiState.isAuthenticated)
        h.teardown()
    }
}
