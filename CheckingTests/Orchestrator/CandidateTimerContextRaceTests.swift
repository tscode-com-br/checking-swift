import Foundation
import XCTest
@testable import Checking

/// Corridas determinísticas entre a invalidação de conta/projeto/toggle e as etapas assíncronas do
/// pipeline TIMER candidato. Os portões são liberados explicitamente; nenhum teste depende de sleep.
final class CandidateTimerContextRaceTests: XCTestCase {
    private actor SuspendedFirstLocationProvider: LocationProvider {
        private let firstCaptureRelease = AsyncGate()
        private let capturedSample: LocationSample
        private(set) var callCount = 0

        init(sample: LocationSample) {
            capturedSample = sample
        }

        func capture(
            _ accuracyThresholdMeters: Int,
            seed: LocationSample?
        ) async -> LocationCapture {
            callCount += 1
            if callCount == 1 {
                await firstCaptureRelease.wait()
            }
            return .success(capturedSample)
        }

        func releaseFirstCapture() async {
            await firstCaptureRelease.release()
        }
    }

    private final class GatedCheckRepository: CheckRepository, @unchecked Sendable {
        enum SuspensionPoint {
            case match
            case state
        }

        let base: FakeCheckRepository
        let matchRelease = AsyncGate()
        let stateRelease = AsyncGate()
        private let suspensionPoint: SuspensionPoint

        init(
            base: FakeCheckRepository,
            suspensionPoint: SuspensionPoint
        ) {
            self.base = base
            self.suspensionPoint = suspensionPoint
        }

        func matchLocation(
            _ lat: Double,
            _ lon: Double,
            _ accuracyMeters: Double?
        ) async -> AppResult<LocationMatch> {
            let result = await base.matchLocation(
                lat,
                lon,
                accuracyMeters
            )
            if suspensionPoint == .match {
                await matchRelease.wait()
            }
            return result
        }

        func getState(_ chave: String) async -> AppResult<HistoryState> {
            let result = await base.getState(chave)
            if suspensionPoint == .state {
                await stateRelease.wait()
            }
            return result
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

        func releaseMatch() async {
            await matchRelease.release()
        }

        func releaseState() async {
            await stateRelease.release()
        }
    }

    /// Repositório que para exatamente antes do ponto atômico `performIfCurrent`. Diferentemente de um
    /// gate em volta do método assíncrono antigo, este fake conta um dispatch somente dentro do mesmo
    /// fence usado por produção para autorizar `URLSessionDataTask.resume()`.
    private final class CommitGatedCheckRepository: CheckRepository, @unchecked Sendable {
        enum CommitPoint {
            case match
            case submit
        }

        struct Snapshot: Equatable {
            let matchAttempts: Int
            let matchDispatches: Int
            let submitAttempts: Int
            let submitDispatches: Int
            let unguardedMatchCalls: Int
            let unguardedSubmitCalls: Int
            let intendedClientEventIDs: [String]
        }

        private let base: FakeCheckRepository
        private let commitPoint: CommitPoint
        private let matchResult: AppResult<LocationMatch>
        private let submitResult: AppResult<HistoryState>
        private let commitRelease = AsyncGate()
        private let lock = NSLock()
        private var matchAttempts = 0
        private var matchDispatches = 0
        private var submitAttempts = 0
        private var submitDispatches = 0
        private var unguardedMatchCalls = 0
        private var unguardedSubmitCalls = 0
        private var intendedClientEventIDs: [String] = []

        init(
            base: FakeCheckRepository,
            commitPoint: CommitPoint,
            matchResult: AppResult<LocationMatch>,
            submitResult: AppResult<HistoryState>
        ) {
            self.base = base
            self.commitPoint = commitPoint
            self.matchResult = matchResult
            self.submitResult = submitResult
        }

        var snapshot: Snapshot {
            lock.withLock {
                Snapshot(
                    matchAttempts: matchAttempts,
                    matchDispatches: matchDispatches,
                    submitAttempts: submitAttempts,
                    submitDispatches: submitDispatches,
                    unguardedMatchCalls: unguardedMatchCalls,
                    unguardedSubmitCalls: unguardedSubmitCalls,
                    intendedClientEventIDs: intendedClientEventIDs
                )
            }
        }

