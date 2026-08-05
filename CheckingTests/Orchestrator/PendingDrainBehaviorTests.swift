import Foundation
import XCTest
@testable import Checking

/// Provas de integração dos efeitos do drain do único pending normal candidato.
///
/// Os gates suspendem seams explícitos do pipeline. Não há sleep, Core Location real ou rede, e as
/// contagens atravessam os casos de uso de produção quando o comportamento sob prova depende da matriz.
final class PendingDrainBehaviorTests: XCTestCase {
    private actor StateRecordingActivities: RunningAutomaticActivities {
        private let firstCallStarted = AsyncGate()
        private let firstCallRelease = AsyncGate()
        private var recordedStates: [HistoryState?] = []

        func execute(
            chave: String,
            userProjects: UserProjects?,
            currentState: HistoryState?,
            mixedZoneIntervalMinutes: Int,
            accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> AutomaticActivitiesExecution {
            let isFirstCall = recordedStates.isEmpty
            recordedStates.append(currentState)
            if isFirstCall {
                await firstCallStarted.release()
                await firstCallRelease.wait()
            }
            return AutomaticActivitiesExecution(
                result: .noAction,
                trace: AutomaticActivitiesTrace(
                    maximumStage: .decisionCompleted,
                    capture: nil,
                    failure: nil,
                    offlineDisposition: nil
                ),
                submissionContext: nil
            )
        }

        func waitUntilFirstCallStarts() async {
            await firstCallStarted.wait()
        }

        func releaseFirstCall() async {
            await firstCallRelease.release()
        }

        func states() -> [HistoryState?] {
            recordedStates
        }
    }

    private final class SubmitGatedRepository: CheckRepository, @unchecked Sendable {
        let base: FakeCheckRepository
        private let submitStarted = AsyncGate()
        private let submitRelease = AsyncGate()

        init(base: FakeCheckRepository) {
            self.base = base
        }

        func matchLocation(
            _ lat: Double,
            _ lon: Double,
            _ accuracyMeters: Double?
        ) async -> AppResult<LocationMatch> {
            await base.matchLocation(lat, lon, accuracyMeters)
        }

        func getState(_ chave: String) async -> AppResult<HistoryState> {
            await base.getState(chave)
        }

        func getHistory(
            _ chave: String
        ) async -> AppResult<[CheckHistoryEntry]> {
            await base.getHistory(chave)
        }

        func getLocations() async -> AppResult<LocationOptions> {
            await base.getLocations()
        }

        func getGeofences(
            _ chave: String
        ) async -> AppResult<[GeofenceCircle]> {
            await base.getGeofences(chave)
        }

        func invalidateGeofenceCache() {
            base.invalidateGeofenceCache()
        }

        func submit(
            chave: String,
            projeto: String,
            action: CheckAction,
            local: String?,
            informe: InformeType,
            eventTime: Date,
            clientEventId: String,
            fillForms: Bool
        ) async -> AppResult<HistoryState> {
            await submitStarted.release()
            await submitRelease.wait()
            return await base.submit(
                chave: chave,
                projeto: projeto,
                action: action,
                local: local,
                informe: informe,
                eventTime: eventTime,
                clientEventId: clientEventId,
                fillForms: fillForms
            )
        }

        func waitUntilSubmitStarts() async {
            await submitStarted.wait()
        }

        func releaseSubmit() async {
            await submitRelease.release()
        }
    }

    private final class MatchGatedRepository: CheckRepository, @unchecked Sendable {
        let base: FakeCheckRepository
        private let blockingCall: Int
        private let matchStarted = AsyncGate()
        private let matchRelease = AsyncGate()
        private let lock = NSLock()
        private var matchCalls = 0

        init(base: FakeCheckRepository, blockingCall: Int) {
            self.base = base
            self.blockingCall = blockingCall
        }

        var matchCallCount: Int {
            lock.withLock { matchCalls }
        }

        func matchLocation(
            _ lat: Double,
            _ lon: Double,
            _ accuracyMeters: Double?
        ) async -> AppResult<LocationMatch> {
            let shouldBlock = lock.withLock {
                matchCalls += 1
                return matchCalls == blockingCall
            }
            if shouldBlock {
                await matchStarted.release()
                await matchRelease.wait()
            }
            return await base.matchLocation(lat, lon, accuracyMeters)
        }

        func getState(_ chave: String) async -> AppResult<HistoryState> {
            await base.getState(chave)
        }

        func getHistory(
            _ chave: String
        ) async -> AppResult<[CheckHistoryEntry]> {
            await base.getHistory(chave)
        }

        func getLocations() async -> AppResult<LocationOptions> {
            await base.getLocations()
        }

        func getGeofences(
            _ chave: String
        ) async -> AppResult<[GeofenceCircle]> {
            await base.getGeofences(chave)
        }

        func invalidateGeofenceCache() {
            base.invalidateGeofenceCache()
        }

        func submit(
            chave: String,
            projeto: String,
            action: CheckAction,
            local: String?,
            informe: InformeType,
            eventTime: Date,
            clientEventId: String,
            fillForms: Bool
        ) async -> AppResult<HistoryState> {
            await base.submit(
                chave: chave,
                projeto: projeto,
                action: action,
                local: local,
                informe: informe,
                eventTime: eventTime,
                clientEventId: clientEventId,
                fillForms: fillForms
            )
        }

        func waitUntilBlockingMatchStarts() async {
            await matchStarted.wait()
        }

        func releaseBlockingMatch() async {
            await matchRelease.release()
        }
    }

    private final class ClientEventIDFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var generated: [String] = []

        var values: [String] {
            lock.withLock { generated }
        }

        func next() -> String {
            lock.withLock {
                let value = "pending-drain-event-\(generated.count + 1)"
                generated.append(value)
                return value
            }
        }
    }

