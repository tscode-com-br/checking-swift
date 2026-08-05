import Foundation
import XCTest
@testable import Checking

@MainActor
final class CheckViewModelHeadlessLifecycleTests: XCTestCase {
    private let storedChave = "AAAA"
    private let storedPassword = "abc123"

    private func seedStoredSession(
        _ harness: VMHarness,
        automaticActivitiesEnabled: Bool = false
    ) async {
        await harness.prefs.setChave(storedChave)
        harness.passwords.seed(storedChave, storedPassword)
        let settings = UserSettings(
            projects: ["P80"],
            activeProject: "P80",
            automaticActivitiesEnabled: automaticActivitiesEnabled
        )
        let data = try! JSONCoding.encoder.encode([storedChave: settings])
        await harness.prefs.setUserSettingsJson(String(data: data, encoding: .utf8)!)
        harness.projects.userProjectsResult = .success(
            UserProjects(projects: ["P80"], activeProject: "P80")
        )
        harness.projects.result = .success([
            Project(id: 1, name: "P80", transportEnabled: false),
        ])
        harness.auth.historyResult = .success(history(chave: storedChave))
    }

    private func history(
        chave: String,
        action: CheckAction = .checkOut
    ) -> HistoryState {
        HistoryState(
            found: true,
            chave: chave,
            projeto: "P80",
            currentAction: action,
            currentLocal: "Escritório Principal",
            hasCurrentDayCheckin: action == .checkIn,
            lastCheckinAt: action == .checkIn ? Date(timeIntervalSince1970: 10) : nil,
            lastCheckoutAt: action == .checkOut ? Date(timeIntervalSince1970: 20) : nil,
            transportEnabled: false
        )
    }

    private func authenticatedStatus(
        chave: String,
        hasPassword: Bool = true
    ) -> AuthStatus {
        AuthStatus(
            found: true,
            chave: chave,
            hasPassword: hasPassword,
            authenticated: true,
            message: ""
        )
    }

    func test_candidateBackgroundInitRestoresOnlyLocalStateWithZeroRemoteEffects() async {
        let harness = VMHarness()
        await seedStoredSession(harness, automaticActivitiesEnabled: true)
        let permissions = ControlledPermissionsInspector(status: harness.permissions)
        let stream = SpyCheckEventStream()
        let viewModel = harness.build(
            backgroundReliabilityProfile: .candidate,
            permissionsInspector: permissions,
            checkEventStream: stream
        )

        await settle { !viewModel.uiState.isInitializing }
        await viewModel.sceneStateDidChange(.background)
        await viewModel.sceneStateDidChange(.background)
        viewModel.onForegroundResume() // simula um onAppear antigo: candidato deve ignorá-lo.

        XCTAssertEqual(viewModel.uiState.chave, storedChave)
        XCTAssertEqual(viewModel.uiState.password, storedPassword)
        XCTAssertTrue(viewModel.uiState.automaticActivitiesEnabled)
        XCTAssertTrue(harness.auth.statusCalls.isEmpty)
        XCTAssertEqual(harness.auth.logoutCallCount, 0)
        XCTAssertTrue(harness.auth.loginCalls.isEmpty)
        XCTAssertEqual(harness.auth.getHistoryCallCount, 0)
        XCTAssertEqual(harness.projects.getUserProjectsCallCount, 0)
        XCTAssertEqual(harness.projects.listProjectsCallCount, 0)
        let permissionCalls = await permissions.callCount
        let monitorStarts = await harness.significantLocationMonitor.startCount
        let monitorStops = await harness.significantLocationMonitor.stopCount
        let geofenceRegistrations = await harness.geofenceRegionManager.registrations
        let geofenceUnregisters = await harness.geofenceRegionManager.unregisterCount
        let journalRecords = await harness.evaluationJournal.recent(limit: 1)
        XCTAssertEqual(permissionCalls, 0)
        XCTAssertEqual(harness.captureLocation.callCount, 0)
        XCTAssertTrue(stream.calls.isEmpty)
        XCTAssertTrue(harness.orchestrator.runOnceCalls.isEmpty)
        XCTAssertEqual(monitorStarts, 0)
        XCTAssertEqual(monitorStops, 0)
        XCTAssertTrue(geofenceRegistrations.isEmpty)
        XCTAssertEqual(geofenceUnregisters, 0)
        XCTAssertTrue(journalRecords.isEmpty)
        harness.teardown()
    }

