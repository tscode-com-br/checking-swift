import Foundation
import XCTest
@testable import Checking

/// Cenários de fronteira entre os componentes candidatos. Estes testes não habilitam o perfil candidato
/// em nenhum build: todos os perfis são injetados diretamente e a configuração instalável continua legada.
final class BackgroundReliabilityIntegrationTests: XCTestCase {
    private let now = iso("2026-08-04T08:00:00Z")

    private final class MatchSuspendingRepository: CheckRepository, @unchecked Sendable {
        let base: FakeCheckRepository
        private let matchStarted = AsyncGate()
        private let releaseMatch = AsyncGate()

        init(base: FakeCheckRepository) {
            self.base = base
        }

        func matchLocation(
            _ lat: Double,
            _ lon: Double,
            _ accuracyMeters: Double?
        ) async -> AppResult<LocationMatch> {
            let result = await base.matchLocation(lat, lon, accuracyMeters)
            await matchStarted.release()
            await releaseMatch.wait()
            return result
        }

        func getState(_ chave: String) async -> AppResult<HistoryState> {
            await base.getState(chave)
        }

        func getHistory(_ chave: String) async -> AppResult<[CheckHistoryEntry]> {
            await base.getHistory(chave)
        }

        func getLocations() async -> AppResult<LocationOptions> {
            await base.getLocations()
        }

        func getGeofences(_ chave: String) async -> AppResult<[GeofenceCircle]> {
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

        func waitForMatch() async {
            await matchStarted.wait()
        }

        func resumeMatch() async {
            await releaseMatch.release()
        }
    }

