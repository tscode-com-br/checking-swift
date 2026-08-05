import XCTest
@testable import Checking

// Port de AccidentNotificationDecisionTest.kt — dedup de notificação de acidente via runAccidentCheck. §12.
final class AccidentNotificationDecisionTests: XCTestCase {

    private let chave = "STSM"

    private func accidentState(_ ids: Int...) -> AppResult<AccidentState> {
        .success(AccidentState(
            isActive: !ids.isEmpty, accidentId: ids.first, accidentNumberLabel: nil, projectId: nil, projectName: nil,
            locationName: nil, description: nil, awarenessStatus: nil, currentUserReport: nil,
            activeAccidents: ids.map { AccidentActiveItem(accidentId: $0, accidentNumberLabel: "AC-\($0)", projectId: 1,
                                                          projectName: "P80", locationName: "L", description: nil,
                                                          awarenessStatus: "open", currentUserReport: nil) }))
    }

    private func automaticPreferences() throws -> FakeAppPreferences {
        let settings = UserSettings(
            projects: ["P80"],
            activeProject: "P80",
            automaticActivitiesEnabled: true,
            scheduledPauseEnabled: false,
            notifyActivities: false,
            notifyScheduledPause: false,
            notifyAccident: true
        )
        let data = try JSONCoding.encoder.encode([chave: settings])
        let prefs = FakeAppPreferences()
        prefs.chaveValue = chave
        prefs.userSettingsJsonValue = String(data: data, encoding: .utf8)!
        return prefs
    }

    private func successfulAuth() -> SpyAuthRepository {
        let auth = SpyAuthRepository()
        auth.result = .success(AuthStatus(
            found: true,
            chave: chave,
            hasPassword: true,
            authenticated: true,
            message: "ok"
        ))
        return auth
    }

    func test_newAccident_postsOnce_andRemembersId() async {
        let prefs = FakeAppPreferences(); prefs.chaveValue = chave; prefs.userSettingsJsonValue = ""; prefs.seenAccidentIdsValue = []
        let accident = FakeAccidentStateRepository(); accident.result = accidentState(42)
        let notifications = SpyNotifications()
        await makeOrchestrator(prefs: prefs, accidentRepository: accident, notifications: notifications).runAccidentCheck()
        XCTAssertEqual(notifications.accidentPosts, ["pt"])          // postAccidentNotification(lang:"pt") 1×
        XCTAssertEqual(prefs.setSeenCalls, [Set([42])])             // persiste o id novo
    }

    func test_alreadySeen_doesNotPostAgain() async {
        let prefs = FakeAppPreferences(); prefs.chaveValue = chave; prefs.userSettingsJsonValue = ""; prefs.seenAccidentIdsValue = [42]
        let accident = FakeAccidentStateRepository(); accident.result = accidentState(42)
        let notifications = SpyNotifications()
        await makeOrchestrator(prefs: prefs, accidentRepository: accident, notifications: notifications).runAccidentCheck()
        XCTAssertTrue(notifications.accidentPosts.isEmpty)
        XCTAssertTrue(prefs.setSeenCalls.isEmpty)                   // set inalterado → não persiste
    }

    func test_notifyDisabled_doesNotPost_norQueriesState() async throws {
        let settings = UserSettings(projects: ["P80"], activeProject: "P80", automaticActivitiesEnabled: false, notifyAccident: false)
        let json = String(data: try JSONCoding.encoder.encode([chave: settings]), encoding: .utf8)!
        let prefs = FakeAppPreferences(); prefs.chaveValue = chave; prefs.userSettingsJsonValue = json; prefs.seenAccidentIdsValue = []
        let accident = FakeAccidentStateRepository(); accident.result = accidentState(42)
        let notifications = SpyNotifications()
        await makeOrchestrator(prefs: prefs, accidentRepository: accident, notifications: notifications).runAccidentCheck()
        XCTAssertTrue(notifications.accidentPosts.isEmpty)
        XCTAssertEqual(accident.getStateCount, 0)                   // toggle-off curto-circuita ANTES da query
    }

    func test_embeddedUnauthorizedRefreshesOnceRetriesOnlyAccidentAndAutomaticFlowContinues() async throws {
        let prefs = try automaticPreferences()
        let accident = FakeAccidentStateRepository()
        accident.queuedResults = [
            .failure(.unauthorized),
            accidentState(42),
        ]
        let notifications = SpyNotifications()
        let automatic = SpyAutoActivities()
        let auth = successfulAuth()

        let completion = await makeOrchestrator(
            prefs: prefs,
            autoActivities: automatic,
            accidentRepository: accident,
            notifications: notifications,
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            )
        ).runOnce(.geofence)