    func test_firstActiveIsSingleFlightAndPreservesPersistedSessionCookie() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        let statusGate = AsyncGate()
        harness.auth.statusGates[storedChave] = statusGate
        harness.auth.statusResults[storedChave] = .success(
            AuthStatus(
                found: true,
                chave: storedChave,
                hasPassword: true,
                authenticated: false,
                message: ""
            )
        )
        harness.auth.loginResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave)
        )
        let permissions = ControlledPermissionsInspector(status: harness.permissions)
        let stream = SpyCheckEventStream()
        let viewModel = harness.build(
            backgroundReliabilityProfile: .candidate,
            permissionsInspector: permissions,
            checkEventStream: stream
        )
        await settle { !viewModel.uiState.isInitializing }

        let first = Task { await viewModel.sceneStateDidChange(.active) }
        await settle { harness.auth.statusCalls.count == 1 }
        let duplicate = Task { await viewModel.sceneStateDidChange(.active) }
        await Task.yield()
        XCTAssertEqual(harness.auth.statusCalls, [storedChave])

        await statusGate.release()
        await first.value
        await duplicate.value
        await viewModel.sceneStateDidChange(.active)

        XCTAssertTrue(viewModel.uiState.isAuthenticated)
        XCTAssertEqual(harness.auth.statusCalls, [storedChave])
        XCTAssertEqual(harness.auth.logoutCallCount, 0)
        XCTAssertEqual(harness.auth.loginCalls.map(\.chave), [storedChave])
        XCTAssertEqual(harness.auth.getHistoryCallCount, 1)
        XCTAssertEqual(harness.projects.getUserProjectsCallCount, 1)
        XCTAssertEqual(harness.projects.listProjectsCallCount, 1)
        let permissionCalls = await permissions.callCount
        XCTAssertEqual(permissionCalls, 1)
        XCTAssertEqual(stream.calls, [storedChave])
        XCTAssertEqual(harness.orchestrator.runOnceCalls, [.foreground])
        harness.teardown()
    }

    func test_activeSavedLoginCoalescesWithBackgroundSilentRelogin() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        let statusGate = AsyncGate()
        let loginGate = AsyncGate()
        harness.auth.statusGates[storedChave] = statusGate
        harness.auth.loginGates[storedChave] = loginGate
        harness.auth.statusResults[storedChave] = .success(
            AuthStatus(
                found: true,
                chave: storedChave,
                hasPassword: true,
                authenticated: false,
                message: ""
            )
        )
        harness.auth.loginResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave)
        )
        let coordinator = AuthSessionCoordinator(
            authRepository: harness.auth,
            securePasswordStore: harness.passwords,
            cookieStore: InMemorySessionCookieStore()
        )
        let viewModel = harness.build(
            backgroundReliabilityProfile: .candidate,
            authSessionCoordinator: coordinator
        )
        await settle { !viewModel.uiState.isInitializing }

        let activation = Task {
            await viewModel.sceneStateDidChange(.active)
        }
        await settle { harness.auth.statusCalls == [storedChave] }

        // Simula um 401 do motor enquanto o probe ativo ainda aguarda a resposta. O auto-login salvo da
        // UI deve entrar no mesmo slot de refresh, não abrir um segundo POST de login.
        let backgroundRefresh = Task {
            await coordinator.silentRelogin(self.storedChave)
        }
        await settle { harness.auth.loginCalls.count == 1 }
        await statusGate.release()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(harness.auth.loginCalls.count, 1)

        await loginGate.release()
        let backgroundResult = await backgroundRefresh.value
        await activation.value

        XCTAssertEqual(
            backgroundResult,
            .refreshed(authenticatedStatus(chave: storedChave))
        )
        XCTAssertEqual(harness.auth.loginCalls.map(\.chave), [storedChave])
        XCTAssertEqual(harness.auth.loginCalls.map(\.password), [storedPassword])
        XCTAssertEqual(harness.auth.logoutCallCount, 0)
        XCTAssertTrue(viewModel.uiState.isAuthenticated)
        harness.teardown()
    }

    func test_authenticatedCookieWithoutStoredPasswordHydratesWithoutLogin() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        harness.passwords.removePassword(storedChave)
        harness.auth.statusResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave, hasPassword: true)
        )
        let permissions = ControlledPermissionsInspector(status: harness.permissions)
        let stream = SpyCheckEventStream()
        let viewModel = harness.build(
            backgroundReliabilityProfile: .candidate,
            permissionsInspector: permissions,
            checkEventStream: stream
        )
        await settle { !viewModel.uiState.isInitializing }

        await viewModel.sceneStateDidChange(.active)

        XCTAssertTrue(viewModel.uiState.isAuthenticated)
        XCTAssertTrue(harness.auth.loginCalls.isEmpty)
        XCTAssertEqual(harness.auth.logoutCallCount, 0)
        XCTAssertEqual(harness.auth.getHistoryCallCount, 1)
        XCTAssertEqual(harness.projects.getUserProjectsCallCount, 1)
        let permissionCalls = await permissions.callCount
        XCTAssertEqual(permissionCalls, 1)
        XCTAssertEqual(stream.calls, [storedChave])
        harness.teardown()
    }

    func test_eachRealReactivationReconcilesOnceWithoutRepeatingLogin() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        harness.auth.statusResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave, hasPassword: false)
        )
        harness.checkRepository.getStateResult = .success(history(chave: storedChave))
        let permissions = ControlledPermissionsInspector(status: harness.permissions)
        let stream = SpyCheckEventStream()
        let viewModel = harness.build(
            backgroundReliabilityProfile: .candidate,
            permissionsInspector: permissions,
            checkEventStream: stream
        )
        await settle { !viewModel.uiState.isInitializing }
        await viewModel.sceneStateDidChange(.active)

        let projectsBefore = harness.projects.getUserProjectsCallCount
        let permissionsBefore = await permissions.callCount
        let streamsBefore = stream.calls.count
        let foregroundBefore = harness.orchestrator.runOnceCalls.count
        await viewModel.sceneStateDidChange(.background)
        await viewModel.sceneStateDidChange(.active)
        await viewModel.sceneStateDidChange(.active)

        XCTAssertEqual(harness.auth.statusCalls.count, 1)
        XCTAssertTrue(harness.auth.loginCalls.isEmpty)
        XCTAssertEqual(harness.auth.getHistoryCallCount, 1)
        XCTAssertEqual(harness.checkRepository.getStateCallCount, 1)
        XCTAssertEqual(
            harness.projects.getUserProjectsCallCount,
            projectsBefore + 1
        )
        let permissionCalls = await permissions.callCount
        XCTAssertEqual(permissionCalls, permissionsBefore + 1)
        XCTAssertEqual(stream.calls.count, streamsBefore + 1)
        XCTAssertEqual(
            harness.orchestrator.runOnceCalls.count,
            foregroundBefore + 1
        )
        harness.teardown()
    }

    func test_pendingApprovalPollingRunsOnlyWhileActiveAndNeverLogsOutCurrentSession() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        harness.auth.statusResults[storedChave] = .success(
            AuthStatus(
                found: false,
                chave: storedChave,
                hasPassword: false,
                authenticated: false,
                message: "",
                pendingApproval: true
            )
        )
        let sleeper = ControlledAccuracyRetrySleeper()
        let viewModel = harness.build(
            backgroundReliabilityProfile: .candidate,
            approvalPollingSleeper: sleeper
        )
        await settle { !viewModel.uiState.isInitializing }
        XCTAssertTrue(harness.auth.statusCalls.isEmpty)

        await viewModel.sceneStateDidChange(.active)
        let pollStarted = await waitUntil { await sleeper.waitingCount() == 1 }
        XCTAssertTrue(pollStarted)
        XCTAssertEqual(harness.auth.statusCalls.count, 1)
        XCTAssertEqual(harness.auth.logoutCallCount, 0)

        await viewModel.sceneStateDidChange(.background)
        await sleeper.releaseNext()
        await Task.yield()
        XCTAssertEqual(
            harness.auth.statusCalls.count,
            1,
            "poll cancelado em background não pode iniciar novo probe"
        )

        harness.auth.statusResults[storedChave] = .success(
            AuthStatus(
                found: false,
                chave: storedChave,
                hasPassword: false,
                authenticated: false,
                message: "",
                pendingApproval: false
            )
        )
        await viewModel.sceneStateDidChange(.active)
        XCTAssertEqual(harness.auth.statusCalls.count, 2)
        XCTAssertEqual(harness.auth.logoutCallCount, 0)
        harness.teardown()
    }

    func test_legacyRestoreAbortedByEditedKeyDoesNotProbeTheNewKeyTwice() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        harness.auth.statusResults["BBBB"] = .success(
            AuthStatus(
                found: false,
                chave: "BBBB",
                hasPassword: false,
                authenticated: false,
                message: ""
            )
        )
        let chaveGate = AsyncGate()
        let preferences = GatedChavePreferences(
            base: harness.prefs,
            gate: chaveGate
        )
        let viewModel = harness.build(
            backgroundReliabilityProfile: .legacyWithDiagnostics,
            appPreferences: preferences
        )

        await preferences.waitUntilChaveReadStarted()
        viewModel.onChaveChanged("BBBB")
        await chaveGate.release()
        let probed = await waitUntil { harness.auth.statusCalls.count == 1 }
        XCTAssertTrue(probed)
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(harness.auth.statusCalls, ["BBBB"])
        XCTAssertEqual(harness.auth.logoutCallCount, 1)
        XCTAssertTrue(harness.auth.loginCalls.isEmpty)
        XCTAssertFalse(viewModel.uiState.isInitializing)
        harness.teardown()
    }

    func test_validKeyThroughIntermediateInputKeepsContextBarrierUntilLatestIdentityIsPersisted() async {
        let harness = VMHarness()
        harness.auth.statusResults["AAAA"] = .success(
            AuthStatus(
                found: false,
                chave: "AAAA",
                hasPassword: false,
                authenticated: false,
                message: ""
            )
        )
        harness.auth.statusResults["BCDE"] = .success(
            AuthStatus(
                found: false,
                chave: "BCDE",
                hasPassword: false,
                authenticated: false,
                message: ""
            )
        )
        let viewModel = harness.build(
            backgroundReliabilityProfile: .legacyWithDiagnostics
        )
        await settle { !viewModel.uiState.isInitializing }
        viewModel.onChaveChanged("AAAA")
        let firstProbeCompleted = await waitUntil {
            harness.auth.statusCalls == ["AAAA"]
        }
        XCTAssertTrue(firstProbeCompleted)

        let logoutGate = AsyncGate()
        let logoutBeforeTransition = harness.auth.logoutCallCount
        harness.auth.nextLogoutGate = logoutGate
        viewModel.onChaveChanged("B")
        let invalidationReachedLogout = await waitUntil {
            harness.auth.logoutCallCount == logoutBeforeTransition + 1
        }
        XCTAssertTrue(invalidationReachedLogout)

        viewModel.onChaveChanged("BCDE")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertGreaterThan(
            harness.orchestrator.beginAutomationContextTransitionCount,
            harness.orchestrator.endAutomationContextTransitionCount,
            "o owner da identidade anterior não pode reabrir o barrier antes do logout"
        )

        await logoutGate.release()
        let latestIdentityCompleted = await waitUntil {
            viewModel.uiState.chave == "BCDE"
                && harness.auth.statusCalls.contains("BCDE")
                && harness.orchestrator.beginAutomationContextTransitionCount
                    == harness.orchestrator.endAutomationContextTransitionCount
        }
        let persistedChave = await harness.prefs.chave()
        XCTAssertTrue(latestIdentityCompleted)
        XCTAssertEqual(persistedChave, "BCDE")
        XCTAssertFalse(harness.auth.statusCalls.contains("B"))
        XCTAssertEqual(
            harness.orchestrator.beginAutomationContextTransitionCount,
            harness.orchestrator.endAutomationContextTransitionCount
        )
        harness.teardown()
    }

    func test_normalKeyTypingCancelsSupersededPartialInputsWithoutLogoutQueue() async {
        let harness = VMHarness()
        harness.auth.statusResults["ABCD"] = .success(
            AuthStatus(
                found: false,
                chave: "ABCD",
                hasPassword: false,
                authenticated: false,
                message: ""
            )
        )
        let viewModel = harness.build(
            backgroundReliabilityProfile: .legacyWithDiagnostics
        )
        await settle { !viewModel.uiState.isInitializing }

        viewModel.onChaveChanged("A")
        viewModel.onChaveChanged("AB")
        viewModel.onChaveChanged("ABC")
        viewModel.onChaveChanged("ABCD")
        let completed = await waitUntil {
            harness.auth.statusCalls == ["ABCD"]
        }

        XCTAssertTrue(completed)
        XCTAssertEqual(harness.auth.logoutCallCount, 1)
        XCTAssertEqual(viewModel.uiState.chave, "ABCD")
        harness.teardown()
    }

    func test_candidatePermissionRevocationOnReactivationDisablesAutomation() async {
        let harness = VMHarness()
        await seedStoredSession(harness, automaticActivitiesEnabled: true)
        await harness.prefs.setBackgroundLocationConsentAt("2026-07-31T00:00:00Z")
        harness.auth.statusResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave, hasPassword: false)
        )
        harness.checkRepository.getStateResult = .success(history(chave: storedChave))
        let permissions = ControlledPermissionsInspector(status: harness.permissions)
        let viewModel = harness.build(
            backgroundReliabilityProfile: .candidate,
            permissionsInspector: permissions
        )
        await settle { !viewModel.uiState.isInitializing }
        await viewModel.sceneStateDidChange(.active)
        XCTAssertTrue(viewModel.uiState.automaticActivitiesEnabled)
        let captureCallsBeforeRevocation = harness.captureLocation.callCount
        let foregroundRunsBeforeRevocation = harness.orchestrator.runOnceCalls.count
        let projectLoadsBeforeRevocation = harness.projects.getUserProjectsCallCount

        await viewModel.sceneStateDidChange(.background)
        await permissions.update(
            PermissionsStatus(
                locationAuthorization: .always,
                preciseAccuracy: true,
                cameraMicGranted: true,
                notificationAuthorization: .denied,
                lowPowerMode: false,
                backgroundRefresh: .available
            )
        )
        await viewModel.sceneStateDidChange(.active)

        XCTAssertFalse(viewModel.uiState.automaticActivitiesEnabled)
        XCTAssertEqual(viewModel.uiState.notificationTone, .error)
        let settings = try? JSONCoding.decoder.decode(
            [String: UserSettings].self,
            from: Data((await harness.prefs.userSettingsJson()).utf8)
        )
        XCTAssertEqual(settings?[storedChave]?.automaticActivitiesEnabled, false)
        XCTAssertEqual(
            harness.captureLocation.callCount,
            captureCallsBeforeRevocation,
            "a permissão revogada deve ser validada antes de qualquer captura visual"
        )
        XCTAssertEqual(
            harness.orchestrator.runOnceCalls.count,
            foregroundRunsBeforeRevocation + 1,
            "somente a reconciliação segura do OFF durável deve executar"
        )
        XCTAssertEqual(
            harness.projects.getUserProjectsCallCount,
            projectLoadsBeforeRevocation + 1
        )
        let monitorStops = await harness.significantLocationMonitor.stopCount
        let geofenceUnregisters = await harness.geofenceRegionManager.unregisterCount
        XCTAssertGreaterThan(monitorStops, 0)
        XCTAssertGreaterThan(geofenceUnregisters, 0)
        harness.teardown()
    }

    func test_candidateSelfRegistrationAuthenticatedInBackgroundHydratesOnNextActiveOnly() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        harness.auth.statusResults[storedChave] = .success(
            AuthStatus(
                found: false,
                chave: storedChave,
                hasPassword: false,
                authenticated: false,
                message: ""
            )
        )
        harness.auth.selfRegisterResult = .success(
            authenticatedStatus(chave: storedChave)
        )
        let registrationGate = AsyncGate()
        harness.auth.selfRegisterGate = registrationGate
        let permissions = ControlledPermissionsInspector(status: harness.permissions)
        let stream = SpyCheckEventStream()
        let viewModel = harness.build(
            backgroundReliabilityProfile: .candidate,
            permissionsInspector: permissions,
            checkEventStream: stream
        )
        await settle { !viewModel.uiState.isInitializing }
        await viewModel.sceneStateDidChange(.active)
        XCTAssertEqual(viewModel.uiState.dialogOpen, .selfRegistration)

        viewModel.loadProjectCatalogForRegistration()
        await settle {
            !viewModel.uiState.selfRegistrationFields.projectCatalog.isEmpty
        }
        viewModel.onRegProjectToggled(1)
        viewModel.onRegNomeChanged("Full Name")
        viewModel.onRegPasswordChanged("abc123")
        viewModel.onRegConfirmPwChanged("abc123")
        viewModel.submitSelfRegistration()
        let requestStarted = await waitUntil {
            harness.auth.selfRegistrationCalls == [storedChave]
        }
        XCTAssertTrue(requestStarted)

        await viewModel.sceneStateDidChange(.background)
        await registrationGate.release()
        let authenticatedInBackground = await waitUntil {
            viewModel.uiState.isAuthenticated
        }
        XCTAssertTrue(authenticatedInBackground)
        XCTAssertEqual(harness.auth.getHistoryCallCount, 0)
        XCTAssertEqual(harness.projects.getUserProjectsCallCount, 0)
        let backgroundPermissionCalls = await permissions.callCount
        XCTAssertEqual(backgroundPermissionCalls, 0)
        XCTAssertEqual(harness.captureLocation.callCount, 0)
        XCTAssertTrue(stream.calls.isEmpty)
        XCTAssertTrue(harness.orchestrator.runOnceCalls.isEmpty)

        await viewModel.sceneStateDidChange(.active)
        XCTAssertEqual(harness.auth.getHistoryCallCount, 1)
        XCTAssertEqual(harness.projects.getUserProjectsCallCount, 1)
        XCTAssertEqual(harness.projects.listProjectsCallCount, 2)
        let activePermissionCalls = await permissions.callCount
        XCTAssertEqual(activePermissionCalls, 1)
        XCTAssertEqual(stream.calls, [storedChave])
        XCTAssertEqual(harness.orchestrator.runOnceCalls, [.foreground])

        await viewModel.sceneStateDidChange(.active)
        XCTAssertEqual(harness.auth.getHistoryCallCount, 1)
        XCTAssertEqual(harness.projects.getUserProjectsCallCount, 1)
        XCTAssertEqual(stream.calls, [storedChave])
        harness.teardown()
    }

    func test_candidatePasswordRegistrationAuthenticatedInBackgroundHydratesOnNextActiveOnly() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        harness.passwords.removePassword(storedChave)
        harness.auth.statusResults[storedChave] = .success(
            AuthStatus(
                found: true,
                chave: storedChave,
                hasPassword: false,
                authenticated: false,
                message: ""
            )
        )
        harness.auth.registerPasswordResult = .success(
            authenticatedStatus(chave: storedChave)
        )
        let passwordGate = AsyncGate()
        harness.auth.registerPasswordGate = passwordGate
        let permissions = ControlledPermissionsInspector(status: harness.permissions)
        let stream = SpyCheckEventStream()
        let viewModel = harness.build(
            backgroundReliabilityProfile: .candidate,
            permissionsInspector: permissions,
            checkEventStream: stream
        )
        await settle { !viewModel.uiState.isInitializing }
        await viewModel.sceneStateDidChange(.active)
        XCTAssertEqual(viewModel.uiState.dialogOpen, .passwordChange)

        viewModel.onPasswordChangeNewPwChanged("new123")
        viewModel.onPasswordChangeConfirmPwChanged("new123")
        viewModel.submitPasswordChange()
        await Task.yield()
        await viewModel.sceneStateDidChange(.background)
        await passwordGate.release()
        let authenticatedInBackground = await waitUntil {
            viewModel.uiState.isAuthenticated
        }
        XCTAssertTrue(authenticatedInBackground)
        XCTAssertEqual(harness.auth.getHistoryCallCount, 0)
        XCTAssertEqual(harness.projects.getUserProjectsCallCount, 0)
        let backgroundPermissionCalls = await permissions.callCount
        XCTAssertEqual(backgroundPermissionCalls, 0)
        XCTAssertTrue(stream.calls.isEmpty)

        await viewModel.sceneStateDidChange(.active)
        XCTAssertEqual(harness.auth.getHistoryCallCount, 1)
        XCTAssertEqual(harness.projects.getUserProjectsCallCount, 1)
        XCTAssertEqual(harness.projects.listProjectsCallCount, 1)
        let activePermissionCalls = await permissions.callCount
        XCTAssertEqual(activePermissionCalls, 1)
        XCTAssertEqual(stream.calls, [storedChave])
        XCTAssertEqual(harness.orchestrator.runOnceCalls, [.foreground])
        harness.teardown()
    }

    func test_backgroundCancellationClearsOwnedLoadingFlagsAndAllowsFreshCapture() async {
        let harness = VMHarness()
        await seedStoredSession(harness, automaticActivitiesEnabled: true)
        harness.auth.statusResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave, hasPassword: false)
        )
        harness.checkRepository.getStateResult = .success(history(chave: storedChave))
        harness.captureLocation.result = .matched(ucMatch(.matched, "Known"))
        let historyGate = AsyncGate()
        harness.auth.historyGate = historyGate
        let viewModel = harness.build(backgroundReliabilityProfile: .candidate)
        await settle { !viewModel.uiState.isInitializing }

        let firstActivation = Task {
            await viewModel.sceneStateDidChange(.active)
        }
        let historyStarted = await waitUntil {
            harness.auth.getHistoryCallCount == 1
        }
        XCTAssertTrue(historyStarted)
        XCTAssertTrue(viewModel.uiState.isHistoryLoading)
        await viewModel.sceneStateDidChange(.background)
        XCTAssertFalse(viewModel.uiState.isHistoryLoading)
        await historyGate.release()
        await firstActivation.value

        let captureGate = AsyncGate()
        harness.captureLocation.setExecutionGate(captureGate)
        let secondActivation = Task {
            await viewModel.sceneStateDidChange(.active)
        }
        let captureStarted = await waitUntil {
            harness.captureLocation.callCount == 1
        }
        XCTAssertTrue(captureStarted)
        XCTAssertTrue(viewModel.uiState.isLocationLoading)
        await viewModel.sceneStateDidChange(.background)
        XCTAssertFalse(viewModel.uiState.isLocationLoading)
        await captureGate.release()
        await secondActivation.value

        await viewModel.sceneStateDidChange(.active)
        XCTAssertEqual(harness.captureLocation.callCount, 2)
        XCTAssertFalse(viewModel.uiState.isHistoryLoading)
        XCTAssertFalse(viewModel.uiState.isLocationLoading)
        harness.teardown()
    }

    func test_candidateExplicitKeySwapInvalidatesOldSessionAndStopsItsStream() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        harness.auth.statusResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave, hasPassword: false)
        )
        harness.auth.statusResults["BBBB"] = .success(
            AuthStatus(
                found: false,
                chave: "BBBB",
                hasPassword: false,
                authenticated: false,
                message: ""
            )
        )
        let stream = SpyCheckEventStream()
        let viewModel = harness.build(
            backgroundReliabilityProfile: .candidate,
            checkEventStream: stream
        )
        await settle { !viewModel.uiState.isInitializing }
        await viewModel.sceneStateDidChange(.active)
        XCTAssertEqual(stream.calls, [storedChave])

        viewModel.onChaveChanged("BBBB")
        let swapped = await waitUntil {
            harness.auth.statusCalls.contains("BBBB")
        }
        XCTAssertTrue(swapped)

        XCTAssertEqual(viewModel.uiState.chave, "BBBB")
        XCTAssertFalse(viewModel.uiState.isAuthenticated)
        XCTAssertEqual(harness.auth.logoutCallCount, 1)
        XCTAssertEqual(stream.calls, [storedChave])
        let monitorStops = await harness.significantLocationMonitor.stopCount
        XCTAssertGreaterThan(monitorStops, 0)
        harness.teardown()
    }

    func test_reactivationWaitsForKeyLogoutFenceBeforeProbingTheNewIdentity() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        harness.auth.statusResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave, hasPassword: false)
        )
        harness.passwords.seed("BBBB", "pw1234")
        harness.auth.statusResults["BBBB"] = .success(
            AuthStatus(
                found: true,
                chave: "BBBB",
                hasPassword: true,
                authenticated: false,
                message: ""
            )
        )
        harness.auth.loginResults["BBBB"] = .success(
            authenticatedStatus(chave: "BBBB")
        )
        let viewModel = harness.build(backgroundReliabilityProfile: .candidate)
        await settle { !viewModel.uiState.isInitializing }
        await viewModel.sceneStateDidChange(.active)

        let logoutGate = AsyncGate()
        harness.auth.nextLogoutGate = logoutGate
        viewModel.onChaveChanged("BBBB")
        let logoutStarted = await waitUntil {
            harness.auth.logoutCallCount == 1
        }
        XCTAssertTrue(logoutStarted)

        await viewModel.sceneStateDidChange(.background)
        let reactivation = Task {
            await viewModel.sceneStateDidChange(.active)
        }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(harness.auth.statusCalls.contains("BBBB"))
        XCTAssertFalse(harness.auth.loginCalls.contains { $0.chave == "BBBB" })

        await logoutGate.release()
        await reactivation.value

        XCTAssertEqual(
            harness.auth.statusCalls.filter { $0 == "BBBB" }.count,
            1
        )
        XCTAssertEqual(
            harness.auth.loginCalls.filter { $0.chave == "BBBB" }.count,
            1
        )
        XCTAssertTrue(viewModel.uiState.isAuthenticated)
        harness.teardown()
    }

    func test_reactivationWaitsForSupersededIntermediateKeyCleanup() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        harness.auth.statusResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave, hasPassword: false)
        )
        harness.passwords.seed("BCDE", "pw1234")
        harness.auth.statusResults["BCDE"] = .success(
            AuthStatus(
                found: true,
                chave: "BCDE",
                hasPassword: true,
                authenticated: false,
                message: ""
            )
        )
        harness.auth.loginResults["BCDE"] = .success(
            authenticatedStatus(chave: "BCDE")
        )
        let viewModel = harness.build(backgroundReliabilityProfile: .candidate)
        await settle { !viewModel.uiState.isInitializing }
        await viewModel.sceneStateDidChange(.active)

        let logoutGate = AsyncGate()
        harness.auth.nextLogoutGate = logoutGate
        viewModel.onChaveChanged("B")
        let intermediateCleanupStarted = await waitUntil {
            harness.auth.logoutCallCount == 1
        }
        XCTAssertTrue(intermediateCleanupStarted)
        viewModel.onChaveChanged("BCDE")

        await viewModel.sceneStateDidChange(.background)
        let reactivation = Task {
            await viewModel.sceneStateDidChange(.active)
        }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(harness.auth.statusCalls.contains("BCDE"))
        XCTAssertFalse(harness.auth.loginCalls.contains { $0.chave == "BCDE" })

        await logoutGate.release()
        await reactivation.value

        XCTAssertEqual(
            harness.auth.statusCalls.filter { $0 == "BCDE" }.count,
            1
        )
        XCTAssertEqual(
            harness.auth.loginCalls.filter { $0.chave == "BCDE" }.count,
            1
        )
        XCTAssertTrue(viewModel.uiState.isAuthenticated)
        harness.teardown()
    }

    func test_reactivationWaitsForAuthExpiryLogoutBeforeSavedLogin() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        harness.auth.statusResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave, hasPassword: true)
        )
        harness.checkRepository.getStateResult = .failure(.unauthorized)
        let viewModel = harness.build(backgroundReliabilityProfile: .candidate)
        await settle { !viewModel.uiState.isInitializing }
        await viewModel.sceneStateDidChange(.active)

        let logoutGate = AsyncGate()
        harness.auth.nextLogoutGate = logoutGate
        await viewModel.sceneStateDidChange(.background)
        await viewModel.sceneStateDidChange(.active)
        let logoutStarted = await waitUntil {
            harness.auth.logoutCallCount == 1
        }
        XCTAssertTrue(logoutStarted)
        XCTAssertFalse(viewModel.uiState.isAuthenticated)

        harness.auth.statusResults[storedChave] = .success(
            AuthStatus(
                found: true,
                chave: storedChave,
                hasPassword: true,
                authenticated: false,
                message: ""
            )
        )
        harness.auth.loginResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave)
        )
        harness.checkRepository.getStateResult = .success(
            history(chave: storedChave)
        )
        let statusCallsBeforeSecondActivation = harness.auth.statusCalls.count
        await viewModel.sceneStateDidChange(.background)
        let secondActivation = Task {
            await viewModel.sceneStateDidChange(.active)
        }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(
            harness.auth.statusCalls.count,
            statusCallsBeforeSecondActivation
        )
        XCTAssertTrue(harness.auth.loginCalls.isEmpty)

        await logoutGate.release()
        await secondActivation.value

        XCTAssertEqual(
            harness.auth.statusCalls.count,
            statusCallsBeforeSecondActivation + 1
        )
        XCTAssertEqual(harness.auth.loginCalls.map(\.chave), [storedChave])
        XCTAssertTrue(viewModel.uiState.isAuthenticated)
        harness.teardown()
    }

    func test_explicitSavedLoginWaitsForAuthExpiryLogoutFence() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        harness.auth.statusResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave, hasPassword: true)
        )
        harness.checkRepository.getStateResult = .failure(.unauthorized)
        let viewModel = harness.build(backgroundReliabilityProfile: .candidate)
        await settle { !viewModel.uiState.isInitializing }
        await viewModel.sceneStateDidChange(.active)

        let logoutGate = AsyncGate()
        harness.auth.nextLogoutGate = logoutGate
        await viewModel.sceneStateDidChange(.background)
        await viewModel.sceneStateDidChange(.active)
        let logoutStarted = await waitUntil {
            harness.auth.logoutCallCount == 1
        }
        XCTAssertTrue(logoutStarted)
        harness.auth.loginResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave)
        )

        viewModel.submitLogin()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(harness.auth.loginCalls.isEmpty)

        await logoutGate.release()
        let loginCompleted = await waitUntil {
            harness.auth.loginCalls.map(\.chave) == [storedChave]
                && viewModel.uiState.isAuthenticated
        }
        XCTAssertTrue(loginCompleted)
        harness.teardown()
    }

    func test_keyCleanupClearsCookieWrittenByLateLoginResponse() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        harness.passwords.removePassword(storedChave)
        harness.auth.statusResults[storedChave] = .success(
            AuthStatus(
                found: true,
                chave: storedChave,
                hasPassword: true,
                authenticated: false,
                message: ""
            )
        )
        harness.auth.statusResults["BBBB"] = .success(
            AuthStatus(
                found: false,
                chave: "BBBB",
                hasPassword: false,
                authenticated: false,
                message: ""
            )
        )
        harness.auth.loginResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave)
        )
        let loginGate = AsyncGate()
        harness.auth.loginGates[storedChave] = loginGate
        harness.auth.simulatedAuthenticationResponseCookie = "late-response-cookie-fixture"
        let logoutGate = AsyncGate()
        harness.auth.nextLogoutGate = logoutGate
        let viewModel = harness.build(backgroundReliabilityProfile: .candidate)
        await settle { !viewModel.uiState.isInitializing }
        await viewModel.sceneStateDidChange(.active)

        viewModel.onPasswordChanged("abc123")
        viewModel.submitLogin()
        let loginStarted = await waitUntil {
            harness.auth.loginCalls.map(\.chave) == [storedChave]
        }
        XCTAssertTrue(loginStarted)

        viewModel.onChaveChanged("BBBB")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(
            harness.auth.logoutCallCount,
            0,
            "o cleanup precisa aguardar a resposta capaz de persistir Set-Cookie"
        )

        await loginGate.release()
        let logoutStarted = await waitUntil {
            harness.auth.logoutCallCount == 1
        }

        XCTAssertTrue(logoutStarted)
        XCTAssertNil(
            harness.auth.simulatedPersistedSessionCookie,
            "a geração deve rejeitar Set-Cookie antes de o logout remoto poder limpar o jar"
        )
        await logoutGate.release()
        let newIdentityReady = await waitUntil {
            harness.auth.statusCalls.contains("BBBB")
        }
        XCTAssertTrue(newIdentityReady)
        XCTAssertFalse(
            harness.passwords.setPasswordCalls.contains {
                $0.chave == storedChave
            },
            "a resposta abandonada não pode repor a senha da identidade antiga"
        )
        XCTAssertEqual(viewModel.uiState.chave, "BBBB")
        harness.teardown()
    }

    func test_localWipeClearsCookieAndRejectsPasswordFromLateLoginResponse() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        harness.passwords.removePassword(storedChave)
        harness.auth.statusResults[storedChave] = .success(
            AuthStatus(
                found: true,
                chave: storedChave,
                hasPassword: true,
                authenticated: false,
                message: ""
            )
        )
        harness.auth.loginResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave)
        )
        let loginGate = AsyncGate()
        harness.auth.loginGates[storedChave] = loginGate
        harness.auth.simulatedAuthenticationResponseCookie = "late-response-cookie-fixture"
        let logoutGate = AsyncGate()
        harness.auth.nextLogoutGate = logoutGate
        let viewModel = harness.build(backgroundReliabilityProfile: .candidate)
        await settle { !viewModel.uiState.isInitializing }
        await viewModel.sceneStateDidChange(.active)

        viewModel.onPasswordChanged("abc123")
        viewModel.submitLogin()
        let loginStarted = await waitUntil {
            harness.auth.loginCalls.map(\.chave) == [storedChave]
        }
        XCTAssertTrue(loginStarted)

        let wipe = Task {
            await viewModel.deleteLocalData()
        }
        try? await Task.sleep(for: .milliseconds(30))
        let clearCountWhileLoginIsPending =
            await harness.evaluationJournal.clearCount
        XCTAssertEqual(clearCountWhileLoginIsPending, 0)
        XCTAssertEqual(harness.auth.logoutCallCount, 0)

        await loginGate.release()
        let logoutStarted = await waitUntil {
            harness.auth.logoutCallCount == 1
        }
        XCTAssertTrue(logoutStarted)
        XCTAssertNil(
            harness.auth.simulatedPersistedSessionCookie,
            "wipe deve invalidar a resposta antes do clear executado ao fim do logout"
        )
        await logoutGate.release()
        await wipe.value

        XCTAssertNil(harness.auth.simulatedPersistedSessionCookie)
        XCTAssertTrue(harness.passwords.setPasswordCalls.isEmpty)
        XCTAssertEqual(harness.passwords.getPassword(storedChave), "")
        let finalClearCount = await harness.evaluationJournal.clearCount
        XCTAssertEqual(finalClearCount, 1)
        XCTAssertFalse(viewModel.uiState.isAuthenticated)
        harness.teardown()
    }

    func test_localWipeDrainsSessionFenceBeforeOpeningItsDestructiveBarrier() async {
        let harness = VMHarness()
        harness.auth.statusResults["ABCD"] = .success(
            AuthStatus(
                found: false,
                chave: "ABCD",
                hasPassword: false,
                authenticated: false,
                message: ""
            )
        )
        let logoutGate = AsyncGate()
        harness.auth.nextLogoutGate = logoutGate
        let viewModel = harness.build(
            backgroundReliabilityProfile: .legacyWithDiagnostics
        )
        await settle { !viewModel.uiState.isInitializing }
        viewModel.onChaveChanged("ABCD")
        let logoutStarted = await waitUntil {
            harness.auth.logoutCallCount == 1
        }
        XCTAssertTrue(logoutStarted)

        let wipe = Task {
            await viewModel.deleteLocalData()
        }
        try? await Task.sleep(for: .milliseconds(30))
        let clearCountWhileBlocked = await harness.evaluationJournal.clearCount
        XCTAssertEqual(clearCountWhileBlocked, 0)

        await logoutGate.release()
        await wipe.value

        let persistedChave = await harness.prefs.chave()
        let finalClearCount = await harness.evaluationJournal.clearCount
        XCTAssertEqual(persistedChave, "")
        XCTAssertEqual(finalClearCount, 1)
        XCTAssertTrue(harness.auth.statusCalls.isEmpty)
        XCTAssertFalse(viewModel.uiState.isAuthenticated)
        harness.teardown()
    }

    func test_localWipeReleasesEvaluationWaitingForSessionBeforeQuiescenceAndJournalClear() async {
        let harness = VMHarness()
        harness.auth.attachSessionCookieStore(harness.sessionCookies)
        let coordinator = AuthSessionCoordinator(
            authRepository: harness.auth,
            securePasswordStore: harness.passwords,
            cookieStore: harness.sessionCookies
        )
        let observedCoordinator = ObservedAuthSessionCoordinator(base: coordinator)
        let orchestrator = BarrierWaitingEvaluationOrchestrator(
            authSessionCoordinator: observedCoordinator,
            journal: harness.evaluationJournal
        )
        let viewModel = harness.build(
            backgroundReliabilityProfile: .candidate,
            authSessionCoordinator: observedCoordinator,
            orchestrator: orchestrator
        )
        await settle { !viewModel.uiState.isInitializing }

        let wipe = Task { await viewModel.deleteLocalData() }
        let completed = await waitUntil {
            await harness.evaluationJournal.clearCount == 1
        }
        XCTAssertTrue(
            completed,
            "wipe não pode esperar quiescence enquanto a avaliação espera o auth barrier"
        )
        guard completed else {
            wipe.cancel()
            harness.teardown()
            return
        }
        await wipe.value

        let trace = await harness.evaluationJournal.eventTrace
        XCTAssertEqual(trace, ["finish:stale_context", "clear"])
        XCTAssertEqual(observedCoordinator.useCurrentCallCount, 1)
        XCTAssertEqual(orchestrator.maximumConcurrentDrivers, 1)
        XCTAssertEqual(harness.auth.loginCalls.count, 0)
        XCTAssertEqual(harness.auth.deleteCallCount, 0)
        harness.teardown()
    }

    func test_localWipeFencesLateSelfRegistrationProjectCatalogResponse() async {
        let harness = VMHarness()
        harness.projects.result = .success([
            Project(id: 1, name: "P80", transportEnabled: false),
        ])
        let catalogGate = AsyncGate()
        harness.projects.listProjectsGate = catalogGate
        let viewModel = harness.build(backgroundReliabilityProfile: .candidate)
        await settle { !viewModel.uiState.isInitializing }

        viewModel.loadProjectCatalogForRegistration()
        let requested = await waitUntil {
            harness.projects.listProjectsCallCount == 1
        }
        XCTAssertTrue(requested)

        await viewModel.deleteLocalData()
        await catalogGate.release()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(viewModel.uiState.selfRegistrationFields.projectCatalog.isEmpty)
        XCTAssertFalse(viewModel.uiState.selfRegistrationFields.isLoadingProjects)
        harness.teardown()
    }

    func test_successfulDeleteReleasesEvaluationWaitingForSessionBeforeQuiescenceAndJournalClear() async {
        let harness = VMHarness()
        harness.auth.attachSessionCookieStore(harness.sessionCookies)
        let coordinator = AuthSessionCoordinator(
            authRepository: harness.auth,
            securePasswordStore: harness.passwords,
            cookieStore: harness.sessionCookies
        )
        let observedCoordinator = ObservedAuthSessionCoordinator(base: coordinator)
        let orchestrator = BarrierWaitingEvaluationOrchestrator(
            authSessionCoordinator: observedCoordinator,
            journal: harness.evaluationJournal
        )
        let authenticated = AuthStatus(
            found: true,
            chave: storedChave,
            hasPassword: true,
            authenticated: true,
            message: ""
        )
        let viewModel = harness.build(
            backgroundReliabilityProfile: .candidate,
            authSessionCoordinator: observedCoordinator,
            orchestrator: orchestrator,
            initialState: CheckUiState(
                isInitializing: false,
                chave: storedChave,
                authStatus: authenticated
            )
        )

        viewModel.deleteAccount()
        let completed = await waitUntil {
            await harness.evaluationJournal.clearCount == 1
        }
        XCTAssertTrue(
            completed,
            "DELETE aceito deve liberar o auth barrier antes de aguardar quiescence"
        )
        guard completed else {
            harness.teardown()
            return
        }

        let trace = await harness.evaluationJournal.eventTrace
        XCTAssertEqual(trace, ["finish:stale_context", "clear"])
        XCTAssertEqual(observedCoordinator.useCurrentCallCount, 1)
        XCTAssertEqual(orchestrator.maximumConcurrentDrivers, 1)
        XCTAssertEqual(harness.auth.loginCalls.count, 0)
        XCTAssertEqual(harness.auth.deleteCallCount, 1)
        XCTAssertEqual(harness.auth.logoutCallCount, 0)
        harness.teardown()
    }

    func test_oldSameKeyResponseFromPreviousActivationCannotOverwriteNewActivation() async {
        let harness = VMHarness()
        await seedStoredSession(harness)
        let firstGate = AsyncGate()
        let secondGate = AsyncGate()
        harness.auth.statusResults[storedChave] = .success(
            AuthStatus(
                found: false,
                chave: storedChave,
                hasPassword: false,
                authenticated: false,
                message: "OLD"
            )
        )
        harness.auth.statusGates[storedChave] = firstGate
        let viewModel = harness.build(backgroundReliabilityProfile: .candidate)
        await settle { !viewModel.uiState.isInitializing }

        let firstActivation = Task {
            await viewModel.sceneStateDidChange(.active)
        }
        await settle { harness.auth.statusCalls.count == 1 }
        harness.auth.statusResults[storedChave] = .success(
            authenticatedStatus(chave: storedChave, hasPassword: false)
        )
        harness.auth.statusGates[storedChave] = secondGate

        await viewModel.sceneStateDidChange(.background)
        let secondActivation = Task {
            await viewModel.sceneStateDidChange(.active)
        }
        await settle { harness.auth.statusCalls.count == 2 }
        await secondGate.release()
        await secondActivation.value
        XCTAssertTrue(viewModel.uiState.isAuthenticated)

        await firstGate.release()
        await firstActivation.value

        XCTAssertTrue(viewModel.uiState.isAuthenticated)
        XCTAssertEqual(viewModel.uiState.authStatus?.message, "")
        XCTAssertEqual(harness.auth.getHistoryCallCount, 1)
        XCTAssertEqual(harness.projects.getUserProjectsCallCount, 1)
        harness.teardown()
    }

    func test_keyEditedDuringLocalRestoreIsNotOverwrittenByStalePersistedKey() async {
        let harness = VMHarness()
        await seedStoredSession(harness, automaticActivitiesEnabled: true)
        let chaveGate = AsyncGate()
        let preferences = GatedChavePreferences(
            base: harness.prefs,
            gate: chaveGate
        )
        let viewModel = harness.build(
            backgroundReliabilityProfile: .candidate,
            appPreferences: preferences
        )

        await preferences.waitUntilChaveReadStarted()
        viewModel.onChaveChanged("BBBB")
        await chaveGate.release()
        await settle { !viewModel.uiState.isInitializing }
        await settle { viewModel.uiState.chave == "BBBB" }

        XCTAssertEqual(viewModel.uiState.chave, "BBBB")
        XCTAssertNotEqual(viewModel.uiState.password, storedPassword)
        XCTAssertFalse(viewModel.uiState.automaticActivitiesEnabled)
        XCTAssertTrue(harness.auth.statusCalls.isEmpty)
        harness.teardown()
    }

    func test_keyABARaceCannotApplySettingsOrProbeFromTheSupersededTask() async {
        let harness = VMHarness()
        let staleSettings = UserSettings(
            projects: [],
            activeProject: "",
            automaticActivitiesEnabled: false
        )
        let staleData = try! JSONCoding.encoder.encode(["AAAA": staleSettings])
        await harness.prefs.setUserSettingsJson(
            String(decoding: staleData, as: UTF8.self)
        )
        harness.auth.statusResults["AAAA"] = .success(
            AuthStatus(
                found: false,
                chave: "AAAA",
                hasPassword: false,
                authenticated: false,
                message: ""
            )
        )
        let preferences = FirstUserSettingsReadPreferences(base: harness.prefs)
        let viewModel = harness.build(
            backgroundReliabilityProfile: .legacyWithDiagnostics,
            appPreferences: preferences
        )
        await settle { !viewModel.uiState.isInitializing }

        viewModel.onChaveChanged("AAAA")
        await preferences.waitUntilFirstReadStarted()

        let currentSettings = UserSettings(
            projects: ["P80"],
            activeProject: "P80",
            automaticActivitiesEnabled: true
        )
        let currentData = try! JSONCoding.encoder.encode(["AAAA": currentSettings])
        await harness.prefs.setUserSettingsJson(
            String(decoding: currentData, as: UTF8.self)
        )
        viewModel.onChaveChanged("BBBB")
        viewModel.onChaveChanged("AAAA")

        let currentProbeCompleted = await waitUntil {
            harness.auth.statusCalls == ["AAAA"]
        }
        XCTAssertTrue(currentProbeCompleted)
        XCTAssertTrue(viewModel.uiState.automaticActivitiesEnabled)

        await preferences.releaseFirstRead()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(viewModel.uiState.chave, "AAAA")
        XCTAssertTrue(viewModel.uiState.automaticActivitiesEnabled)
        XCTAssertEqual(harness.auth.statusCalls, ["AAAA"])
        harness.teardown()
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private final class ObservedAuthSessionCoordinator:
    AuthSessionCoordinating,
    @unchecked Sendable {
    private let base: any AuthSessionCoordinating
    private let lock = NSLock()
    private var recordedUseCurrentCalls = 0

    init(base: any AuthSessionCoordinating) {
        self.base = base
    }

    var useCurrentCallCount: Int {
        lock.withLock { recordedUseCurrentCalls }
    }

    nonisolated func invalidateCurrentIdentity() -> AuthSessionInvalidation {
        base.invalidateCurrentIdentity()
    }

    func useCurrentSession() async -> AuthSessionGeneration {
        lock.withLock { recordedUseCurrentCalls += 1 }
        return await base.useCurrentSession()
    }

    func isCurrent(_ generation: AuthSessionGeneration) async -> Bool {
        await base.isCurrent(generation)
    }

    func awaitIdle() async {
        await base.awaitIdle()
    }

    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus> {
        await base.login(chave, password)
    }

    func registerPassword(
        _ chave: String,
        _ project: String?,
        _ password: String
    ) async -> AppResult<AuthStatus> {
        await base.registerPassword(chave, project, password)
    }

    func changePassword(
        _ chave: String,
        _ oldPassword: String,
        _ newPassword: String
    ) async -> AppResult<AuthStatus> {
        await base.changePassword(chave, oldPassword, newPassword)
    }

    func selfRegister(
        _ chave: String,
        _ nome: String,
        _ projetos: [String],
        _ email: String?,
        _ password: String,
        _ confirmPassword: String
    ) async -> AppResult<AuthStatus> {
        await base.selfRegister(
            chave,
            nome,
            projetos,
            email,
            password,
            confirmPassword
        )
    }

    func silentRelogin(_ chave: String) async -> SilentReloginResult {
        await base.silentRelogin(chave)
    }

    func replaceIdentity() async {
        await base.replaceIdentity()
    }

    func explicitLogout() async {
        await base.explicitLogout()
    }

    func completeInvalidatedLogout(
        _ invalidation: AuthSessionInvalidation
    ) async {
        await base.completeInvalidatedLogout(invalidation)
    }

    func completeInvalidatedTransition(
        _ invalidation: AuthSessionInvalidation
    ) async {
        await base.completeInvalidatedTransition(invalidation)
    }

    func deleteAccount() async -> DeleteAccountSessionResult {
        await base.deleteAccount()
    }
}

private final class BarrierWaitingEvaluationOrchestrator:
    OrchestratorRunning,
    @unchecked Sendable {
    private let authSessionCoordinator: ObservedAuthSessionCoordinator
    private let journal: any EvaluationJournaling
    private let lock = NSLock()
    private var driver: Task<Void, Never>?
    private var activeDrivers = 0
    private var maximumDrivers = 0

    init(
        authSessionCoordinator: ObservedAuthSessionCoordinator,
        journal: any EvaluationJournaling
    ) {
        self.authSessionCoordinator = authSessionCoordinator
        self.journal = journal
    }

    var maximumConcurrentDrivers: Int {
        lock.withLock { maximumDrivers }
    }

    func runOnce(_ trigger: OrchestratorTrigger) async -> EvaluationCompletion {
        EvaluationCompletion(
            evaluationID: EvaluationID(),
            outcome: .noAction,
            completedBeforeExpiration: true
        )
    }

    func invalidateAccuracyRetry() async {}

    func beginAutomationContextTransition() async -> AutomationContextTransitionToken {
        let callsBeforeDriver = authSessionCoordinator.useCurrentCallCount
        let authSessionCoordinator = authSessionCoordinator
        let journal = journal
        let evaluationID = EvaluationID()
        let task = Task { [weak self] in
            self?.recordDriverStarted()
            _ = await authSessionCoordinator.useCurrentSession()
            await journal.finish(
                id: evaluationID,
                terminal: EvaluationTerminal(
                    outcome: .staleContext,
                    stage: .restore
                )
            )
            self?.recordDriverFinished()
        }
        lock.withLock { driver = task }
        while authSessionCoordinator.useCurrentCallCount == callsBeforeDriver {
            await Task.yield()
        }
        return AutomationContextTransitionToken()
    }

    func awaitAutomationQuiescence(
        _ token: AutomationContextTransitionToken
    ) async {
        let task = lock.withLock { driver }
        await task?.value
    }

    func endAutomationContextTransition(
        _ token: AutomationContextTransitionToken
    ) async {}

    func scheduledPauseSettingsDidChange() async {}

    func acceptedCheck(
        chave: String,
        project: String,
        action: CheckAction,
        newState: HistoryState
    ) async {}

    func confirmedState(chave: String, newState: HistoryState) async {}

    private func recordDriverStarted() {
        lock.withLock {
            activeDrivers += 1
            maximumDrivers = max(maximumDrivers, activeDrivers)
        }
    }

    private func recordDriverFinished() {
        lock.withLock { activeDrivers -= 1 }
    }
}

private final class GatedChavePreferences: AppPreferencesStore, @unchecked Sendable {
    private let base: any AppPreferencesStore
    private let gate: AsyncGate
    private let readStarted = AsyncGate()

    init(base: any AppPreferencesStore, gate: AsyncGate) {
        self.base = base
        self.gate = gate
    }

    func chave() async -> String {
        let captured = await base.chave()
        await readStarted.release()
        await gate.wait()
        return captured
    }

    func waitUntilChaveReadStarted() async {
        await readStarted.wait()
    }

    func language() async -> String { await base.language() }
    func userSettingsJson() async -> String { await base.userSettingsJson() }
    func backgroundLocationConsentAt() async -> String {
        await base.backgroundLocationConsentAt()
    }
    func seenAccidentIds() async -> Set<Int> { await base.seenAccidentIds() }
    func getFlag(_ name: String) async -> Bool { await base.getFlag(name) }
    func accuracyRetryEpisodeJson() async -> String {
        await base.accuracyRetryEpisodeJson()
    }
    func scheduledPauseDeferralJson() async -> String {
        await base.scheduledPauseDeferralJson()
    }
    func transportLocalJson() async -> String { await base.transportLocalJson() }
    func pendingChecksJson() async -> String { await base.pendingChecksJson() }

    func setChave(_ chave: String) async { await base.setChave(chave) }
    func setLanguage(_ code: String) async { await base.setLanguage(code) }
    func setUserSettingsJson(_ json: String) async {
        await base.setUserSettingsJson(json)
    }
    func setTransportLocalJson(_ json: String) async {
        await base.setTransportLocalJson(json)
    }
    func setPendingChecksJson(_ json: String) async {
        await base.setPendingChecksJson(json)
    }
    func setBackgroundLocationConsentAt(_ iso8601: String) async {
        await base.setBackgroundLocationConsentAt(iso8601)
    }
    func setSeenAccidentIds(_ ids: Set<Int>) async {
        await base.setSeenAccidentIds(ids)
    }
    func setFlag(_ name: String, _ value: Bool) async {
        await base.setFlag(name, value)
    }
    func setAccuracyRetryEpisodeJson(_ json: String) async {
        await base.setAccuracyRetryEpisodeJson(json)
    }
    func setScheduledPauseDeferralJson(_ json: String) async {
        await base.setScheduledPauseDeferralJson(json)
    }
    func clearAll() async { await base.clearAll() }
}

private final class FirstUserSettingsReadPreferences:
    AppPreferencesStore,
    @unchecked Sendable {
    private let base: any AppPreferencesStore
    private let lock = NSLock()
    private var didGateFirstRead = false
    private let firstReadStarted = AsyncGate()
    private let firstReadRelease = AsyncGate()

    init(base: any AppPreferencesStore) {
        self.base = base
    }

    func waitUntilFirstReadStarted() async {
        await firstReadStarted.wait()
    }

    func releaseFirstRead() async {
        await firstReadRelease.release()
    }

    func chave() async -> String { await base.chave() }
    func language() async -> String { await base.language() }
    func userSettingsJson() async -> String {
        let captured = await base.userSettingsJson()
        let shouldGate = lock.withLock { () -> Bool in
            guard !didGateFirstRead else { return false }
            didGateFirstRead = true
            return true
        }
        if shouldGate {
            await firstReadStarted.release()
            await firstReadRelease.wait()
        }
        return captured
    }
    func backgroundLocationConsentAt() async -> String {
        await base.backgroundLocationConsentAt()
    }
    func seenAccidentIds() async -> Set<Int> { await base.seenAccidentIds() }
    func getFlag(_ name: String) async -> Bool { await base.getFlag(name) }
    func accuracyRetryEpisodeJson() async -> String {
        await base.accuracyRetryEpisodeJson()
    }
    func scheduledPauseDeferralJson() async -> String {
        await base.scheduledPauseDeferralJson()
    }
    func transportLocalJson() async -> String { await base.transportLocalJson() }
    func pendingChecksJson() async -> String { await base.pendingChecksJson() }

    func setChave(_ chave: String) async { await base.setChave(chave) }
    func setLanguage(_ code: String) async { await base.setLanguage(code) }
    func setUserSettingsJson(_ json: String) async {
        await base.setUserSettingsJson(json)
    }
    func setTransportLocalJson(_ json: String) async {
        await base.setTransportLocalJson(json)
    }
    func setPendingChecksJson(_ json: String) async {
        await base.setPendingChecksJson(json)
    }
    func setBackgroundLocationConsentAt(_ iso8601: String) async {
        await base.setBackgroundLocationConsentAt(iso8601)
    }
    func setSeenAccidentIds(_ ids: Set<Int>) async {
        await base.setSeenAccidentIds(ids)
    }
    func setFlag(_ name: String, _ value: Bool) async {
        await base.setFlag(name, value)
    }
    func setAccuracyRetryEpisodeJson(_ json: String) async {
        await base.setAccuracyRetryEpisodeJson(json)
    }
    func setScheduledPauseDeferralJson(_ json: String) async {
        await base.setScheduledPauseDeferralJson(json)
    }
    func clearAll() async { await base.clearAll() }
}
