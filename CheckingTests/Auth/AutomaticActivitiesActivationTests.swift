import XCTest
@testable import Checking

@MainActor
final class AutomaticActivitiesActivationTests: XCTestCase {
    func test_enablePersistsProjectsAndRunsImmediateEvaluation() async throws {
        let h = VMHarness()
        h.auth.statusResults["HR70"] = .success(status(found: true, hasPassword: true, authenticated: false, chave: "HR70"))
        h.auth.loginResults["HR70"] = .success(status(found: true, hasPassword: true, authenticated: true, chave: "HR70"))
        h.auth.historyResult = .success(ucHistory(nil))
        h.projects.userProjectsResult = .success(UserProjects(projects: ["P80", "P81"], activeProject: "P81"))
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }

        vm.onChaveChanged("HR70")
        await settle { vm.uiState.authStatus != nil }
        vm.onPasswordChanged("abc")
        await settle(timeout: 2) { vm.uiState.isAuthenticated && vm.uiState.userProjects != nil }
        let evaluationsBeforeEnable = h.orchestrator.runOnceCalls.count

        let enabled = await vm.setAutomaticActivitiesEnabled(true)
        let stored = try JSONCoding.decoder.decode(
            [String: UserSettings].self,
            from: Data((await h.prefs.userSettingsJson()).utf8)
        )

        XCTAssertTrue(enabled)
        XCTAssertTrue(vm.uiState.automaticActivitiesEnabled)
        XCTAssertEqual(stored["HR70"]?.projects, ["P80", "P81"])
        XCTAssertEqual(stored["HR70"]?.activeProject, "P81")
        XCTAssertEqual(h.orchestrator.runOnceCalls.count, evaluationsBeforeEnable + 1)
        XCTAssertEqual(h.orchestrator.runOnceCalls.last, .foreground)
        let startCount = await h.significantLocationMonitor.startCount
        XCTAssertEqual(startCount, 0) // sem consentimento explícito
        h.teardown()
    }

    func test_enableStartsSignificantChangesWhenConsentAlreadyExists() async {
        let h = VMHarness()
        h.auth.statusResults["HR70"] = .success(status(found: true, hasPassword: true, authenticated: false, chave: "HR70"))
        h.auth.loginResults["HR70"] = .success(status(found: true, hasPassword: true, authenticated: true, chave: "HR70"))
        h.projects.userProjectsResult = .success(UserProjects(projects: ["P80"], activeProject: "P80"))
        await h.prefs.setBackgroundLocationConsentAt("2026-07-22T00:00:00Z")
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }

        vm.onChaveChanged("HR70")
        await settle { vm.uiState.authStatus != nil }
        vm.onPasswordChanged("abc")
        await settle(timeout: 2) { vm.uiState.isAuthenticated && vm.uiState.userProjects != nil }

        let enabled = await vm.setAutomaticActivitiesEnabled(true)
        let startCount = await h.significantLocationMonitor.startCount
        let isActive = await h.significantLocationMonitor.isActive()
        XCTAssertTrue(enabled)
        XCTAssertEqual(startCount, 1)
        XCTAssertTrue(isActive)
        h.teardown()
    }

    func test_enableFailsClosedWhenUserHasNoProjects() async {
        let h = VMHarness()
        h.auth.statusResults["HR70"] = .success(status(found: true, hasPassword: true, authenticated: false, chave: "HR70"))
        h.auth.loginResults["HR70"] = .success(status(found: true, hasPassword: true, authenticated: true, chave: "HR70"))
        h.projects.userProjectsResult = .success(UserProjects(projects: [], activeProject: ""))
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }

        vm.onChaveChanged("HR70")
        await settle { vm.uiState.authStatus != nil }
        vm.onPasswordChanged("abc")
        await settle(timeout: 2) { vm.uiState.isAuthenticated && vm.uiState.userProjects != nil }
        let evaluationsBeforeEnable = h.orchestrator.runOnceCalls.count

        let enabled = await vm.setAutomaticActivitiesEnabled(true)
        XCTAssertFalse(enabled)
        XCTAssertFalse(vm.uiState.automaticActivitiesEnabled)
        XCTAssertEqual(h.orchestrator.runOnceCalls.count, evaluationsBeforeEnable)
        h.teardown()
    }
}