        func matchLocation(
            _ lat: Double,
            _ lon: Double,
            _ accuracyMeters: Double?
        ) async -> AppResult<LocationMatch> {
            lock.withLock { unguardedMatchCalls += 1 }
            return matchResult
        }

        func matchLocation(
            _ lat: Double,
            _ lon: Double,
            _ accuracyMeters: Double?,
            effectGuard: AutomaticActivitiesEffectGuard
        ) async -> GuardedOperationResult<AppResult<LocationMatch>> {
            lock.withLock { matchAttempts += 1 }
            if commitPoint == .match {
                await commitRelease.wait()
            }

            var committedResult: AppResult<LocationMatch>?
            let didDispatch = effectGuard.performIfCurrent {
                lock.withLock { matchDispatches += 1 }
                committedResult = matchResult
            }
            guard didDispatch, let committedResult else { return .notDispatched }
            return .dispatched(committedResult)
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
            lock.withLock { unguardedSubmitCalls += 1 }
            return submitResult
        }

        func submit(
            chave: String,
            projeto: String,
            action: CheckAction,
            local: String?,
            informe: InformeType,
            eventTime: Date,
            clientEventId: String,
            fillForms: Bool,
            effectGuard: AutomaticActivitiesEffectGuard
        ) async -> GuardedOperationResult<AppResult<HistoryState>> {
            lock.withLock {
                submitAttempts += 1
                intendedClientEventIDs.append(clientEventId)
            }
            if commitPoint == .submit {
                await commitRelease.wait()
            }

            var committedResult: AppResult<HistoryState>?
            let didDispatch = effectGuard.performIfCurrent {
                lock.withLock { submitDispatches += 1 }
                committedResult = submitResult
            }
            guard didDispatch, let committedResult else { return .notDispatched }
            return .dispatched(committedResult)
        }

        func releaseCommit() async {
            await commitRelease.release()
        }
    }