    private actor BlockingAutomaticActivities: PhasedRunningAutomaticActivities {
        private let firstExecutionStarted = AsyncGate()
        private let releaseFirstExecution = AsyncGate()
        private var calls = 0

        func execute(
            chave: String,
            userProjects: UserProjects?,
            currentState: HistoryState?,
            mixedZoneIntervalMinutes: Int,
            accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> AutomaticActivitiesExecution {
            calls += 1
            if calls == 1 {
                await firstExecutionStarted.release()
                await releaseFirstExecution.wait()
            }
            return Self.noActionExecution()
        }

        nonisolated func preflight(
            chave: String,
            userProjects: UserProjects?,
            mixedZoneIntervalMinutes: Int
        ) -> AutomaticActivitiesPreflight {
            guard let projeto = userProjects?.activeProject, !projeto.isEmpty else {
                return .terminal(Self.noActionExecution())
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
            .ready(
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
            calls += 1
            if calls == 1 {
                await firstExecutionStarted.release()
                await releaseFirstExecution.wait()
            }
            return Self.noActionExecution()
        }

        func waitForFirstExecution() async {
            await firstExecutionStarted.wait()
        }

        func resumeFirstExecution() async {
            await releaseFirstExecution.release()
        }

        func callCount() -> Int {
            calls
        }

        private static func noActionExecution() -> AutomaticActivitiesExecution {
            AutomaticActivitiesExecution(
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
    }

    private actor CountingAutomaticActivities: RunningAutomaticActivities {
        private var calls = 0

        func execute(
            chave: String,
            userProjects: UserProjects?,
            currentState: HistoryState?,
            mixedZoneIntervalMinutes: Int,
            accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> AutomaticActivitiesExecution {
            calls += 1
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

        func callCount() -> Int {
            calls
        }
    }

    @MainActor
    private final class PreciseSeedDriver: LocationUpdateDriving {
        var authorization: LocationUpdateAuthorization = .allowed
        private(set) var startCount = 0
        private(set) var stopCount = 0

        func start(
            onLocations: @escaping @MainActor @Sendable ([LocationSample]) -> Void,
            onFailure: @escaping @MainActor @Sendable (LocationUpdateFailure) -> Void
        ) {
            startCount += 1
        }

        func stop() {
            stopCount += 1
        }
    }

    @MainActor
    private final class PreciseSeedDriverFactory {
        let driver: PreciseSeedDriver
        private(set) var makeCount = 0

        init(driver: PreciseSeedDriver) {
            self.driver = driver
        }

        func make() -> any LocationUpdateDriving {
            makeCount += 1
            return driver
        }
    }

    @MainActor
    private final class NeverTimeoutScheduler: CaptureTimeoutScheduling {
        private(set) var scheduleCount = 0

        func schedule(
            after delay: TimeInterval,
            operation: @escaping @MainActor @Sendable () -> Void
        ) -> any CaptureTimeoutCancellable {
            scheduleCount += 1
            return NeverTimeoutToken()
        }
    }

    @MainActor
    private final class NeverTimeoutToken: CaptureTimeoutCancellable {
        func cancel() {}
    }

    func test_candidateTimerRunsOneSampleThroughMatchStateDecisionSubmitAndTerminal() async {
        let sample = makeSample()
        let provider = FakeLocationProvider(.success(sample))
        let repository = configuredRepository(
            matchResult: .success(makeMatch(status: .matched, local: "Unidade P80")),
            state: makeHistory(.checkOut),
            submit: makeHistory(.checkIn, local: "Unidade P80")
        )
        let journal = RecordingEvaluationJournal()
        let queue = FakeOfflineQueue()
        let orchestrator = makePipelineOrchestrator(
            provider: provider,
            repository: repository,
            queue: queue,
            journal: journal,
            pipeline: .candidate,
            clientEventID: "integration-timer-event"
        )

        let completion = await orchestrator.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .submittedCheckIn)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(
            repository.lastMatchLocationCall,
            .init(
                latitude: sample.latitude,
                longitude: sample.longitude,
                accuracyMeters: sample.horizontalAccuracyMeters
            )
        )
        XCTAssertEqual(repository.getStateCallCount, 1)
        XCTAssertEqual(repository.submitCount, 1)
        XCTAssertEqual(repository.submitCalls.first?.clientEventId, "integration-timer-event")
        XCTAssertEqual(repository.submitCalls.first?.eventTime, now)
        XCTAssertTrue(queue.enqueued.isEmpty)

        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.begins.count, 1)
        XCTAssertEqual(snapshot.finishes.count, 1)
        XCTAssertEqual(snapshot.finishes.first?.id, completion.evaluationID)
        XCTAssertEqual(snapshot.finishes.first?.terminal.outcome, .submittedCheckIn)
        XCTAssertEqual(snapshot.finishes.first?.terminal.stage, .submit)
    }

    @MainActor
    func test_candidatePreciseSignificantSeedUsesNoStandardDriverAndReachesTerminal() async {
        let seed = makeSample(source: .significantChange, accuracy: 8)
        let driver = PreciseSeedDriver()
        let driverFactory = PreciseSeedDriverFactory(driver: driver)
        let timeoutScheduler = NeverTimeoutScheduler()
        let provider = CLLocationManagerLocationProvider(
            behavior: .freshnessValidated,
            samplePolicy: .candidateTrial,
            now: { [now] in now },
            makeDriver: { driverFactory.make() },
            makeTimeoutScheduler: { timeoutScheduler }
        )
        let repository = configuredRepository(
            matchResult: .success(makeMatch(status: .noKnownLocations)),
            state: makeHistory(.checkOut),
            submit: makeHistory(.checkIn)
        )
        let journal = RecordingEvaluationJournal()
        let orchestrator = makePipelineOrchestrator(
            provider: provider,
            repository: repository,
            queue: FakeOfflineQueue(),
            journal: journal,
            pipeline: .candidate,
            clientEventID: "integration-significant-event"
        )

        let completion = await orchestrator.runOnce(
            .significantLocation,
            seedCandidate: seed
        )

        XCTAssertEqual(completion.outcome, .noAction)
        XCTAssertEqual(driverFactory.makeCount, 0)
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(driver.stopCount, 0)
        XCTAssertEqual(timeoutScheduler.scheduleCount, 0)
        XCTAssertEqual(
            repository.lastMatchLocationCall,
            .init(
                latitude: seed.latitude,
                longitude: seed.longitude,
                accuracyMeters: seed.horizontalAccuracyMeters
            )
        )
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.finishes.first?.terminal.outcome, .noAction)
        XCTAssertEqual(snapshot.finishes.first?.terminal.locationSource, .seed)
        XCTAssertEqual(snapshot.finishes.first?.terminal.captureReused, true)
    }

    func test_sharedContextInvalidationStopsSuspendedCandidateBeforeStateOrSubmit() async {
        enum ContextChange: CaseIterable {
            case account
            case automaticToggle
            case project
            case consent
        }

        for change in ContextChange.allCases {
            let base = configuredRepository(
                matchResult: .success(makeMatch(status: .matched, local: "Unidade P80")),
                state: makeHistory(.checkOut),
                submit: makeHistory(.checkIn, local: "Unidade P80")
            )
            let repository = MatchSuspendingRepository(base: base)
            let provider = FakeLocationProvider(.success(makeSample()))
            let queue = FakeOfflineQueue()
            let journal = RecordingEvaluationJournal()
            let orchestrator = makePipelineOrchestrator(
                provider: provider,
                repository: repository,
                queue: queue,
                journal: journal,
                pipeline: .candidate,
                clientEventID: "integration-context-\(change)"
            )

            let evaluation = Task {
                await orchestrator.runOnce(.timer)
            }
            await repository.waitForMatch()

            // Conta, toggle, projeto e consentimento convergem para a mesma fence atômica do
            // orquestrador. O wiring de cada origem é coberto nos testes de ViewModel; aqui a prova é
            // a semântica compartilhada: nenhum deles pode deixar o trabalho suspenso avançar depois
            // do await de match.
            let transition = await orchestrator.beginAutomationContextTransition()
            await repository.resumeMatch()
            await orchestrator.awaitAutomationQuiescence(transition)
            await orchestrator.endAutomationContextTransition(transition)
            let completion = await evaluation.value

            XCTAssertEqual(completion.outcome, .staleContext, "\(change)")
            XCTAssertEqual(provider.callCount, 1, "\(change)")
            XCTAssertEqual(base.matchLocationCallCount, 1, "\(change)")
            XCTAssertEqual(base.getStateCallCount, 0, "\(change)")
            XCTAssertEqual(base.submitCount, 0, "\(change)")
            XCTAssertTrue(queue.enqueued.isEmpty, "\(change)")
            let snapshot = await journal.snapshot()
            XCTAssertEqual(snapshot.finishes.map(\.terminal.outcome), [.staleContext], "\(change)")
        }
    }

    func test_legacyRollbackKeepsOfflineQueueAndClearsCandidateJournalWithoutResumingPending() async throws {
        let temporary = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temporary.root) }

        let journal = DurableEvaluationJournal(
            fileURL: temporary.file,
            clock: FixedClock(now),
            processID: EvaluationProcessID()
        )
        let queueStore = InMemoryOfflineQueueStore()
        let queue = OfflineCheckQueue(store: queueStore, scheduler: NoopSyncScheduler())
        let candidateRepository = configuredRepository(
            matchResult: .failure(.network),
            state: makeHistory(.checkOut),
            submit: makeHistory(.checkIn)
        )
        let candidate = makePipelineOrchestrator(
            provider: FakeLocationProvider(.success(makeSample())),
            repository: candidateRepository,
            queue: queue,
            journal: journal,
            pipeline: .candidate,
            clientEventID: "candidate-rollback-event"
        )

        let candidateCompletion = await candidate.runOnce(.timer)
        XCTAssertEqual(candidateCompletion.outcome, .queuedOfflineRaw)
        let queuedBeforeRollback = await queue.peekAll()
        XCTAssertEqual(queuedBeforeRollback.count, 1)

        let blockingActivities = BlockingAutomaticActivities()
        let candidateWithPending = makeOrchestrator(
            prefs: activePreferences(),
            checkRepository: configuredRepository(),
            autoActivities: blockingActivities,
            locationProvider: FakeLocationProvider(.success(makeSample())),
            automaticEvaluationPipeline: .candidate,
            clock: FixedClock(now),
            evaluationJournal: journal
        )
        let runningTicket = await candidateWithPending.evaluationTicket(.timer)
        await blockingActivities.waitForFirstExecution()
        let pendingTicket = await candidateWithPending.evaluationTicket(.geofence)
        XCTAssertEqual(pendingTicket.admission, .deferred)

        let transition = await candidateWithPending.beginAutomationContextTransition()
        await blockingActivities.resumeFirstExecution()
        await candidateWithPending.awaitAutomationQuiescence(transition)
        await candidateWithPending.endAutomationContextTransition(transition)
        _ = await runningTicket.completion()
        let pendingCompletion = await pendingTicket.completion()
        XCTAssertEqual(pendingCompletion.outcome, .staleContext)
        let blockingCallCount = await blockingActivities.callCount()
        XCTAssertEqual(blockingCallCount, 1)

        try addUnknownCandidateDiagnosticField(to: temporary.file)
        let legacyJournal = DurableEvaluationJournal(
            fileURL: temporary.file,
            clock: FixedClock(now),
            processID: EvaluationProcessID()
        )
        let recordsBeforeLegacy = await legacyJournal.recent(limit: 10)
        XCTAssertFalse(recordsBeforeLegacy.isEmpty)
        XCTAssertTrue(recordsBeforeLegacy.contains {
            $0.evaluationID == candidateCompletion.evaluationID
                && $0.terminal == .queuedOfflineRaw
        })

        let legacyActivities = CountingAutomaticActivities()
        let legacy = makeOrchestrator(
            prefs: activePreferences(),
            checkRepository: configuredRepository(),
            autoActivities: legacyActivities,
            locationProvider: FakeLocationProvider(.unavailable),
            automaticEvaluationPipeline: .legacy,
            clock: FixedClock(now),
            evaluationJournal: legacyJournal
        )
        let legacyCompletion = await legacy.runOnce(.timer)
        XCTAssertEqual(legacyCompletion.outcome, .noAction)
        let legacyCallCount = await legacyActivities.callCount()
        let queueBeforeJournalClear = await queue.peekAll()
        XCTAssertEqual(legacyCallCount, 1)
        XCTAssertEqual(queueBeforeJournalClear, queuedBeforeRollback)

        await legacyJournal.clear()
        let recordsAfterClear = await legacyJournal.recent(limit: 10)
        XCTAssertTrue(recordsAfterClear.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.file.path))
        let queueAfterJournalClear = await queue.peekAll()
        XCTAssertEqual(queueAfterJournalClear, queuedBeforeRollback)
    }

    private func activePreferences() -> FakeAppPreferences {
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
        let encoded = try! JSONCoding.encoder.encode(["HR70": settings])
        let preferences = FakeAppPreferences()
        preferences.chaveValue = "HR70"
        preferences.languageValue = "pt"
        preferences.userSettingsJsonValue = String(decoding: encoded, as: UTF8.self)
        return preferences
    }

    private func configuredRepository(
        matchResult: AppResult<LocationMatch>? = nil,
        state: HistoryState? = nil,
        submit: HistoryState? = nil
    ) -> FakeCheckRepository {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(LocationOptions(
            items: ["Unidade P80"],
            accuracyThresholdMeters: 50,
            mixedZoneIntervalMinutes: 15
        ))
        repository.matchLocationResult = matchResult
            ?? .success(makeMatch(status: .noKnownLocations))
        repository.getStateResult = .success(state ?? makeHistory(.checkOut))
        repository.submitResult = .success(submit ?? makeHistory(.checkIn))
        return repository
    }

    private func makePipelineOrchestrator(
        provider: any LocationProvider,
        repository: any CheckRepository,
        queue: any OfflineCheckQueueing,
        journal: any EvaluationJournaling,
        pipeline: BackgroundAutomaticEvaluationPipeline,
        clientEventID: String
    ) -> BackgroundCheckOrchestrator {
        let behavior: LocationCaptureBehavior = pipeline == .candidate
            ? .freshnessValidated
            : .legacyCompatible
        let capture = CaptureLocationUseCase(
            locationProvider: provider,
            checkRepository: repository,
            activityLogger: NoopActivityLogger(),
            clock: FixedClock(now),
            samplePolicy: .candidateTrial,
            captureBehavior: behavior
        )
        let automatic = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: FixedClock(now),
            activityLogger: NoopActivityLogger(),
            makeClientEventID: { clientEventID }
        )
        return makeOrchestrator(
            prefs: activePreferences(),
            checkRepository: repository,
            autoActivities: automatic,
            locationProvider: provider,
            automaticEvaluationPipeline: pipeline,
            clock: FixedClock(now),
            evaluationJournal: journal
        )
    }