    private let now = iso("2026-07-31T08:00:00Z")

    override func setUp() {
        super.setUp()
        EvaluationLog.shared.reset()
    }

    func test_pendingFollowUpForcesFreshStateDespiteFirstEvaluationFillingLiveCache() async {
        let cachedState = history(.checkOut)
        let freshState = history(.checkIn, local: "Unidade P80")
        let repository = configuredRepository()
        repository.queuedGetStateResults = [
            .success(cachedState),
            .success(freshState),
        ]
        let activities = StateRecordingActivities()
        let sut = makeOrchestrator(
            prefs: preferences(),
            checkRepository: repository,
            autoActivities: activities,
            locationProvider: FakeLocationProvider(.unavailable),
            automaticEvaluationPipeline: .candidate,
            clock: FixedClock(now)
        )

        let first = await sut.evaluationTicket(.geofence)
        XCTAssertEqual(first.admission, .admitted)
        await activities.waitUntilFirstCallStarts()
        XCTAssertEqual(repository.getStateCallCount, 1)

        let pending = await sut.evaluationTicket(.geofence)
        XCTAssertEqual(pending.admission, .deferred)
        await activities.releaseFirstCall()

        let firstCompletion = await first.completion()
        let pendingCompletion = await pending.completion()
        let observedStates = await activities.states()

        XCTAssertEqual(firstCompletion.outcome, .noAction)
        XCTAssertEqual(pendingCompletion.outcome, .noAction)
        XCTAssertEqual(
            repository.getStateCallCount,
            2,
            "o follow-up deve ignorar o cache vivo de 45 s e executar um novo GET state"
        )
        XCTAssertEqual(observedStates, [cachedState, freshState])
    }

    func test_firstEvaluationSubmitsAndPendingNoActionDoesNotDuplicateIDSubmitOrNotification() async {
        let checkedOut = history(.checkOut)
        let checkedIn = history(.checkIn, local: "Unidade P80")
        let base = configuredRepository()
        base.queuedGetStateResults = [
            .success(checkedOut),
            .success(checkedIn),
        ]
        base.submitResult = .success(checkedIn)
        let repository = SubmitGatedRepository(base: base)
        let provider = FakeLocationProvider(.success(sample()))
        let notifications = SpyNotifications()
        let eventIDs = ClientEventIDFactory()
        let sut = actualCandidateOrchestrator(
            repository: repository,
            provider: provider,
            notifications: notifications,
            preferences: preferences(notifyActivities: true),
            makeClientEventID: eventIDs.next
        )

        let first = await sut.evaluationTicket(.geofence)
        await repository.waitUntilSubmitStarts()
        XCTAssertEqual(eventIDs.values, ["pending-drain-event-1"])

        let pending = await sut.evaluationTicket(.geofence)
        XCTAssertEqual(pending.admission, .deferred)
        await repository.releaseSubmit()

        let firstCompletion = await first.completion()
        let pendingCompletion = await pending.completion()

        XCTAssertEqual(firstCompletion.outcome, .submittedCheckIn)
        XCTAssertEqual(pendingCompletion.outcome, .noAction)
        XCTAssertNotEqual(first.evaluationID, pending.evaluationID)
        XCTAssertEqual(base.getStateCallCount, 2)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(base.matchLocationCallCount, 2)
        XCTAssertEqual(base.submitCount, 1)
        XCTAssertEqual(base.submitCalls.count, 1)
        XCTAssertEqual(base.submitCalls.first?.clientEventId, "pending-drain-event-1")
        XCTAssertEqual(base.submitCalls.first?.eventTime, now)
        XCTAssertEqual(eventIDs.values, ["pending-drain-event-1"])
        XCTAssertEqual(notifications.activityPosts.count, 1)
        XCTAssertEqual(notifications.activityPosts.first?.action, .checkIn)
        XCTAssertEqual(notifications.activityPosts.first?.local, "Unidade P80")
        XCTAssertEqual(notifications.activityPosts.first?.lang, "pt")
    }