    /// Seam específico para provar que `runCandidateOperation` propaga o cancelamento enquanto
    /// `complete` está suspenso. O fake só chama o repositório depois de revalidar `Task.isCancelled`,
    /// reproduzindo o guard imediatamente anterior ao submit do use-case real.
    private final class GatedPhasedActivities:
        PhasedRunningAutomaticActivities,
        @unchecked Sendable
    {
        private let repository: FakeCheckRepository
        private let now: Date
        private let lock = NSLock()
        private var prepareCalls = 0
        private var completeCalls = 0
        private var submitIntents = 0

        let completeRelease = AsyncGate()

        init(
            repository: FakeCheckRepository,
            now: Date
        ) {
            self.repository = repository
            self.now = now
        }

        var prepareCallCount: Int {
            lock.withLock { prepareCalls }
        }

        var completeCallCount: Int {
            lock.withLock { completeCalls }
        }

        var submitIntentCount: Int {
            lock.withLock { submitIntents }
        }

        func preflight(
            chave: String,
            userProjects: UserProjects?,
            mixedZoneIntervalMinutes: Int
        ) -> AutomaticActivitiesPreflight {
            guard let projeto = userProjects?.activeProject,
                  !projeto.isEmpty else {
                return .terminal(Self.notConfiguredExecution())
            }
            return .ready(
                AutomaticActivitiesConfiguration(
                    chave: chave,
                    projeto: projeto,
                    mixedZoneIntervalMinutes: mixedZoneIntervalMinutes
                )
            )
        }

        func prepare(
            _ configuration: AutomaticActivitiesConfiguration,
            accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> AutomaticActivitiesPreparation {
            lock.withLock { prepareCalls += 1 }
            return .ready(
                PreparedAutomaticActivitiesMatch(
                    configuration: configuration,
                    match: Self.matchedLocation(),
                    capture: nil
                )
            )
        }

        func complete(
            _ prepared: PreparedAutomaticActivitiesMatch,
            currentState: HistoryState?
        ) async -> AutomaticActivitiesExecution {
            lock.withLock { completeCalls += 1 }
            await completeRelease.wait()

            guard !Task.isCancelled else {
                return Self.cancelledExecution()
            }

            lock.withLock { submitIntents += 1 }
            let result = await repository.submit(
                chave: prepared.configuration.chave,
                projeto: prepared.configuration.projeto,
                action: .checkIn,
                local: prepared.match.resolvedLocal,
                informe: .normal,
                eventTime: now,
                clientEventId: "context-race-event",
                fillForms: true
            )
            switch result {
            case .success(let state):
                return AutomaticActivitiesExecution(
                    result: .submitted(
                        action: .checkIn,
                        local: prepared.match.resolvedLocal,
                        newState: state
                    ),
                    trace: AutomaticActivitiesTrace(
                        maximumStage: .submitted,
                        capture: nil,
                        failure: nil,
                        offlineDisposition: nil
                    ),
                    submissionContext: nil
                )
            case .failure(let error):
                return AutomaticActivitiesExecution(
                    result: .networkError,
                    trace: AutomaticActivitiesTrace(
                        maximumStage: .submitStarted,
                        capture: nil,
                        failure: .submit(error),
                        offlineDisposition: nil
                    ),
                    submissionContext: nil
                )
            }
        }

        func execute(
            chave: String,
            userProjects: UserProjects?,
            currentState: HistoryState?,
            mixedZoneIntervalMinutes: Int,
            accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> AutomaticActivitiesExecution {
            switch preflight(
                chave: chave,
                userProjects: userProjects,
                mixedZoneIntervalMinutes: mixedZoneIntervalMinutes
            ) {
            case .terminal(let execution):
                return execution
            case .ready(let configuration):
                switch await prepare(
                    configuration,
                    accuracyThresholdMeters: accuracyThresholdMeters,
                    locationAttempt: locationAttempt
                ) {
                case .terminal(let execution):
                    return execution
                case .ready(let prepared):
                    return await complete(
                        prepared,
                        currentState: currentState
                    )
                }
            }
        }

        func releaseComplete() async {
            await completeRelease.release()
        }

        private static func matchedLocation() -> LocationMatch {
            LocationMatch(
                matched: true,
                resolvedLocal: "Test Location",
                label: "Test Location",
                status: .matched,
                message: "",
                accuracyMeters: 12,
                accuracyThresholdMeters: 50,
                minimumCheckoutDistanceMeters: 2_000,
                nearestWorkplaceDistanceMeters: nil
            )
        }

        private static func notConfiguredExecution()
            -> AutomaticActivitiesExecution
        {
            AutomaticActivitiesExecution(
                result: .notConfigured,
                trace: AutomaticActivitiesTrace(
                    maximumStage: .started,
                    capture: nil,
                    failure: nil,
                    offlineDisposition: nil
                ),
                submissionContext: nil
            )
        }

        private static func cancelledExecution()
            -> AutomaticActivitiesExecution
        {
            AutomaticActivitiesExecution(
                result: .locationTimeout,
                trace: AutomaticActivitiesTrace(
                    maximumStage: .decisionCompleted,
                    capture: nil,
                    failure: .cancelled(.taskCancelled),
                    offlineDisposition: nil
                ),
                submissionContext: nil
            )
        }
    }

    private let now = iso("2026-07-31T10:00:00Z")

    override func setUp() {
        super.setUp()
        EvaluationLog.shared.reset()
    }

    func test_contextInvalidatedWhileMatchIsSuspendedDoesNotQueueRawFetchStateOrSubmit() async {
        let base = configuredRepository(
            matchResult: .failure(.network)
        )
        let repository = GatedCheckRepository(
            base: base,
            suspensionPoint: .match
        )
        let provider = FakeLocationProvider(
            .success(sample())
        )
        let queue = FakeOfflineQueue()
        let journal = RecordingEvaluationJournal()
        let sut = realOrchestrator(
            provider: provider,
            repository: repository,
            queue: queue,
            journal: journal
        )

        let evaluation = Task {
            await sut.runOnce(.timer)
        }
        await waitUntil {
            base.matchLocationCallCount == 1
        }

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(base.matchLocationCallCount, 1)
        XCTAssertEqual(base.getStateCallCount, 0)
        XCTAssertEqual(base.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)

        await sut.invalidateAutomationContext()
        await repository.releaseMatch()
        let completion = await evaluation.value

        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(base.matchLocationCallCount, 1)
        XCTAssertEqual(base.getStateCallCount, 0)
        XCTAssertEqual(base.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
        await assertSingleJournalTerminal(
            journal,
            outcome: .staleContext
        )
    }

    func test_contextInvalidatedWhileStateIsSuspendedDoesNotCompleteOrSubmit() async {
        let base = configuredRepository(
            matchResult: .success(matchedLocation())
        )
        let repository = GatedCheckRepository(
            base: base,
            suspensionPoint: .state
        )
        let provider = FakeLocationProvider(
            .success(sample())
        )
        let queue = FakeOfflineQueue()
        let journal = RecordingEvaluationJournal()
        let sut = realOrchestrator(
            provider: provider,
            repository: repository,
            queue: queue,
            journal: journal
        )

        let evaluation = Task {
            await sut.runOnce(.timer)
        }
        await waitUntil {
            base.getStateCallCount == 1
        }

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(base.matchLocationCallCount, 1)
        XCTAssertEqual(base.getStateCallCount, 1)
        XCTAssertEqual(base.submitCount, 0)

        await sut.invalidateAutomationContext()
        await repository.releaseState()
        let completion = await evaluation.value

        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(base.matchLocationCallCount, 1)
        XCTAssertEqual(base.getStateCallCount, 1)
        XCTAssertEqual(base.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
        await assertSingleJournalTerminal(
            journal,
            outcome: .staleContext
        )
    }

    func test_contextInvalidatedDuringCompleteCancelsBeforeSubmitIntent() async {
        let repository = configuredRepository(
            matchResult: .success(matchedLocation())
        )
        let activities = GatedPhasedActivities(
            repository: repository,
            now: now
        )
        let provider = FakeLocationProvider(
            .success(sample())
        )
        let journal = RecordingEvaluationJournal()
        let sut = makeOrchestrator(
            prefs: preferences(),
            checkRepository: repository,
            autoActivities: activities,
            locationProvider: provider,
            automaticEvaluationPipeline: .candidate,
            clock: FixedClock(now),
            evaluationJournal: journal
        )

        let evaluation = Task {
            await sut.runOnce(.timer)
        }
        await waitUntil {
            activities.completeCallCount == 1
        }

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.getStateCallCount, 1)
        XCTAssertEqual(activities.prepareCallCount, 1)
        XCTAssertEqual(activities.completeCallCount, 1)
        XCTAssertEqual(activities.submitIntentCount, 0)
        XCTAssertEqual(repository.submitCount, 0)

        await sut.invalidateAutomationContext()
        await activities.releaseComplete()
        let completion = await evaluation.value

        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertEqual(activities.completeCallCount, 1)
        XCTAssertEqual(activities.submitIntentCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        await assertSingleJournalTerminal(
            journal,
            outcome: .staleContext
        )
    }

    func test_identityInvalidationWinningMatchCommitPreventsDispatchWithoutRecapture() async {
        await assertInvalidationWinningCommit(
            .match,
            invalidation: .identity
        )
    }

    func test_automationInvalidationWinningMatchCommitPreventsDispatchWithoutRecapture() async {
        await assertInvalidationWinningCommit(
            .match,
            invalidation: .automation
        )
    }

    func test_identityInvalidationWinningSubmitCommitPreventsDispatchWithoutDuplicate() async {
        await assertInvalidationWinningCommit(
            .submit,
            invalidation: .identity
        )
    }

    func test_automationInvalidationWinningSubmitCommitPreventsDispatchWithoutDuplicate() async {
        await assertInvalidationWinningCommit(
            .submit,
            invalidation: .automation
        )
    }

    func test_legacyContextInvalidatedDuringMovementCaptureDoesNotPoisonNextTimerBaseline() async {
        let provider = SuspendedFirstLocationProvider(
            sample: sample()
        )
        let repository = configuredRepository(
            matchResult: .success(
                LocationMatch(
                    matched: false,
                    resolvedLocal: nil,
                    label: "",
                    status: .noKnownLocations,
                    message: "",
                    accuracyMeters: 12,
                    accuracyThresholdMeters: 50,
                    minimumCheckoutDistanceMeters: 2_000,
                    nearestWorkplaceDistanceMeters: nil
                )
            )
        )
        let queue = FakeOfflineQueue()
        let journal = RecordingEvaluationJournal()
        let sut = realOrchestrator(
            provider: provider,
            repository: repository,
            queue: queue,
            journal: journal,
            pipeline: .legacy
        )

        let invalidatedEvaluation = Task {
            await sut.runOnce(.timer)
        }
        await waitUntil {
            await provider.callCount == 1
        }
        let providerCallsWhileSuspended = await provider.callCount
        XCTAssertEqual(providerCallsWhileSuspended, 1)

        await sut.invalidateAutomationContext()
        await provider.releaseFirstCapture()
        let invalidated = await invalidatedEvaluation.value

        XCTAssertEqual(invalidated.outcome, .staleContext)
        let providerCallsAfterInvalidation = await provider.callCount
        XCTAssertEqual(providerCallsAfterInvalidation, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 0)

        let nextContext = await sut.runOnce(.timer)
        let finalProviderCalls = await provider.callCount

        XCTAssertEqual(nextContext.outcome, .noAction)
        XCTAssertEqual(
            finalProviderCalls,
            3,
            "o TIMER novo deve capturar uma vez para movimento e outra no motor legado"
        )
        XCTAssertEqual(
            repository.matchLocationCallCount,
            1,
            "a captura invalidada não pode fazer o primeiro TIMER novo parecer estacionário"
        )

        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.begins.count, 2)
        XCTAssertEqual(snapshot.finishes.count, 2)
        XCTAssertEqual(
            snapshot.finishes.map(\.terminal.outcome),
            [.staleContext, .noAction]
        )
    }

    private func preferences() -> FakeAppPreferences {
        let settings = UserSettings(
            projects: ["P80"],
            activeProject: "P80",
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
        let data = try! JSONCoding.encoder.encode(["HR70": settings])
        let preferences = FakeAppPreferences()
        preferences.chaveValue = "HR70"
        preferences.languageValue = "pt"
        preferences.userSettingsJsonValue = String(
            data: data,
            encoding: .utf8
        )!
        return preferences
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

    private func matchedLocation() -> LocationMatch {
        LocationMatch(
            matched: true,
            resolvedLocal: "Test Location",
            label: "Test Location",
            status: .matched,
            message: "",
            accuracyMeters: 12,
            accuracyThresholdMeters: 50,
            minimumCheckoutDistanceMeters: 2_000,
            nearestWorkplaceDistanceMeters: nil
        )
    }

    private func configuredRepository(
        matchResult: AppResult<LocationMatch>
    ) -> FakeCheckRepository {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(
            LocationOptions(
                items: ["Test Location"],
                accuracyThresholdMeters: 50,
                mixedZoneIntervalMinutes: 15
            )
        )
        repository.matchLocationResult = matchResult
        repository.getStateResult = .success(
            HistoryState(
                found: true,
                chave: "HR70",
                projeto: "P80",
                currentAction: .checkOut,
                currentLocal: nil,
                hasCurrentDayCheckin: false,
                lastCheckinAt: nil,
                lastCheckoutAt: now.addingTimeInterval(-600),
                transportEnabled: false
            )
        )
        repository.submitResult = .success(
            HistoryState(
                found: true,
                chave: "HR70",
                projeto: "P80",
                currentAction: .checkIn,
                currentLocal: "Test Location",
                hasCurrentDayCheckin: true,
                lastCheckinAt: now,
                lastCheckoutAt: nil,
                transportEnabled: false
            )
        )
        return repository
    }

    private enum CommitInvalidation {
        case identity
        case automation
    }

    private func assertInvalidationWinningCommit(
        _ commitPoint: CommitGatedCheckRepository.CommitPoint,
        invalidation: CommitInvalidation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let base = configuredRepository(
            matchResult: .success(matchedLocation())
        )
        let repository = CommitGatedCheckRepository(
            base: base,
            commitPoint: commitPoint,
            matchResult: .success(matchedLocation()),
            submitResult: base.submitResult
        )
        let provider = FakeLocationProvider(.success(sample()))
        let queue = FakeOfflineQueue()
        let journal = RecordingEvaluationJournal()
        let coordinator = OrchestratorAuthSessionCoordinator(
            authRepository: NoopAuthRepository(),
            securePasswordStore: NoopSecurePasswordStore()
        )
        let sut = realOrchestrator(
            provider: provider,
            repository: repository,
            queue: queue,
            journal: journal,
            authSessionCoordinator: coordinator
        )

        let evaluation = Task { await sut.runOnce(.timer) }
        await waitUntil {
            let snapshot = repository.snapshot
            return switch commitPoint {
            case .match:
                snapshot.matchAttempts == 1
            case .submit:
                snapshot.submitAttempts == 1
            }
        }

        let sessionInvalidation: AuthSessionInvalidation?
        switch invalidation {
        case .identity:
            sessionInvalidation = coordinator.invalidateCurrentIdentity()
        case .automation:
            sessionInvalidation = nil
            await sut.invalidateAutomationContext()
        }

        await repository.releaseCommit()
        let completion = await evaluation.value
        if let sessionInvalidation {
            await coordinator.completeInvalidatedTransition(sessionInvalidation)
        }

        let snapshot = repository.snapshot
        XCTAssertEqual(completion.outcome, .staleContext, file: file, line: line)
        XCTAssertEqual(provider.callCount, 1, file: file, line: line)
        XCTAssertEqual(snapshot.matchAttempts, 1, file: file, line: line)
        XCTAssertEqual(snapshot.unguardedMatchCalls, 0, file: file, line: line)
        XCTAssertEqual(snapshot.unguardedSubmitCalls, 0, file: file, line: line)
        XCTAssertTrue(queue.enqueued.isEmpty, file: file, line: line)

        switch commitPoint {
        case .match:
            XCTAssertEqual(snapshot.matchDispatches, 0, file: file, line: line)
            XCTAssertEqual(base.getStateCallCount, 0, file: file, line: line)
            XCTAssertEqual(snapshot.submitAttempts, 0, file: file, line: line)
            XCTAssertEqual(snapshot.submitDispatches, 0, file: file, line: line)
            XCTAssertTrue(snapshot.intendedClientEventIDs.isEmpty, file: file, line: line)
        case .submit:
            XCTAssertEqual(snapshot.matchDispatches, 1, file: file, line: line)
            XCTAssertEqual(base.getStateCallCount, 1, file: file, line: line)
            XCTAssertEqual(snapshot.submitAttempts, 1, file: file, line: line)
            XCTAssertEqual(snapshot.submitDispatches, 0, file: file, line: line)
            XCTAssertEqual(
                snapshot.intendedClientEventIDs,
                ["context-race-event"],
                file: file,
                line: line
            )
        }

        await assertSingleJournalTerminal(
            journal,
            outcome: .staleContext,
            file: file,
            line: line
        )
    }

    private func realOrchestrator(
        provider: any LocationProvider,
        repository: any CheckRepository,
        queue: FakeOfflineQueue,
        journal: RecordingEvaluationJournal,
        pipeline: BackgroundAutomaticEvaluationPipeline = .candidate,
        authSessionCoordinator: (any AuthSessionCoordinating)? = nil
    ) -> BackgroundCheckOrchestrator {
        let clock = FixedClock(now)
        let capture = CaptureLocationUseCase(
            locationProvider: provider,
            checkRepository: repository,
            activityLogger: NoopActivityLogger(),
            clock: clock,
            samplePolicy: .candidateTrial,
            captureBehavior:
                pipeline == .legacy
                    ? .legacyCompatible
                    : .freshnessValidated
        )
        let activities = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: clock,
            activityLogger: NoopActivityLogger(),
            makeClientEventID: { "context-race-event" }
        )
        return makeOrchestrator(
            prefs: preferences(),
            checkRepository: repository,
            autoActivities: activities,
            locationProvider: provider,
            automaticEvaluationPipeline: pipeline,
            clock: clock,
            authSessionCoordinator: authSessionCoordinator,
            evaluationJournal: journal
        )
    }

    private func assertSingleJournalTerminal(
        _ journal: RecordingEvaluationJournal,
        outcome: EvaluationTerminalOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let snapshot = await journal.snapshot()
        XCTAssertEqual(
            snapshot.begins.count,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            snapshot.finishes.count,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            snapshot.finishes.first?.terminal.outcome,
            outcome,
            file: file,
            line: line
        )
    }
}