    private func makeSample(
        source: LocationSampleSource = .standardCapture,
        accuracy: Double = 12
    ) -> LocationSample {
        LocationSample(
            latitude: 1.3,
            longitude: 103.8,
            horizontalAccuracyMeters: accuracy,
            capturedAt: now,
            source: source
        )
    }

    private func makeMatch(
        status: MatchStatus,
        local: String? = nil
    ) -> LocationMatch {
        LocationMatch(
            matched: status == .matched,
            resolvedLocal: local,
            label: local ?? "",
            status: status,
            message: "",
            accuracyMeters: 12,
            accuracyThresholdMeters: 50,
            minimumCheckoutDistanceMeters: 2_000,
            nearestWorkplaceDistanceMeters: nil
        )
    }

    private func makeHistory(
        _ action: CheckAction,
        local: String? = nil
    ) -> HistoryState {
        HistoryState(
            found: true,
            chave: "HR70",
            projeto: "P80",
            currentAction: action,
            currentLocal: local,
            hasCurrentDayCheckin: action == .checkIn,
            lastCheckinAt: action == .checkIn ? now.addingTimeInterval(-600) : nil,
            lastCheckoutAt: action == .checkOut ? now.addingTimeInterval(-600) : nil,
            transportEnabled: false
        )
    }

    private func makeTemporaryJournal() throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-reliability-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, root.appendingPathComponent("journal.json"))
    }

    private func addUnknownCandidateDiagnosticField(to file: URL) throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        object["candidate_diagnostic_vnext"] = ["ignored": true]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try data.write(to: file, options: .atomic)
    }
}