    func test_firstEvaluationSubmitsAndPendingFreshStateFailureDoesNotSubmitAgain() async {
        let checkedOut = history(.checkOut)
        let checkedIn = history(.checkIn, local: "Unidade P80")
        let base = configuredRepository()
        base.queuedGetStateResults = [
            .success(checkedOut),
            .failure(.network),
        ]
        base.submitResult = .success(checkedIn)
        let repository = SubmitGatedRepository(base: base)
        let provider = FakeLocationProvider(.success(sample()))
        let notifications = SpyNotifications()
        let eventIDs = ClientEventIDFactory()
        let journal = RecordingEvaluationJournal()
        let sut = actualCandidateOrchestrator(
            repository: repository,
            provider: provider,
            notifications: notifications,
            preferences: preferences(notifyActivities: true),
            journal: journal,
            makeClientEventID: eventIDs.next
        )

        let first = await sut.evaluationTicket(.geofence)
        await repository.waitUntilSubmitStarts()
        let pending = await sut.evaluationTicket(.geofence)
        XCTAssertEqual(pending.admission, .deferred)

        await repository.releaseSubmit()
        let firstCompletion = await first.completion()
        XCTAssertEqual(firstCompletion.outcome, .submittedCheckIn)
        let pendingCompletion = await pending.completion()

        XCTAssertEqual(pendingCompletion.outcome, .networkFailure)
        XCTAssertEqual(base.getStateCallCount, 2)
        XCTAssertEqual(
            provider.callCount,
            1,
            "a falha da dependência state no follow-up GEOFENCE encerra antes de ligar localização"
        )
        XCTAssertEqual(
            base.matchLocationCallCount,
            1,
            "o follow-up continua canônico, mas não deve matchear após falha obrigatória de state"
        )
        XCTAssertEqual(base.submitCount, 1)
        XCTAssertEqual(base.submitCalls.count, 1)
        XCTAssertEqual(eventIDs.values, ["pending-drain-event-1"])
        XCTAssertEqual(notifications.activityPosts.count, 1)

        let journalSnapshot = await journal.snapshot()
        let pendingTerminal = try? XCTUnwrap(
            journalSnapshot.finishes.first {
                $0.id == pending.evaluationID
            }?.terminal
        )
        XCTAssertEqual(pendingTerminal?.outcome, .networkFailure)
        XCTAssertEqual(pendingTerminal?.stage, .state)
    }

    func test_oldContextIrreversibleActionCannotSuppressSameActionInNewContext() async {
        let checkedOut = history(.checkOut)
        let checkedIn = history(.checkIn, local: "Unidade P80")
        let base = configuredRepository()
        base.queuedGetStateResults = [
            .success(checkedOut),
            .success(checkedOut),
        ]
        base.submitResult = .success(checkedIn)
        let repository = SubmitGatedRepository(base: base)
        let provider = FakeLocationProvider(.success(sample()))
        let eventIDs = ClientEventIDFactory()
        let sut = actualCandidateOrchestrator(
            repository: repository,
            provider: provider,
            notifications: SpyNotifications(),
            preferences: preferences(),
            makeClientEventID: eventIDs.next
        )

        let oldContext = await sut.evaluationTicket(.geofence)
        await repository.waitUntilSubmitStarts()

        let transition = await sut.beginAutomationContextTransition()
        await sut.endAutomationContextTransition(transition)

        let newContext = await sut.evaluationTicket(.geofence)
        XCTAssertEqual(newContext.admission, .deferred)

        await repository.releaseSubmit()
        let oldCompletion = await oldContext.completion()
        let newCompletion = await newContext.completion()

        XCTAssertEqual(oldCompletion.outcome, .submittedCheckIn)
        XCTAssertEqual(newCompletion.outcome, .submittedCheckIn)
        XCTAssertEqual(base.getStateCallCount, 2)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(base.matchLocationCallCount, 2)
        XCTAssertEqual(base.submitCount, 2)
        XCTAssertEqual(
            eventIDs.values,
            ["pending-drain-event-1", "pending-drain-event-2"],
            "o suppressor da geração antiga não pode ser herdado pela avaliação do contexto novo"
        )
    }

