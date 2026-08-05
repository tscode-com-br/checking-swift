import Foundation
import XCTest
@testable import Checking

final class BackgroundDependencyResolutionTests: XCTestCase {
    private final class MutableClock: Clock, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        func now() -> Date {
            lock.withLock { value }
        }

        func advance(_ interval: TimeInterval) {
            lock.withLock {
                value = value.addingTimeInterval(interval)
            }
        }
    }

    private let initialOptions = LocationOptions(
        items: ["alpha"],
        accuracyThresholdMeters: 40,
        mixedZoneIntervalMinutes: 12
    )

    private let refreshedOptions = LocationOptions(
        items: ["beta"],
        accuracyThresholdMeters: 25,
        mixedZoneIntervalMinutes: 7
    )

    private var dependencyErrors: [(name: String, error: ApiError)] {
        [
            ("unauthorized", .unauthorized),
            ("network", .network),
            ("http422", .http(status: 422, detail: "validation-sentinel")),
            ("other4xx", .http(status: 418, detail: "client-sentinel")),
            ("http500", .http(status: 500, detail: "server-sentinel")),
            ("conflict", .conflict),
            ("unknown", .unknown(description: "unknown-sentinel"))
        ]
    }

    private var hardOptionsErrors: [(name: String, error: ApiError)] {
        dependencyErrors.filter { $0.name != "network" }
    }

    private func history(
        action: CheckAction?,
        chave: String = "HR70",
        project: String = "P80"
    ) -> HistoryState {
        HistoryState(
            found: action != nil,
            chave: chave,
            projeto: project,
            currentAction: action,
            currentLocal: action == .checkIn ? "local-alpha" : nil,
            hasCurrentDayCheckin: action == .checkIn,
            lastCheckinAt: action == .checkIn ? iso("2026-07-30T09:00:00Z") : nil,
            lastCheckoutAt: action == .checkOut ? iso("2026-07-30T09:00:00Z") : nil,
            transportEnabled: false
        )
    }

    private func activePreferences(
        chave: String = "HR70",
        project: String = "P80"
    ) -> FakeAppPreferences {
        let settings = UserSettings(
            projects: [project],
            activeProject: project,
            automaticActivitiesEnabled: true,
            scheduledPauseEnabled: false,
            scheduledPauseFrom: "20:00",
            scheduledPauseTo: "07:00",
            suspendSaturdays: false,
            suspendSundays: false,
            notifyActivities: false,
            notifyScheduledPause: false,
            notifyAccident: false
        )
        let data = try! JSONCoding.encoder.encode([chave: settings])
        let preferences = FakeAppPreferences()
        preferences.chaveValue = chave
        preferences.languageValue = "pt"
        preferences.userSettingsJsonValue = String(data: data, encoding: .utf8)!
        return preferences
    }

    func test_locationOptions_remoteThenCacheUntilExactTTLBoundary() async {
        let clock = MutableClock(iso("2026-07-30T10:00:00Z"))
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(initialOptions)
        let sut = makeOrchestrator(checkRepository: repository, clock: clock)

        let remote = await sut.getLocationOptions()

        XCTAssertEqual(
            remote,
            .resolved(initialOptions, source: .remote, upstreamFailure: nil)
        )
        XCTAssertEqual(repository.getLocationsCallCount, 1)

        repository.getLocationsResult = .success(refreshedOptions)
        clock.advance(BackgroundCheckOrchestrator.locationOptionsTTL - 0.001)

        let cached = await sut.getLocationOptions()

        XCTAssertEqual(
            cached,
            .resolved(initialOptions, source: .cache, upstreamFailure: nil)
        )
        XCTAssertEqual(repository.getLocationsCallCount, 1)

        clock.advance(0.001)

        let refreshed = await sut.getLocationOptions()

        XCTAssertEqual(
            refreshed,
            .resolved(refreshedOptions, source: .remote, upstreamFailure: nil)
        )
        XCTAssertEqual(repository.getLocationsCallCount, 2)
    }

    func test_locationOptions_networkAfterTTL_reusesCacheAndPreservesFailure() async {
        let clock = MutableClock(iso("2026-07-30T10:00:00Z"))
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(initialOptions)
        let sut = makeOrchestrator(checkRepository: repository, clock: clock)
        _ = await sut.getLocationOptions()

        clock.advance(BackgroundCheckOrchestrator.locationOptionsTTL)
        repository.getLocationsResult = .failure(.network)

        let resolution = await sut.getLocationOptions()

        XCTAssertEqual(
            resolution,
            .resolved(initialOptions, source: .cache, upstreamFailure: .network)
        )
        XCTAssertEqual(resolution.value, initialOptions)
        XCTAssertEqual(resolution.source, .cache)
        XCTAssertEqual(resolution.failure, .network)
        XCTAssertEqual(repository.getLocationsCallCount, 2)
    }

    func test_locationOptions_networkWithoutCache_usesOfflineDefaultAndPreservesFailure() async {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .failure(.network)
        let sut = makeOrchestrator(checkRepository: repository)

        let resolution = await sut.getLocationOptions()

        let expected = LocationOptions(
            items: [],
            accuracyThresholdMeters: DEFAULT_ACCURACY_THRESHOLD_METERS,
            mixedZoneIntervalMinutes: 0
        )
        XCTAssertEqual(
            resolution,
            .resolved(expected, source: .offlineDefault, upstreamFailure: .network)
        )
        XCTAssertEqual(resolution.value, expected)
        XCTAssertEqual(resolution.source, .offlineDefault)
        XCTAssertEqual(resolution.failure, .network)
        XCTAssertEqual(repository.getLocationsCallCount, 1)
    }

    func test_locationOptions_hardErrorsRemainTypedAndNeverBecomeOfflineDefaults() async {
        for testCase in hardOptionsErrors {
            let repository = FakeCheckRepository()
            repository.getLocationsResult = .failure(testCase.error)
            let sut = makeOrchestrator(checkRepository: repository)

            let resolution = await sut.getLocationOptions()

            XCTAssertEqual(
                resolution,
                .failed(testCase.error),
                "unexpected options resolution for \(testCase.name)"
            )
            XCTAssertNil(resolution.value, testCase.name)
            XCTAssertNil(resolution.source, testCase.name)
            XCTAssertEqual(resolution.failure, testCase.error, testCase.name)
            XCTAssertEqual(repository.getLocationsCallCount, 1, testCase.name)
        }
    }

    func test_runOnce_offlineDefaultOptionsReachMotorWithExactLegacyFallbackValues() async {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .failure(.network)
        repository.getStateResult = .success(history(action: nil))
        let automaticActivities = SpyAutoActivities()
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            checkRepository: repository,
            autoActivities: automaticActivities
        )

        await sut.runOnce(.geofence)

        XCTAssertEqual(automaticActivities.callCount, 1)
        XCTAssertEqual(
            automaticActivities.calls.first?.accuracyThresholdMeters,
            DEFAULT_ACCURACY_THRESHOLD_METERS
        )
        XCTAssertEqual(
            automaticActivities.calls.first?.mixedZoneIntervalMinutes,
            0
        )
        XCTAssertEqual(repository.getLocationsCallCount, 1)
        XCTAssertEqual(repository.getStateCallCount, 1)
    }

    func test_runOnce_hardOptionsFailuresStopBeforeStateAndMotor() async {
        for testCase in hardOptionsErrors {
            let repository = FakeCheckRepository()
            repository.getLocationsResult = .failure(testCase.error)
            let automaticActivities = SpyAutoActivities()
            let sut = makeOrchestrator(
                prefs: activePreferences(),
                checkRepository: repository,
                autoActivities: automaticActivities
            )

            await sut.runOnce(.geofence)

            XCTAssertEqual(repository.getLocationsCallCount, 1, testCase.name)
            XCTAssertEqual(repository.getStateCallCount, 0, testCase.name)
            XCTAssertEqual(automaticActivities.callCount, 0, testCase.name)
        }
    }

    func test_remoteState_remoteThenCacheUntilExactTTLBoundary() async {
        let clock = MutableClock(iso("2026-07-30T10:00:00Z"))
        let repository = FakeCheckRepository()
        let initial = history(action: .checkIn)
        let refreshed = history(action: .checkOut)
        repository.getStateResult = .success(initial)
        let sut = makeOrchestrator(checkRepository: repository, clock: clock)

        let remote = await sut.getRemoteState("HR70")

        XCTAssertEqual(
            remote,
            .resolved(initial, source: .remote, upstreamFailure: nil)
        )
        XCTAssertEqual(repository.getStateCallCount, 1)

        repository.getStateResult = .success(refreshed)
        clock.advance(BackgroundCheckOrchestrator.stateCacheTTL - 0.001)

        let cached = await sut.getRemoteState("HR70")

        XCTAssertEqual(
            cached,
            .resolved(initial, source: .cache, upstreamFailure: nil)
        )
        XCTAssertEqual(repository.getStateCallCount, 1)

        clock.advance(0.001)

        let updated = await sut.getRemoteState("HR70")

        XCTAssertEqual(
            updated,
            .resolved(refreshed, source: .remote, upstreamFailure: nil)
        )
        XCTAssertEqual(repository.getStateCallCount, 2)
    }

    func test_remoteState_cacheIsScopedToChave() async {
        let repository = FakeCheckRepository()
        let first = history(action: .checkIn, chave: "HR70")
        let second = history(action: .checkOut, chave: "AB12")
        repository.getStateResult = .success(first)
        let sut = makeOrchestrator(checkRepository: repository)
        _ = await sut.getRemoteState("HR70")

        repository.getStateResult = .success(second)

        let resolution = await sut.getRemoteState("AB12")

        XCTAssertEqual(
            resolution,
            .resolved(second, source: .remote, upstreamFailure: nil)
        )
        XCTAssertEqual(repository.getStateCallCount, 2)
    }

    func test_freshRemoteState_bypassesCacheAndRefreshesRegularStateCache() async {
        let repository = FakeCheckRepository()
        let cachedState = history(action: .checkIn)
        let freshState = history(action: .checkOut)
        repository.getStateResult = .success(cachedState)
        let sut = makeOrchestrator(checkRepository: repository)
        _ = await sut.getRemoteState("HR70")

        repository.getStateResult = .success(freshState)

        let fresh = await sut.getFreshRemoteState("HR70")
        let cachedAfterFreshRead = await sut.getRemoteState("HR70")

        XCTAssertEqual(
            fresh,
            .resolved(freshState, source: .remote, upstreamFailure: nil)
        )
        XCTAssertEqual(
            cachedAfterFreshRead,
            .resolved(freshState, source: .cache, upstreamFailure: nil)
        )
        XCTAssertEqual(repository.getStateCallCount, 2)
    }

    func test_remoteState_errorsRemainTyped() async {
        for testCase in dependencyErrors {
            let repository = FakeCheckRepository()
            repository.getStateResult = .failure(testCase.error)
            let sut = makeOrchestrator(checkRepository: repository)

            let resolution = await sut.getRemoteState("HR70")

            XCTAssertEqual(
                resolution,
                .failed(testCase.error),
                "unexpected state resolution for \(testCase.name)"
            )
            XCTAssertNil(resolution.value, testCase.name)
            XCTAssertNil(resolution.source, testCase.name)
            XCTAssertEqual(resolution.failure, testCase.error, testCase.name)
            XCTAssertEqual(repository.getStateCallCount, 1, testCase.name)
        }
    }

    func test_freshRemoteState_errorsRemainTyped() async {
        for testCase in dependencyErrors {
            let repository = FakeCheckRepository()
            repository.getStateResult = .failure(testCase.error)
            let sut = makeOrchestrator(checkRepository: repository)

            let resolution = await sut.getFreshRemoteState("HR70")

            XCTAssertEqual(
                resolution,
                .failed(testCase.error),
                "unexpected fresh-state resolution for \(testCase.name)"
            )
            XCTAssertNil(resolution.value, testCase.name)
            XCTAssertNil(resolution.source, testCase.name)
            XCTAssertEqual(resolution.failure, testCase.error, testCase.name)
            XCTAssertEqual(repository.getStateCallCount, 1, testCase.name)
        }
    }

    func test_runOnce_passesNilStateToMotorForNonAuthTypedStateFailures() async {
        // Unauthorized possui recuperação tipada por estágio desde o Prompt 13 e, portanto, não faz mais
        // parte do fallback legado `state == nil` exercitado por esta tabela.
        for testCase in dependencyErrors where testCase.name != "unauthorized" {
            let repository = FakeCheckRepository()
            repository.getLocationsResult = .success(initialOptions)
            repository.getStateResult = .failure(testCase.error)
            let automaticActivities = SpyAutoActivities()
            let sut = makeOrchestrator(
                prefs: activePreferences(),
                checkRepository: repository,
                autoActivities: automaticActivities
            )

            await sut.runOnce(.geofence)

            XCTAssertEqual(
                automaticActivities.callCount,
                1,
                "motor call count for \(testCase.name)"
            )
            XCTAssertNil(
                automaticActivities.calls.first?.currentState,
                "currentState for \(testCase.name)"
            )
            XCTAssertEqual(repository.getStateCallCount, 1, testCase.name)
        }
    }

    func test_matchUnauthorizedWithoutRetryContext_doesNotInventAuthRetry() async {
        await assertTypedAutomaticUnauthorizedDoesNotReauthenticate(
            failure: .match(.unauthorized),
            maximumStage: .matched,
            submissionContext: nil
        )
    }

    func test_submitUnauthorized_doesNotTriggerAuthRetryOrReauthNotification() async {
        let now = iso("2026-07-30T10:00:00Z")
        await assertTypedAutomaticUnauthorizedDoesNotReauthenticate(
            failure: .submit(.unauthorized),
            maximumStage: .submitStarted,
            submissionContext: AutomaticSubmissionContext(
                chave: "HR70",
                projeto: "P80",
                action: .checkIn,
                local: nil,
                informe: .normal,
                eventTime: now,
                clientEventId: "event-id-sentinel",
                fillForms: true
            )
        )
    }

    func test_lateOptionsSuccessFromInvalidatedSessionIsStaleAndNeverPopulatesCacheOrStartsEngine() async {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(initialOptions)
        repository.getLocationsStarted = AsyncGate()
        repository.getLocationsGate = AsyncGate()
        let automaticActivities = SpyAutoActivities()
        let coordinator = OrchestratorAuthSessionCoordinator(
            authRepository: NoopAuthRepository(),
            securePasswordStore: NoopSecurePasswordStore()
        )
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            checkRepository: repository,
            autoActivities: automaticActivities,
            authSessionCoordinator: coordinator
        )

        let evaluation = Task { await sut.runOnce(.geofence) }
        await repository.getLocationsStarted?.wait()
        let invalidation = coordinator.invalidateCurrentIdentity()
        await repository.getLocationsGate?.release()
        let completion = await evaluation.value

        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertEqual(repository.getLocationsCallCount, 1)
        XCTAssertEqual(repository.getStateCallCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertEqual(automaticActivities.callCount, 0)

        await coordinator.completeInvalidatedTransition(invalidation)
        repository.getLocationsResult = .success(refreshedOptions)
        let next = await sut.getLocationOptions()
        XCTAssertEqual(
            next,
            .resolved(refreshedOptions, source: .remote, upstreamFailure: nil)
        )
        XCTAssertEqual(repository.getLocationsCallCount, 2)
    }

    func test_lateStateSuccessFromInvalidatedSessionIsStaleAndNeverPopulatesCacheOrStartsEngine() async {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(initialOptions)
        let staleState = history(action: .checkIn)
        let replacementState = history(action: .checkOut)
        repository.getStateResult = .success(staleState)
        repository.getStateStarted = AsyncGate()
        repository.getStateGate = AsyncGate()
        let automaticActivities = SpyAutoActivities()
        let coordinator = OrchestratorAuthSessionCoordinator(
            authRepository: NoopAuthRepository(),
            securePasswordStore: NoopSecurePasswordStore()
        )
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            checkRepository: repository,
            autoActivities: automaticActivities,
            authSessionCoordinator: coordinator
        )

        let evaluation = Task { await sut.runOnce(.geofence) }
        await repository.getStateStarted?.wait()
        let invalidation = coordinator.invalidateCurrentIdentity()
        await repository.getStateGate?.release()
        let completion = await evaluation.value

        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertEqual(repository.getLocationsCallCount, 1)
        XCTAssertEqual(repository.getStateCallCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertEqual(automaticActivities.callCount, 0)

        await coordinator.completeInvalidatedTransition(invalidation)
        repository.getStateResult = .success(replacementState)
        let next = await sut.getRemoteState("HR70")
        XCTAssertEqual(
            next,
            .resolved(replacementState, source: .remote, upstreamFailure: nil)
        )
        XCTAssertEqual(repository.getStateCallCount, 2)
    }

    private func assertTypedAutomaticUnauthorizedDoesNotReauthenticate(
        failure: AutomaticActivitiesFailure,
        maximumStage: AutomaticActivitiesStage,
        submissionContext: AutomaticSubmissionContext?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(initialOptions)
        repository.getStateResult = .success(history(action: nil))
        let automaticActivities = SpyAutoActivities()
        automaticActivities.execution = AutomaticActivitiesExecution(
            result: .networkError,
            trace: AutomaticActivitiesTrace(
                maximumStage: maximumStage,
                capture: nil,
                failure: failure,
                offlineDisposition: nil
            ),
            submissionContext: submissionContext
        )
        let auth = SpyAuthRepository()
        let notifications = SpyNotifications()
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            checkRepository: repository,
            autoActivities: automaticActivities,
            notifications: notifications,
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(password: "password-sentinel")
        )

        await sut.runOnce(.geofence)

        XCTAssertEqual(automaticActivities.callCount, 1, file: file, line: line)
        XCTAssertEqual(repository.getStateCallCount, 1, file: file, line: line)
        XCTAssertEqual(auth.callCount, 0, file: file, line: line)
        XCTAssertTrue(notifications.reauthPosts.isEmpty, file: file, line: line)
    }
}