        XCTAssertEqual(completion.outcome, .noAction)
        XCTAssertEqual(accident.getStateCount, 2)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(automatic.callCount, 1)
        XCTAssertEqual(notifications.accidentPosts, ["pt"])
        XCTAssertTrue(notifications.reauthPosts.isEmpty)
        XCTAssertEqual(prefs.setSeenCalls, [Set([42])])
    }

    func test_embeddedSecondUnauthorizedDoesNotLoopOrBlockAutomaticFlow() async throws {
        let prefs = try automaticPreferences()
        let accident = FakeAccidentStateRepository()
        accident.queuedResults = [
            .failure(.unauthorized),
            .failure(.unauthorized),
        ]
        let notifications = SpyNotifications()
        let automatic = SpyAutoActivities()
        let auth = successfulAuth()

        let completion = await makeOrchestrator(
            prefs: prefs,
            autoActivities: automatic,
            accidentRepository: accident,
            notifications: notifications,
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            )
        ).runOnce(.geofence)

        XCTAssertEqual(completion.outcome, .noAction)
        XCTAssertEqual(accident.getStateCount, 2)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(automatic.callCount, 1)
        XCTAssertTrue(notifications.accidentPosts.isEmpty)
        XCTAssertEqual(notifications.reauthPosts, ["pt"])
        XCTAssertTrue(prefs.setSeenCalls.isEmpty)
    }

    func test_embeddedAccidentResponseFromInvalidatedSessionCannotNotifyOrPersistSeenIDs() async throws {
        let prefs = try automaticPreferences()
        let accident = FakeAccidentStateRepository()
        accident.result = accidentState(42)
        accident.getStateStarted = AsyncGate()
        accident.getStateGate = AsyncGate()
        let notifications = SpyNotifications()
        let automatic = SpyAutoActivities()
        let coordinator = OrchestratorAuthSessionCoordinator(
            authRepository: NoopAuthRepository(),
            securePasswordStore: NoopSecurePasswordStore()
        )
        let repository = FakeCheckRepository()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            autoActivities: automatic,
            accidentRepository: accident,
            notifications: notifications,
            authSessionCoordinator: coordinator
        )

        let evaluation = Task { await sut.runOnce(.geofence) }
        await accident.getStateStarted?.wait()
        _ = coordinator.invalidateCurrentIdentity()
        await accident.getStateGate?.release()
        let completion = await evaluation.value

        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertEqual(accident.getStateCount, 1)
        XCTAssertTrue(notifications.accidentPosts.isEmpty)
        XCTAssertTrue(prefs.setSeenCalls.isEmpty)
        XCTAssertEqual(repository.getLocationsCallCount, 0)
        XCTAssertEqual(automatic.callCount, 0)
    }

    func test_embeddedSecondAccidentResponseFromInvalidatedSessionCannotNotifyOrPersist() async throws {
        let prefs = try automaticPreferences()
        let accident = FakeAccidentStateRepository()
        accident.queuedResults = [
            .failure(.unauthorized),
            accidentState(42),
        ]
        accident.getStateGate = AsyncGate()
        accident.getStateGateOnCall = 2
        let notifications = SpyNotifications()
        let automatic = SpyAutoActivities()
        let auth = successfulAuth()
        let coordinator = OrchestratorAuthSessionCoordinator(
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(password: "password-sentinel")
        )
        let sut = makeOrchestrator(
            prefs: prefs,
            autoActivities: automatic,
            accidentRepository: accident,
            notifications: notifications,
            authSessionCoordinator: coordinator
        )

        let evaluation = Task { await sut.runOnce(.geofence) }
        await waitUntil { accident.getStateCount == 2 }
        _ = coordinator.invalidateCurrentIdentity()
        await accident.getStateGate?.release()
        let completion = await evaluation.value

        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertEqual(accident.getStateCount, 2)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertTrue(notifications.accidentPosts.isEmpty)
        XCTAssertTrue(notifications.reauthPosts.isEmpty)
        XCTAssertTrue(prefs.setSeenCalls.isEmpty)
        XCTAssertEqual(automatic.callCount, 0)
    }

    func test_invalidationAtAccidentNotificationOwnerBoundaryPreventsPostAndSeenWrite() async throws {
        let prefs = try automaticPreferences()
        let accident = FakeAccidentStateRepository()
        accident.result = accidentState(42)
        let notifications = SpyNotifications()
        let automatic = SpyAutoActivities()
        let coordinator = OrchestratorAuthSessionCoordinator(
            authRepository: NoopAuthRepository(),
            securePasswordStore: NoopSecurePasswordStore()
        )
        notifications.beforeGuardedAccidentPost = {
            _ = coordinator.invalidateCurrentIdentity()
        }

        let completion = await makeOrchestrator(
            prefs: prefs,
            autoActivities: automatic,
            accidentRepository: accident,
            notifications: notifications,
            authSessionCoordinator: coordinator
        ).runOnce(.geofence)

        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertTrue(notifications.accidentPosts.isEmpty)
        XCTAssertTrue(prefs.setSeenCalls.isEmpty)
        XCTAssertEqual(automatic.callCount, 0)
    }

    func test_invalidationAtSeenPersistenceOwnerBoundaryPreventsStaleWrite() async throws {
        let prefs = try automaticPreferences()
        let accident = FakeAccidentStateRepository()
        accident.result = accidentState(42)
        let notifications = SpyNotifications()
        let automatic = SpyAutoActivities()
        let coordinator = OrchestratorAuthSessionCoordinator(
            authRepository: NoopAuthRepository(),
            securePasswordStore: NoopSecurePasswordStore()
        )
        prefs.beforeGuardedSeenWrite = {
            _ = coordinator.invalidateCurrentIdentity()
        }

        let completion = await makeOrchestrator(
            prefs: prefs,
            autoActivities: automatic,
            accidentRepository: accident,
            notifications: notifications,
            authSessionCoordinator: coordinator
        ).runOnce(.geofence)

        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertEqual(notifications.accidentPosts, ["pt"])
        XCTAssertTrue(prefs.setSeenCalls.isEmpty)
        XCTAssertEqual(automatic.callCount, 0)
    }
}