    func test_firstEvaluationQueuesDecidedAndPendingDoesNotRepeatSameDecision() async {
        let checkedOut = history(.checkOut)
        let base = configuredRepository()
        base.queuedGetStateResults = [
            .success(checkedOut),
            .success(checkedOut),
        ]
        base.submitResult = .failure(.network)
        let repository = SubmitGatedRepository(base: base)
        let provider = FakeLocationProvider(.success(sample()))
        let notifications = SpyNotifications()
        let eventIDs = ClientEventIDFactory()
        let offlineQueue = FakeOfflineQueue()
        let sut = actualCandidateOrchestrator(
            repository: repository,
            provider: provider,
            notifications: notifications,
            preferences: preferences(notifyActivities: true),
            offlineQueue: offlineQueue,
            makeClientEventID: eventIDs.next
        )

        let first = await sut.evaluationTicket(.geofence)
        await repository.waitUntilSubmitStarts()
        let pending = await sut.evaluationTicket(.geofence)
        await repository.releaseSubmit()

        let firstCompletion = await first.completion()
        let pendingCompletion = await pending.completion()
        XCTAssertEqual(firstCompletion.outcome, .queuedOfflineDecided)
        XCTAssertEqual(pendingCompletion.outcome, .noAction)
        XCTAssertEqual(base.getStateCallCount, 2)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(base.matchLocationCallCount, 2)
        XCTAssertEqual(base.submitCount, 1)
        XCTAssertEqual(offlineQueue.enqueued.count, 1)
        XCTAssertEqual(eventIDs.values, ["pending-drain-event-1"])
        XCTAssertTrue(notifications.activityPosts.isEmpty)
    }

    func test_pendingTimerFreshStateUnauthorizedReloginReusesPreparedMatch() async {
        let checkedOut = history(.checkOut)
        let checkedIn = history(.checkIn, local: "Unidade P80")
        let base = configuredRepository()
        base.queuedGetStateResults = [
            .success(checkedOut),
            .failure(.unauthorized),
            .success(checkedOut),
        ]
        base.submitResult = .success(checkedIn)
        let repository = SubmitGatedRepository(base: base)
        let provider = FakeLocationProvider(.success(sample()))
        let eventIDs = ClientEventIDFactory()
        let auth = SpyAuthRepository()
        auth.result = .success(
            AuthStatus(
                found: true,
                chave: "HR70",
                hasPassword: true,
                authenticated: true,
                message: "ok"
            )
        )
        let sut = actualCandidateOrchestrator(
            repository: repository,
            provider: provider,
            notifications: SpyNotifications(),
            preferences: preferences(),
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            ),
            makeClientEventID: eventIDs.next
        )

        let first = await sut.evaluationTicket(.geofence)
        await repository.waitUntilSubmitStarts()
        let pendingTimer = await sut.evaluationTicket(.timer)
        await repository.releaseSubmit()

