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
        submitResult: AppResult<HistoryState>? = nil,
        userProjects: UserProjects = UserProjects(projects: ["P80"], activeProject: "P80")
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
        h.projects.userProjectsResult = .success(userProjects)
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
        await settle {
            vm.uiState.isAuthenticated
                && vm.uiState.userProjects != nil
                && !vm.uiState.isProjectsLoading
                && (vm.uiState.userProjects?.projects.isEmpty == true
                    || !vm.uiState.availableLocations.isEmpty)
        }
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

    func test_authenticationWithoutMembershipShowsSpecificMessageAndPersistsEmptyState() async {
        let (h, vm) = await authenticatedHarness(
            userProjects: UserProjects(projects: [], activeProject: ""))

        XCTAssertEqual(vm.uiState.userProjects, UserProjects(projects: [], activeProject: ""))
        XCTAssertEqual(
            vm.uiState.notificationPrimary,
            "O usuário não está cadastrado em nenhum projeto.")
        XCTAssertEqual(vm.uiState.notificationTone, .error)
        XCTAssertTrue(vm.uiState.availableLocations.isEmpty)

        let map = try? JSONCoding.decoder.decode(
            [String: UserSettings].self,
            from: Data((await h.prefs.userSettingsJson()).utf8))
        XCTAssertEqual(map?["HR70"]?.projects, [])
        XCTAssertEqual(map?["HR70"]?.activeProject, "")
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

    func test_removingLastProjectPersistsEmptyMemberships() async {
        let (h, vm) = await authenticatedHarness()
        h.projects.updateUserProjectsResult = .success(UserProjects(projects: [], activeProject: ""))
        vm.onProjectMembershipToggled("P80")
        await settle { !vm.uiState.isProjectMembershipSyncing }

        XCTAssertEqual(h.projects.updateUserProjectsCalls, [[]])
        XCTAssertEqual(vm.uiState.userProjects, UserProjects(projects: [], activeProject: ""))
        let map = try? JSONCoding.decoder.decode(
            [String: UserSettings].self,
            from: Data((await h.prefs.userSettingsJson()).utf8))
        XCTAssertEqual(map?["HR70"]?.projects, [])
        XCTAssertEqual(map?["HR70"]?.activeProject, "")
        XCTAssertEqual(
            vm.uiState.notificationPrimary,
            t("projects.noActiveProject", lang: "pt"))
        XCTAssertEqual(vm.uiState.notificationTone, .error)
        XCTAssertEqual(h.orchestrator.invalidateAccuracyRetryCount, 1)
        h.teardown()
    }

    func test_addingMembershipUpdatesServerStateAndClearsManualLocation() async {
        let (h, vm) = await authenticatedHarness()
        vm.onManualLocationSelected("Escritório Principal")
        h.projects.updateUserProjectsResult = .success(UserProjects(projects: ["P80", "P81"], activeProject: "P80"))
        vm.onProjectMembershipToggled("P81")
        await settle { vm.uiState.userProjects?.projects == ["P80", "P81"] && !vm.uiState.isProjectMembershipSyncing }

        XCTAssertEqual(h.projects.updateUserProjectsCalls, [["P80", "P81"]])
        XCTAssertNil(vm.uiState.selectedManualLocation)
        XCTAssertEqual(h.orchestrator.invalidateAccuracyRetryCount, 0)
        h.teardown()
    }

    func test_rapidSelectionsFromEmptyAreCoalescedAndBothPersist() async {
        let (h, vm) = await authenticatedHarness(
            userProjects: UserProjects(projects: [], activeProject: ""))
        h.projects.updateUserProjectsResult = .success(
            UserProjects(projects: ["P80", "P81"], activeProject: "P80"))

        vm.onProjectMembershipToggled("P80")
        vm.onProjectMembershipToggled("P81")
        await settle { !vm.uiState.isProjectMembershipSyncing }

        XCTAssertEqual(h.projects.updateUserProjectsCalls, [["P80", "P81"]])
        XCTAssertEqual(
            vm.uiState.userProjects,
            UserProjects(projects: ["P80", "P81"], activeProject: "P80"))
        h.teardown()
    }

    func test_serverResponseIsAuthoritativeAfterMembershipUpdate() async {
        let (h, vm) = await authenticatedHarness()
        h.projects.updateUserProjectsResult = .success(
            UserProjects(projects: ["P81"], activeProject: "P81"))

        vm.onProjectMembershipToggled("P81")
        await settle { !vm.uiState.isProjectMembershipSyncing }

        XCTAssertEqual(h.projects.updateUserProjectsCalls, [["P80", "P81"]])
        XCTAssertEqual(vm.uiState.userProjects, UserProjects(projects: ["P81"], activeProject: "P81"))
        h.teardown()
    }

    func test_updateFailureRollsBackOptimisticMembershipSelection() async {
        let (h, vm) = await authenticatedHarness()
        h.projects.updateUserProjectsResult = .failure(.network)
        vm.onManualLocationSelected("Unidade P80")

        vm.onProjectMembershipToggled("P81")
        XCTAssertEqual(vm.uiState.userProjects?.projects, ["P80", "P81"])
        await settle { !vm.uiState.isProjectMembershipSyncing }

        XCTAssertEqual(vm.uiState.userProjects, UserProjects(projects: ["P80"], activeProject: "P80"))
        XCTAssertEqual(vm.uiState.selectedManualLocation, "Unidade P80")
        XCTAssertEqual(vm.uiState.notificationPrimary, t("projects.updateFailed", lang: "pt"))
        XCTAssertEqual(vm.uiState.notificationTone, .error)
        h.teardown()
    }

    func test_toggleDuringInFlightUpdateQueuesOrderedAuthoritativePut() async {
        let (h, vm) = await authenticatedHarness()
        let firstGate = AsyncGate()
        h.projects.firstUpdateUserProjectsGate = firstGate
        h.projects.updateUserProjectsResults = [
            .success(UserProjects(projects: ["P80", "P81"], activeProject: "P80")),
            .success(UserProjects(projects: ["P81"], activeProject: "P81")),
        ]

        vm.onProjectMembershipToggled("P81")
        await settle { h.projects.updateUserProjectsCalls.count == 1 }
        vm.onProjectMembershipToggled("P80")
        XCTAssertEqual(vm.uiState.userProjects?.projects, ["P81"])
        await firstGate.release()
        await settle { !vm.uiState.isProjectMembershipSyncing }

        XCTAssertEqual(h.projects.updateUserProjectsCalls, [["P80", "P81"], ["P81"]])
        XCTAssertEqual(vm.uiState.userProjects, UserProjects(projects: ["P81"], activeProject: "P81"))
        h.teardown()
    }

    func test_secondSelectionFromEmptyDuringFirstPutPersistsBothProjects() async {
        let (h, vm) = await authenticatedHarness(
            userProjects: UserProjects(projects: [], activeProject: ""))
        let firstGate = AsyncGate()
        h.projects.firstUpdateUserProjectsGate = firstGate
        h.projects.updateUserProjectsResults = [
            .success(UserProjects(projects: ["P80"], activeProject: "P80")),
            .success(UserProjects(projects: ["P80", "P81"], activeProject: "P80")),
        ]

        vm.onProjectMembershipToggled("P80")
        await settle { h.projects.updateUserProjectsCalls.count == 1 }
        vm.onProjectMembershipToggled("P81")
        XCTAssertEqual(vm.uiState.userProjects?.projects, ["P80", "P81"])
        await firstGate.release()
        await settle { !vm.uiState.isProjectMembershipSyncing }

        XCTAssertEqual(h.projects.updateUserProjectsCalls, [["P80"], ["P80", "P81"]])
        XCTAssertEqual(
            vm.uiState.userProjects,
            UserProjects(projects: ["P80", "P81"], activeProject: "P80"))
        h.teardown()
    }

    func test_lateMembershipResponseAfterAccountChangeIsIgnored() async {
        let (h, vm) = await authenticatedHarness()
        let firstGate = AsyncGate()
        h.projects.firstUpdateUserProjectsGate = firstGate

        vm.onProjectMembershipToggled("P81")
        await settle { h.projects.updateUserProjectsCalls.count == 1 }
        vm.onChaveChanged("NEW1")
        await firstGate.release()
        await settle { vm.uiState.chave == "NEW1" && !vm.uiState.isProjectMembershipSyncing }

        XCTAssertNil(vm.uiState.userProjects)
        XCTAssertTrue(vm.uiState.mainProjectCatalog.isEmpty)
        h.teardown()
    }

    func test_submitStaysDisabledUntilMembershipUpdateIsConfirmed() async {
        let (h, vm) = await authenticatedHarness()
        let gate = AsyncGate()
        h.projects.firstUpdateUserProjectsGate = gate
        vm.onActionSelected(.checkOut)

        vm.onProjectMembershipToggled("P81")
        await settle { h.projects.updateUserProjectsCalls.count == 1 }

        XCTAssertTrue(vm.uiState.isProjectMembershipSyncing)
        XCTAssertFalse(vm.uiState.canSubmit)

        await gate.release()
        await settle { !vm.uiState.isProjectMembershipSyncing }
        XCTAssertTrue(vm.uiState.canSubmit)
        h.teardown()
    }

    func test_manualSubmitWithoutMembershipDoesNotCallRepositoryAndExplainsWhy() async {
        let (h, vm) = await authenticatedHarness(
            userProjects: UserProjects(projects: [], activeProject: ""))
        vm.onActionSelected(.checkOut)

        vm.onSubmit()

        XCTAssertEqual(h.checkRepository.submitCount, 0)
        XCTAssertEqual(
            vm.uiState.notificationPrimary,
            t("projects.noActiveProject", lang: "pt"))
        XCTAssertNotEqual(
            vm.uiState.notificationPrimary,
            t("status.submitFailed", lang: "pt"))
        XCTAssertEqual(vm.uiState.notificationTone, .error)
        h.teardown()
    }

    func test_submitConflictRefreshesStaleMembershipAndExplainsNoProject() async {
        let (h, vm) = await authenticatedHarness(submitResult: .failure(.conflict))
        h.projects.userProjectsResult = .success(UserProjects(projects: [], activeProject: ""))
        vm.onManualLocationSelected("Unidade P80")

        vm.onSubmit()
        await settle {
            !vm.uiState.isSubmitting
                && vm.uiState.userProjects == UserProjects(projects: [], activeProject: "")
        }

        XCTAssertEqual(h.checkRepository.submitCount, 1)
        XCTAssertEqual(
            vm.uiState.notificationPrimary,
            t("projects.noActiveProject", lang: "pt"))
        XCTAssertNotEqual(
            vm.uiState.notificationPrimary,
            t("status.submitFailed", lang: "pt"))
        let map = try? JSONCoding.decoder.decode(
            [String: UserSettings].self,
            from: Data((await h.prefs.userSettingsJson()).utf8))
        XCTAssertEqual(map?["HR70"]?.projects, [])
        XCTAssertEqual(map?["HR70"]?.activeProject, "")
        h.teardown()
    }

    func test_toggleDuringReconciliationThenFailureRollsBackAndReconcilesAuthoritativeStateAgain() async {
        let (h, vm) = await authenticatedHarness()
        await settle { !h.orchestrator.runOnceCalls.isEmpty }
        let runsBefore = h.orchestrator.runOnceCalls.count
        let reconciliationGate = AsyncGate()
        h.orchestrator.nextRunGate = reconciliationGate
        h.projects.updateUserProjectsResults = [
            .success(UserProjects(projects: ["P80", "P81"], activeProject: "P80")),
            .failure(.network),
        ]

        vm.onProjectMembershipToggled("P81")
        await settle { h.orchestrator.runOnceCalls.count == runsBefore + 1 }
        vm.onProjectMembershipToggled("P80")
        XCTAssertEqual(vm.uiState.userProjects?.projects, ["P81"])

        await reconciliationGate.release()
        await settle { !vm.uiState.isProjectMembershipSyncing }

        XCTAssertEqual(h.projects.updateUserProjectsCalls, [["P80", "P81"], ["P81"]])
        XCTAssertEqual(
            vm.uiState.userProjects,
            UserProjects(projects: ["P80", "P81"], activeProject: "P80"))
        XCTAssertGreaterThanOrEqual(h.orchestrator.runOnceCalls.count, runsBefore + 2)
        XCTAssertEqual(vm.uiState.notificationPrimary, t("projects.updateFailed", lang: "pt"))
        h.teardown()
    }

    func test_successAfterIntermediateFailureClearsStaleUpdateError() async {
        let (h, vm) = await authenticatedHarness()
        let firstGate = AsyncGate()
        h.projects.firstUpdateUserProjectsGate = firstGate
        h.projects.updateUserProjectsResults = [
            .failure(.network),
            .success(UserProjects(projects: ["P81"], activeProject: "P81")),
        ]

        vm.onProjectMembershipToggled("P81")
        await settle { h.projects.updateUserProjectsCalls.count == 1 }
        vm.onProjectMembershipToggled("P80")
        await firstGate.release()
        await settle { !vm.uiState.isProjectMembershipSyncing }

        XCTAssertEqual(vm.uiState.userProjects, UserProjects(projects: ["P81"], activeProject: "P81"))
        XCTAssertNotEqual(vm.uiState.notificationPrimary, t("projects.updateFailed", lang: "pt"))
        XCTAssertNotEqual(vm.uiState.notificationTone, .error)
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
        XCTAssertEqual(h.orchestrator.invalidateAccuracyRetryCount, 1)
        XCTAssertEqual(h.orchestrator.acceptedChecks.count, 1)
        XCTAssertEqual(h.orchestrator.acceptedChecks.first?.0, "HR70")
        XCTAssertEqual(h.orchestrator.acceptedChecks.first?.1, "P80")
        XCTAssertEqual(h.orchestrator.acceptedChecks.first?.2, .checkIn)
        XCTAssertEqual(h.orchestrator.acceptedChecks.first?.3, newHistory)
        h.teardown()
    }

    func test_manualSuccessInvalidatesAccuracyRetryOnlyAfterServerConfirmation() async {
        let gate = AsyncGate()
        let (h, vm) = await authenticatedHarness(submitResult: .success(history(action: .checkIn)))
        h.checkRepository.submitGate = gate
        vm.onManualLocationSelected("Unidade P80")

        vm.onSubmit()
        await settle { h.checkRepository.submitCount == 1 }
        XCTAssertEqual(h.orchestrator.invalidateAccuracyRetryCount, 0)

        await gate.release()
        await settle { h.orchestrator.invalidateAccuracyRetryCount == 1 }
        XCTAssertEqual(h.orchestrator.invalidateAccuracyRetryCount, 1)
        h.teardown()
    }

    func test_manualCheckoutWithoutSelectionUsesUnknownLocation() async {
        let (h, vm) = await authenticatedHarness(submitResult: .success(history()))
        vm.onManualLocationSelected("Escritório Principal")
        vm.onProjectMembershipToggled("P81")
        await settle { !vm.uiState.isProjectMembershipSyncing }
        vm.onActionSelected(.checkOut)
        vm.onSubmit()
        await settle { h.checkRepository.submitCount == 1 }

        XCTAssertEqual(h.checkRepository.submitCalls.first?.local, "Desconhecido")
        h.teardown()
    }

    func test_networkFailureQueuesSameDecidedEventIdentityAndTimestamp() async {
        let (h, vm) = await authenticatedHarness(submitResult: .failure(.network))
        let enqueueGate = AsyncGate()
        h.offlineQueue.enqueueGate = enqueueGate
        vm.onManualLocationSelected("Unidade P80")
        vm.onSubmit()
        await settle { h.checkRepository.submitCount == 1 }
        XCTAssertEqual(h.orchestrator.invalidateAccuracyRetryCount, 0)

        await enqueueGate.release()
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
        XCTAssertEqual(h.orchestrator.invalidateAccuracyRetryCount, 1)
        XCTAssertTrue(h.orchestrator.acceptedChecks.isEmpty)
        h.teardown()
    }

    func test_manualRejectedSubmissionsDoNotInvalidateAccuracyRetry() async {
        let failures: [ApiError] = [
            .unauthorized,
            .conflict,
            .http(status: 422, detail: "invalid"),
        ]

        for failure in failures {
            let (h, vm) = await authenticatedHarness(submitResult: .failure(failure))
            vm.onManualLocationSelected("Unidade P80")

            vm.onSubmit()
            await settle {
                h.checkRepository.submitCount == 1
                    && (!vm.uiState.isSubmitting || !vm.uiState.isAuthenticated)
            }

            if case .unauthorized = failure {
                await settle { h.orchestrator.invalidateAccuracyRetryCount == 1 }
                XCTAssertEqual(h.orchestrator.invalidateAccuracyRetryCount, 1)
            } else {
                XCTAssertEqual(h.orchestrator.invalidateAccuracyRetryCount, 0, "\(failure)")
            }
            h.teardown()
        }
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

    func test_scheduledPauseChangePersistsAndRequestsImmediateReconciliation() async {
        let (h, vm) = await authenticatedHarness()
        try? await Task.sleep(for: .milliseconds(50))
        let initialRuns = h.orchestrator.runOnceCalls.count
        let runGate = AsyncGate()
        h.orchestrator.nextRunGate = runGate

        vm.onScheduledPauseSettingChanged(
            enabled: false,
            from: "00:00",
            to: "00:00",
            suspendSat: false,
            suspendSun: true)
        await settle {
            h.orchestrator.scheduledPauseSettingsChangeCount == 1
                && h.orchestrator.runOnceCalls.count == initialRuns + 1
        }
        await runGate.release()
        try? await Task.sleep(for: .milliseconds(50))

        let map = try! JSONCoding.decoder.decode(
            [String: UserSettings].self,
            from: Data((await h.prefs.userSettingsJson()).utf8))
        XCTAssertEqual(map["HR70"]?.suspendSundays, true)
        XCTAssertEqual(h.orchestrator.scheduledPauseSettingsChangeCount, 1)
        XCTAssertEqual(
            h.orchestrator.runOnceCalls.dropFirst(initialRuns).filter { $0 == .foreground }.count,
            1)
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

    func test_foregroundResumeRefreshesMembershipRemovedByAnotherClient() async {
        let (h, vm) = await authenticatedHarness()
        h.projects.userProjectsResult = .success(UserProjects(projects: [], activeProject: ""))
        let invalidationsBefore = h.orchestrator.invalidateAccuracyRetryCount

        vm.onForegroundResume()
        await settle {
            vm.uiState.userProjects == UserProjects(projects: [], activeProject: "")
                && vm.uiState.notificationPrimary == t("projects.noActiveProject", lang: "pt")
                && !vm.uiState.isProjectsLoading
        }

        XCTAssertTrue(vm.uiState.availableLocations.isEmpty)
        let map = try? JSONCoding.decoder.decode(
            [String: UserSettings].self,
            from: Data((await h.prefs.userSettingsJson()).utf8))
        XCTAssertEqual(map?["HR70"]?.projects, [])
        XCTAssertEqual(map?["HR70"]?.activeProject, "")
        XCTAssertEqual(h.orchestrator.invalidateAccuracyRetryCount, invalidationsBefore + 1)
        h.teardown()
    }

    func test_foregroundMembershipRefreshWithSameActiveProjectKeepsRetryEpisode() async {
        let (h, vm) = await authenticatedHarness()
        let projectLoadsBefore = h.projects.getUserProjectsCallCount
        let invalidationsBefore = h.orchestrator.invalidateAccuracyRetryCount

        vm.onForegroundResume()
        await settle {
            h.projects.getUserProjectsCallCount > projectLoadsBefore
                && !vm.uiState.isProjectsLoading
        }

        XCTAssertEqual(h.orchestrator.invalidateAccuracyRetryCount, invalidationsBefore)
        h.teardown()
    }

    func test_enablingAutomaticActivitiesWithoutMembershipShowsSpecificMessage() async {
        let (h, vm) = await authenticatedHarness(
            userProjects: UserProjects(projects: [], activeProject: ""))
        let projectLoadsBefore = h.projects.getUserProjectsCallCount

        vm.toggleAutomaticActivities(true)
        await settle {
            h.projects.getUserProjectsCallCount > projectLoadsBefore
                && vm.uiState.notificationPrimary == t("projects.noActiveProject", lang: "pt")
        }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(vm.uiState.automaticActivitiesEnabled)
        XCTAssertNotEqual(
            vm.uiState.notificationPrimary,
            t("autoActivities.enableFailed", lang: "pt"))
        XCTAssertEqual(vm.uiState.notificationTone, .error)
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
        let invalidationsBefore = h.orchestrator.invalidateAccuracyRetryCount

        let disabled = await vm.setAutomaticActivitiesEnabled(false)
        let monitorActive = await h.significantLocationMonitor.isActive()
        let unregistersAfter = await h.geofenceRegionManager.unregisterCount

        XCTAssertTrue(disabled)
        XCTAssertFalse(monitorActive)
        XCTAssertGreaterThan(unregistersAfter, unregistersBefore)
        XCTAssertEqual(h.orchestrator.invalidateAccuracyRetryCount, invalidationsBefore + 1)
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
        await settle { !vm.uiState.isProjectMembershipSyncing }
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