        let firstCompletion = await first.completion()
        let pendingCompletion = await pendingTimer.completion()
        XCTAssertEqual(firstCompletion.outcome, .submittedCheckIn)
        XCTAssertEqual(pendingCompletion.outcome, .noAction)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(base.matchLocationCallCount, 2)
        XCTAssertEqual(base.getStateCallCount, 3)
        XCTAssertEqual(base.submitCount, 1)
        XCTAssertEqual(eventIDs.values, ["pending-drain-event-1"])
    }

    func test_pendingTimerFreshStateUnauthorizedReloginFailureKeepsOneCaptureAndTrace() async {
        let checkedOut = history(.checkOut)
        let checkedIn = history(.checkIn, local: "Unidade P80")
        let base = configuredRepository()
        base.queuedGetStateResults = [
            .success(checkedOut),
            .failure(.unauthorized),
        ]
        base.submitResult = .success(checkedIn)
        let repository = SubmitGatedRepository(base: base)
        let provider = FakeLocationProvider(.success(sample()))
        let auth = SpyAuthRepository()
        auth.result = .failure(.network)
        let journal = RecordingEvaluationJournal()
        let sut = actualCandidateOrchestrator(
            repository: repository,
            provider: provider,
            notifications: SpyNotifications(),
            preferences: preferences(),
            journal: journal,
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            ),
            makeClientEventID: { "pending-drain-event" }
        )

        let first = await sut.evaluationTicket(.geofence)
        await repository.waitUntilSubmitStarts()
        let pendingTimer = await sut.evaluationTicket(.timer)
        await repository.releaseSubmit()

        let firstCompletion = await first.completion()
        let pendingCompletion = await pendingTimer.completion()
        XCTAssertEqual(firstCompletion.outcome, .submittedCheckIn)
        XCTAssertEqual(pendingCompletion.outcome, .reloginFailed)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(base.matchLocationCallCount, 2)
        XCTAssertEqual(base.getStateCallCount, 2)
        XCTAssertEqual(base.submitCount, 1)

        let journalSnapshot = await journal.snapshot()
        let terminal = journalSnapshot.finishes.first {
            $0.id == pendingTimer.evaluationID
        }?.terminal
        XCTAssertEqual(terminal?.locationSource, .freshCapture)
        XCTAssertEqual(terminal?.captureReused, true)
        XCTAssertNotNil(terminal?.accuracyBucket)
        XCTAssertNotNil(terminal?.ageBucket)
    }

    func test_firstEvaluationQueuesRawAndPendingNetworkFailureKeepsOneRawPerCanonicalEvaluation() async {
        let base = configuredRepository()
        base.matchLocationResult = .failure(.network)
        let repository = MatchGatedRepository(base: base, blockingCall: 1)
        let provider = FakeLocationProvider(.success(sample()))
        let notifications = SpyNotifications()
        let eventIDs = ClientEventIDFactory()
        let offlineQueue = FakeOfflineQueue()
        let sut = actualCandidateOrchestrator(
            repository: repository,
            provider: provider,
            notifications: notifications,
            preferences: preferences(),
            offlineQueue: offlineQueue,
            makeClientEventID: eventIDs.next
        )

        let first = await sut.evaluationTicket(.geofence)
        await repository.waitUntilBlockingMatchStarts()
        let pending = await sut.evaluationTicket(.geofence)
        await repository.releaseBlockingMatch()

        let firstCompletion = await first.completion()
        let pendingCompletion = await pending.completion()
        XCTAssertEqual(firstCompletion.outcome, .queuedOfflineRaw)
        XCTAssertEqual(pendingCompletion.outcome, .queuedOfflineRaw)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(repository.matchCallCount, 2)
        XCTAssertEqual(base.matchLocationCallCount, 2)
        XCTAssertEqual(base.submitCount, 0)
        XCTAssertEqual(offlineQueue.enqueued.count, 2)
        XCTAssertEqual(eventIDs.values, [
            "pending-drain-event-1",
            "pending-drain-event-2",
        ])
        XCTAssertTrue(notifications.activityPosts.isEmpty)
    }

    func test_pendingTimerMergedWithGeofenceRunsAsEventAndBypassesMovementSkip() async {
        let base = configuredRepository()
        base.getStateResult = .success(
            history(.checkIn, local: "Unidade P80")
        )
        let repository = MatchGatedRepository(
            base: base,
            blockingCall: 2
        )
        let provider = FakeLocationProvider(.success(sample()))
        let sut = actualCandidateOrchestrator(
            repository: repository,
            provider: provider,
            notifications: SpyNotifications(),
            preferences: preferences(),
            makeClientEventID: { "must-not-be-generated" }
        )

        let baseline = await sut.runOnce(.timer)
        XCTAssertEqual(baseline.outcome, .noAction)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchCallCount, 1)

        let runningEvent = await sut.evaluationTicket(.geofence)
        await repository.waitUntilBlockingMatchStarts()

        let pendingTimer = await sut.evaluationTicket(.timer)
        let mergedGeofence = await sut.evaluationTicket(.geofence)
        XCTAssertEqual(pendingTimer.admission, .deferred)
        XCTAssertEqual(mergedGeofence.admission, .coalesced)
        XCTAssertEqual(mergedGeofence.evaluationID, pendingTimer.evaluationID)

        await repository.releaseBlockingMatch()
        let runningEventCompletion = await runningEvent.completion()
        let pendingCompletion = await pendingTimer.completion()
        let mergedCompletion = await mergedGeofence.completion()

        XCTAssertEqual(runningEventCompletion.outcome, .noAction)
        XCTAssertEqual(pendingCompletion, mergedCompletion)
        XCTAssertEqual(
            pendingCompletion.outcome,
            .noAction,
            "o evento coalescido não pode herdar o skip exclusivo de TIMER"
        )
        XCTAssertEqual(provider.callCount, 3)
        XCTAssertEqual(
            repository.matchCallCount,
            3,
            "a terceira avaliação deve chegar ao matcher; como TIMER puro ela seria suprimida pelo baseline"
        )
        XCTAssertEqual(base.matchLocationCallCount, 3)
        XCTAssertEqual(base.getStateCallCount, 2)
        XCTAssertEqual(base.submitCount, 0)
    }

    private func preferences(
        notifyActivities: Bool = false
    ) -> FakeAppPreferences {
        let settings = UserSettings(
            projects: ["P80"],
            activeProject: "P80",
            automaticActivitiesEnabled: true,
            scheduledPauseEnabled: false,
            scheduledPauseFrom: "20:00",
            scheduledPauseTo: "07:00",
            suspendSaturdays: false,
            suspendSundays: false,
            notifyActivities: notifyActivities,
            notifyScheduledPause: false,
            notifyAccident: false
        )
        let data = try! JSONCoding.encoder.encode(["HR70": settings])
        let preferences = FakeAppPreferences()
        preferences.chaveValue = "HR70"
        preferences.languageValue = "pt"
        preferences.userSettingsJsonValue = String(decoding: data, as: UTF8.self)
        return preferences
    }

    private func configuredRepository() -> FakeCheckRepository {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(
            LocationOptions(
                items: ["Unidade P80"],
                accuracyThresholdMeters: 50,
                mixedZoneIntervalMinutes: 15
            )
        )
        repository.matchLocationResult = .success(
            ucMatch(.matched, "Unidade P80")
        )
        repository.getStateResult = .success(history(.checkOut))
        repository.submitResult = .success(
            history(.checkIn, local: "Unidade P80")
        )
        return repository
    }

    private func actualCandidateOrchestrator(
        repository: any CheckRepository,
        provider: any LocationProvider,
        notifications: SpyNotifications,
        preferences: FakeAppPreferences,
        journal: any EvaluationJournaling = NoopEvaluationJournal(),
        offlineQueue: any OfflineCheckQueueing = FakeOfflineQueue(),
        authRepository: any AuthRepositoring = NoopAuthRepository(),
        securePasswordStore: any SecurePasswordReading = NoopSecurePasswordStore(),
        makeClientEventID: @escaping @Sendable () -> String
    ) -> BackgroundCheckOrchestrator {
        let clock = FixedClock(now)
        let capture = CaptureLocationUseCase(
            locationProvider: provider,
            checkRepository: repository,
            activityLogger: NoopActivityLogger(),
            clock: clock,
            samplePolicy: .candidateTrial,
            captureBehavior: .freshnessValidated
        )
        let automatic = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: offlineQueue,
            clock: clock,
            activityLogger: NoopActivityLogger(),
            makeClientEventID: makeClientEventID
        )
        return makeOrchestrator(
            prefs: preferences,
            checkRepository: repository,
            autoActivities: automatic,
            notifications: notifications,
            locationProvider: provider,
            automaticEvaluationPipeline: .candidate,
            clock: clock,
            authRepository: authRepository,
            securePasswordStore: securePasswordStore,
            evaluationJournal: journal
        )
    }

    private func sample() -> LocationSample {
        LocationSample(
            latitude: 1.3,
            longitude: 103.8,
            horizontalAccuracyMeters: 12,
            capturedAt: now,
            source: .standardCapture
        )
    }

    private func history(
        _ action: CheckAction?,
        local: String? = nil
    ) -> HistoryState {
        HistoryState(
            found: action != nil,
            chave: "HR70",
            projeto: "P80",
            currentAction: action,
            currentLocal: local,
            hasCurrentDayCheckin: action == .checkIn,
            lastCheckinAt: action == .checkIn
                ? now.addingTimeInterval(-600)
                : nil,
            lastCheckoutAt: action == .checkOut
                ? now.addingTimeInterval(-600)
                : nil,
            transportEnabled: false
        )
    }
}
