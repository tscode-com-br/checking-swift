import Foundation
import XCTest
@testable import Checking

/// Provas end-to-end do orçamento de aquisição do TIMER candidato.
///
/// Estes testes usam o provider fake compartilhado, mas atravessam os casos de uso reais de captura e
/// atividades automáticas. Assim, contagens de provider/matcher/fila protegem o seam completo, não apenas
/// uma implementação fake do motor.
final class TimerSingleCaptureTests: XCTestCase {
    private final class ArmableSessionInvalidatingClock: Clock, @unchecked Sendable {
        private let lock = NSLock()
        private let value: Date
        private var invalidation: (@Sendable () -> Void)?

        init(_ value: Date) {
            self.value = value
        }

        func now() -> Date {
            let callback = lock.withLock { () -> (@Sendable () -> Void)? in
                defer { invalidation = nil }
                return invalidation
            }
            callback?()
            return value
        }

        func invalidateOnNextRead(_ callback: @escaping @Sendable () -> Void) {
            lock.withLock { invalidation = callback }
        }
    }

    private final class ArmableClock: Clock, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        private var advanceAfterNextRead: TimeInterval?

        init(_ value: Date) {
            self.value = value
        }

        func now() -> Date {
            lock.withLock {
                let result = value
                if let interval = advanceAfterNextRead {
                    value = value.addingTimeInterval(interval)
                    advanceAfterNextRead = nil
                }
                return result
            }
        }

        func armAdvanceAfterNextRead(by interval: TimeInterval) {
            lock.withLock {
                advanceAfterNextRead = interval
            }
        }

        func advance(by interval: TimeInterval) {
            lock.withLock {
                value = value.addingTimeInterval(interval)
            }
        }
    }

    private struct ClockAdvancingPasswordStore: SecurePasswordReading {
        let clock: ArmableClock
        let interval: TimeInterval

        func getPassword(_ chave: String) -> String {
            clock.advance(by: interval)
            return "password-sentinel"
        }
    }

    /// Arma o clock quando a captura termina. O primeiro `now()` posterior (gate de movimento) ainda vê o
    /// instante original; o chokepoint `finalSample` já vê a amostra envelhecida.
    private struct ClockArmingLocationProvider: LocationProvider {
        let base: FakeLocationProvider
        let clock: ArmableClock
        let advanceBy: TimeInterval

        func capture(
            _ accuracyThresholdMeters: Int,
            seed: LocationSample?
        ) async -> LocationCapture {
            let result = await base.capture(
                accuracyThresholdMeters,
                seed: seed
            )
            clock.armAdvanceAfterNextRead(by: advanceBy)
            return result
        }
    }

    private actor SuspendedFirstLocationProvider: LocationProvider {
        private let firstCaptureStarted = AsyncGate()
        private let firstCaptureGate = AsyncGate()
        private let sample: LocationSample
        private(set) var callCount = 0

        init(sample: LocationSample) {
            self.sample = sample
        }

        func capture(
            _ accuracyThresholdMeters: Int,
            seed: LocationSample?
        ) async -> LocationCapture {
            callCount += 1
            if callCount == 1 {
                await firstCaptureStarted.release()
                await firstCaptureGate.wait()
            }
            return .success(sample)
        }

        func waitUntilFirstCaptureStarts() async {
            await firstCaptureStarted.wait()
        }

        func releaseFirstCapture() async {
            await firstCaptureGate.release()
        }
    }

    private final class StateGatedRepository: CheckRepository, @unchecked Sendable {
        let base: FakeCheckRepository
        let stateStarted = AsyncGate()
        let stateRelease = AsyncGate()

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
            await stateStarted.release()
            await stateRelease.wait()
            return await base.getState(chave)
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

        func releaseState() async {
            await stateRelease.release()
        }
    }

    private final class StateResultHookRepository: CheckRepository, @unchecked Sendable {
        let base: FakeCheckRepository
        private let afterState: @Sendable () -> Void

        init(base: FakeCheckRepository, afterState: @escaping @Sendable () -> Void) {
            self.base = base
            self.afterState = afterState
        }

        func matchLocation(
            _ lat: Double,
            _ lon: Double,
            _ accuracyMeters: Double?
        ) async -> AppResult<LocationMatch> {
            await base.matchLocation(lat, lon, accuracyMeters)
        }

        func getState(_ chave: String) async -> AppResult<HistoryState> {
            let result = await base.getState(chave)
            afterState()
            return result
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
    }

    private let now = iso("2026-07-31T08:00:00Z")

    override func setUp() {
        super.setUp()
        EvaluationLog.shared.reset()
    }

    private func preferences(activeProject: String = "P80") -> FakeAppPreferences {
        let settings = UserSettings(
            projects: activeProject.isEmpty ? [] : [activeProject],
            activeProject: activeProject,
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
        preferences.userSettingsJsonValue = String(data: data, encoding: .utf8)!
        return preferences
    }

    private func sample(
        latitude: Double = 1.3,
        longitude: Double = 103.8,
        accuracyMeters: Double = 12,
        capturedAt: Date? = nil,
        source: LocationSampleSource = .standardCapture
    ) -> LocationSample {
        LocationSample(
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracyMeters: accuracyMeters,
            capturedAt: capturedAt ?? now,
            source: source
        )
    }

    private func match(
        _ status: MatchStatus,
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
            lastCheckinAt: action == .checkIn ? now.addingTimeInterval(-600) : nil,
            lastCheckoutAt: action == .checkOut ? now.addingTimeInterval(-600) : nil,
            transportEnabled: false
        )
    }

    private func successfulAuthRepository() -> SpyAuthRepository {
        let auth = SpyAuthRepository()
        auth.result = .success(AuthStatus(
            found: true,
            chave: "HR70",
            hasPassword: true,
            authenticated: true,
            message: "ok"
        ))
        return auth
    }

    private func repository(
        matchResult: AppResult<LocationMatch>? = nil
    ) -> FakeCheckRepository {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(
            LocationOptions(
                items: ["Unidade P80"],
                accuracyThresholdMeters: 50,
                mixedZoneIntervalMinutes: 15
            )
        )
        repository.matchLocationResult =
            matchResult ?? .success(match(.noKnownLocations))
        repository.getStateResult = .success(history(.checkOut))
        repository.submitResult = .success(
            history(.checkIn, local: "Unidade P80")
        )
        return repository
    }

    private func orchestrator(
        provider: any LocationProvider,
        repository: any CheckRepository,
        preferences: FakeAppPreferences? = nil,
        queue: FakeOfflineQueue = FakeOfflineQueue(),
        journal: any EvaluationJournaling = NoopEvaluationJournal(),
        clock: any Clock,
        pipeline: BackgroundAutomaticEvaluationPipeline = .candidate,
        clientEventID: String = "timer-event-id",
        authRepository: any AuthRepositoring = NoopAuthRepository(),
        securePasswordStore: any SecurePasswordReading = NoopSecurePasswordStore(),
        authSessionCoordinator: (any AuthSessionCoordinating)? = nil,
        accuracyRetrySleeper: any Sleeping = TaskSleeper(),
        appRefreshScheduler: any AppRefreshScheduling = NoopAppRefreshScheduler()
    ) -> BackgroundCheckOrchestrator {
        let captureBehavior: LocationCaptureBehavior =
            pipeline == .legacy ? .legacyCompatible : .freshnessValidated
        let capture = CaptureLocationUseCase(
            locationProvider: provider,
            checkRepository: repository,
            activityLogger: NoopActivityLogger(),
            clock: clock,
            samplePolicy: .candidateTrial,
            captureBehavior: captureBehavior
        )
        let automatic = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: clock,
            activityLogger: NoopActivityLogger(),
            makeClientEventID: { clientEventID }
        )
        return makeOrchestrator(
            prefs: preferences ?? self.preferences(),
            checkRepository: repository,
            autoActivities: automatic,
            locationProvider: provider,
            automaticEvaluationPipeline: pipeline,
            clock: clock,
            authRepository: authRepository,
            securePasswordStore: securePasswordStore,
            authSessionCoordinator: authSessionCoordinator,
            accuracyRetrySleeper: accuracyRetrySleeper,
            appRefreshScheduler: appRefreshScheduler,
            evaluationJournal: journal
        )
    }

    func test_candidateFirstTimerUsesOnePhysicalCaptureAndOneMatchWithSanitizedJournalTrace() async {
        let clock = FixedClock(now)
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository()
        let journal = RecordingEvaluationJournal()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            journal: journal,
            clock: clock
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .noAction)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.getStateCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)

        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.begins.count, 1)
        XCTAssertEqual(snapshot.finishes.count, 1)
        let terminal = try! XCTUnwrap(snapshot.finishes.first?.terminal)
        XCTAssertEqual(terminal.outcome, .noAction)
        XCTAssertEqual(terminal.stage, .decision)
        XCTAssertEqual(terminal.locationSource, .freshCapture)
        XCTAssertEqual(terminal.captureReused, true)
        XCTAssertEqual(terminal.accuracyBucket, .elevenTo25Meters)
        XCTAssertEqual(terminal.ageBucket, .under1Second)
    }

    func test_candidateStationaryTimerSkipsAndMovedTimerUsesOneAdditionalCaptureAndMatch() async {
        let clock = FixedClock(now)
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            clock: clock
        )

        let first = await sut.runOnce(.timer)
        let stationary = await sut.runOnce(.timer)

        XCTAssertEqual(first.outcome, .noAction)
        XCTAssertEqual(stationary.outcome, .skippedNoMovement)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(repository.matchLocationCallCount, 1)

        provider.result = .success(
            sample(latitude: 1.301, longitude: 103.8)
        )
        let moved = await sut.runOnce(.timer)

        XCTAssertEqual(moved.outcome, .noAction)
        XCTAssertEqual(provider.callCount, 3)
        XCTAssertEqual(repository.matchLocationCallCount, 2)
    }

    func test_candidateCoarseCaptureNeverPoisonsMovementBaseline() async {
        let clock = FixedClock(now)
        let provider = FakeLocationProvider(
            .success(sample(accuracyMeters: 500))
        )
        let repository = repository()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            clock: clock
        )

        let coarse = await sut.runOnce(.timer)
        provider.result = .success(sample(accuracyMeters: 5))
        let firstPrecise = await sut.runOnce(.timer)
        let stationaryPrecise = await sut.runOnce(.timer)

        XCTAssertEqual(coarse.outcome, .noAction)
        XCTAssertEqual(firstPrecise.outcome, .noAction)
        XCTAssertEqual(stationaryPrecise.outcome, .skippedNoMovement)
        XCTAssertEqual(provider.callCount, 3)
        XCTAssertEqual(repository.matchLocationCallCount, 2)
    }

    func test_candidateAcquisitionFailuresUseOneProviderCallAndNeverMatch() async {
        let cases: [
            (
                name: String,
                failure: LocationAcquisitionFailure,
                outcome: EvaluationTerminalOutcome
            )
        ] = [
            ("timeout", .timeout, .locationTimeout),
            ("unavailable", .unavailable, .unavailable),
            ("permission", .permissionDenied, .permissionDenied),
            ("cancelled", .cancelled(.taskCancelled), .cancelled),
        ]

        for testCase in cases {
            let provider = FakeLocationProvider(
                .failure(testCase.failure)
            )
            let repository = repository()
            let journal = RecordingEvaluationJournal()
            let sut = orchestrator(
                provider: provider,
                repository: repository,
                journal: journal,
                clock: FixedClock(now)
            )

            let completion = await sut.runOnce(.timer)

            XCTAssertEqual(completion.outcome, testCase.outcome, testCase.name)
            XCTAssertEqual(provider.callCount, 1, testCase.name)
            XCTAssertEqual(
                repository.matchLocationCallCount,
                0,
                testCase.name
            )
            XCTAssertEqual(repository.getStateCallCount, 0, testCase.name)
            XCTAssertEqual(repository.submitCount, 0, testCase.name)
            let snapshot = await journal.snapshot()
            XCTAssertEqual(
                snapshot.finishes.first?.terminal.stage,
                .acquisition,
                testCase.name
            )
        }
    }

    func test_candidateRevalidatesFinalSampleAndDoesNotMatchWhenItBecomesStale() async {
        let clock = ArmableClock(now)
        let base = FakeLocationProvider(.success(sample()))
        let provider = ClockArmingLocationProvider(
            base: base,
            clock: clock,
            advanceBy: LocationSamplePolicy.candidateTrial.maximumAge + 0.001
        )
        let repository = repository()
        let journal = RecordingEvaluationJournal()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            journal: journal,
            clock: clock
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertEqual(base.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.getStateCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        let snapshot = await journal.snapshot()
        let terminal = try! XCTUnwrap(snapshot.finishes.first?.terminal)
        XCTAssertEqual(terminal.stage, .acquisition)
        XCTAssertEqual(terminal.captureReused, true)
        XCTAssertEqual(terminal.ageBucket, .sixTo15Seconds)
    }

    func test_candidateMatchNetworkQueuesExactlyOneRawWithoutFetchingState() async {
        let clock = FixedClock(now)
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository(matchResult: .failure(.network))
        let queue = FakeOfflineQueue()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            queue: queue,
            clock: clock,
            clientEventID: "raw-event-id"
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .queuedOfflineRaw)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.getStateCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertEqual(queue.enqueued.count, 1)
        guard case .raw(let raw) = queue.enqueued.first else {
            return XCTFail("expected one Raw event")
        }
        XCTAssertEqual(raw.chave, "HR70")
        XCTAssertEqual(raw.projeto, "P80")
        XCTAssertEqual(raw.clientEventId, "raw-event-id")
        XCTAssertEqual(raw.latitude, 1.3)
        XCTAssertEqual(raw.longitude, 103.8)
        XCTAssertEqual(raw.accuracyMeters, 12)
        XCTAssertEqual(
            raw.capturedAtEpochMs,
            Int64((now.timeIntervalSince1970 * 1_000).rounded())
        )
    }

    func test_candidateSubmitNetworkQueuesExactlyOneDecidedEvent() async {
        let clock = FixedClock(now)
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository(
            matchResult: .success(match(.matched, local: "Unidade P80"))
        )
        repository.getStateResult = .success(history(.checkOut))
        repository.submitResult = .failure(.network)
        let queue = FakeOfflineQueue()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            queue: queue,
            clock: clock,
            clientEventID: "decided-event-id"
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .queuedOfflineDecided)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.getStateCallCount, 1)
        XCTAssertEqual(repository.submitCount, 1)
        XCTAssertEqual(repository.submitCalls.first?.eventTime, now)
        XCTAssertEqual(
            repository.submitCalls.first?.clientEventId,
            "decided-event-id"
        )
        XCTAssertEqual(queue.enqueued.count, 1)
        guard case .decided(let decided) = queue.enqueued.first else {
            return XCTFail("expected one Decided event")
        }
        XCTAssertEqual(decided.chave, "HR70")
        XCTAssertEqual(decided.projeto, "P80")
        XCTAssertEqual(decided.clientEventId, "decided-event-id")
        XCTAssertEqual(decided.action, "checkin")
        XCTAssertEqual(decided.local, "Unidade P80")
        XCTAssertEqual(decided.informe, "normal")
    }

    func test_candidateTimerDuringAccuracyRetryEpisodeBypassesSkipAndStateRetryDoesNotRecapture() async {
        let clock = ArmableClock(now)
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository()
        let sleeper = ControlledAccuracyRetrySleeper()
        let scheduler = SpyAppRefreshScheduler()
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
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            clock: clock,
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            ),
            accuracyRetrySleeper: sleeper,
            appRefreshScheduler: scheduler
        )

        // Consolida um baseline de movimento.
        let baseline = await sut.runOnce(.timer)
        XCTAssertEqual(baseline.outcome, .noAction)

        // Abre um episódio real de baixa precisão sem alterar o baseline do TIMER.
        repository.matchLocationResult = .success(
            match(.accuracyTooLow, local: "Unidade P80")
        )
        let lowAccuracy = await sut.runOnce(.foreground)
        XCTAssertEqual(lowAccuracy.outcome, .accuracyTooLow)
        let episodeStarted = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertTrue(episodeStarted)

        let providersBeforeTimer = provider.callCount
        let matchesBeforeTimer = repository.matchLocationCallCount

        // Expira o cache e provoca unauthorized em state depois de captura/match. O retry tipado repete
        // somente state, sem consumir outro orçamento de localização nem repetir o matcher.
        clock.advance(
            by: BackgroundCheckOrchestrator.locationOptionsTTL + 1
        )
        provider.result = .success(
            sample(capturedAt: clock.now())
        )
        repository.queuedGetStateResults = [
            .failure(.unauthorized),
            .success(history(.checkOut)),
        ]
        repository.matchLocationResult = .success(
            match(.matched, local: "Unidade P80")
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .submittedCheckIn)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(
            provider.callCount - providersBeforeTimer,
            1,
            "o episódio ativo deve pular o gate de movimento e consumir somente a captura do motor"
        )
        XCTAssertEqual(
            repository.matchLocationCallCount - matchesBeforeTimer,
            1,
            "o retry de state deve reutilizar o match preparado, sem recapturar ou rematch"
        )
        XCTAssertEqual(
            repository.submitCount,
            1,
            "o retry de state não pode duplicar submit"
        )
        let episodeFinished = await sut.hasAccuracyRetryEpisodeForTest
        XCTAssertFalse(episodeFinished)
    }

    func test_candidateContextInvalidationDuringSuspendedCaptureDoesNotCommitBaselineAndKeepsSanitizedTrace() async {
        let coordinateLatitude = 12.345678
        let coordinateLongitude = 98.765432
        let capturedSample = sample(
            latitude: coordinateLatitude,
            longitude: coordinateLongitude
        )
        let provider = SuspendedFirstLocationProvider(
            sample: capturedSample
        )
        let repository = repository()
        let journal = RecordingEvaluationJournal()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            journal: journal,
            clock: FixedClock(now)
        )

        let invalidatedEvaluation = Task {
            await sut.runOnce(.timer)
        }
        await provider.waitUntilFirstCaptureStarts()

        await sut.invalidateAutomationContext()
        await provider.releaseFirstCapture()
        let invalidated = await invalidatedEvaluation.value

        XCTAssertEqual(invalidated.outcome, .staleContext)
        XCTAssertEqual(repository.matchLocationCallCount, 0)

        let afterInvalidation = await sut.runOnce(.timer)
        let providerCalls = await provider.callCount

        XCTAssertEqual(afterInvalidation.outcome, .noAction)
        XCTAssertEqual(providerCalls, 2)
        XCTAssertEqual(
            repository.matchLocationCallCount,
            1,
            "a captura invalidada não pode fazer o próximo TIMER estacionário ser suprimido"
        )

        let snapshot = await journal.snapshot()
        XCTAssertEqual(
            snapshot.finishes.map(\.terminal.outcome),
            [.staleContext, .noAction]
        )
        let invalidatedTerminal = try! XCTUnwrap(
            snapshot.finishes.first?.terminal
        )
        XCTAssertEqual(invalidatedTerminal.stage, .movement)
        XCTAssertEqual(
            invalidatedTerminal.locationSource,
            .freshCapture
        )
        XCTAssertEqual(invalidatedTerminal.captureReused, false)
        XCTAssertEqual(
            invalidatedTerminal.accuracyBucket,
            .elevenTo25Meters
        )
        XCTAssertEqual(invalidatedTerminal.ageBucket, .under1Second)
        let representation = String(reflecting: invalidatedTerminal)
        XCTAssertFalse(
            representation.contains(String(coordinateLatitude))
        )
        XCTAssertFalse(
            representation.contains(String(coordinateLongitude))
        )
    }

    func test_candidateMatchesBeforeSlowStateAndNeverResendsSampleAfterItAges() async {
        let clock = ArmableClock(now)
        let provider = FakeLocationProvider(.success(sample()))
        let baseRepository = repository(
            matchResult: .success(
                match(.matched, local: "Unidade P80")
            )
        )
        baseRepository.getStateResult = .success(history(.checkOut))
        let repository = StateGatedRepository(base: baseRepository)
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            clock: clock
        )

        let evaluation = Task {
            await sut.runOnce(.timer)
        }
        await repository.stateStarted.wait()

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(
            baseRepository.matchLocationCallCount,
            1,
            "o matcher deve concluir antes de o pipeline aguardar state"
        )
        XCTAssertEqual(baseRepository.submitCount, 0)

        // A amostra envelhece enquanto somente o state está pendente. Ela não pode voltar ao matcher:
        // a continuação usa apenas PreparedAutomaticActivitiesMatch, que não contém coordenadas.
        clock.advance(
            by: LocationSamplePolicy.candidateTrial.maximumAge + 1
        )
        await repository.releaseState()
        let completion = await evaluation.value

        XCTAssertEqual(completion.outcome, .submittedCheckIn)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(baseRepository.matchLocationCallCount, 1)
        XCTAssertEqual(baseRepository.getStateCallCount, 1)
        XCTAssertEqual(baseRepository.submitCount, 1)
    }

    func test_candidateMissingProjectStopsBeforePhysicalCapture() async {
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            preferences: preferences(activeProject: ""),
            clock: FixedClock(now)
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .notConfigured)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.getStateCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
    }

    func test_candidateUnregisteredSubmitHTTP422RemainsHTTPRejectedAndIsNotQueued() async {
        let detailSentinel = "backend-detail-must-stay-in-memory"
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository(
            matchResult: .success(match(.notInKnownLocation))
        )
        repository.getStateResult = .success(
            history(.checkIn, local: "Escritório Principal")
        )
        repository.submitResult = .failure(
            .http(status: 422, detail: detailSentinel)
        )
        let queue = FakeOfflineQueue()
        let auth = successfulAuthRepository()
        let journal = RecordingEvaluationJournal()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            queue: queue,
            journal: journal,
            clock: FixedClock(now),
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            )
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .httpRejected)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.getStateCallCount, 1)
        XCTAssertEqual(repository.submitCount, 1)
        XCTAssertEqual(auth.callCount, 0)
        XCTAssertEqual(
            repository.submitCalls.first?.local,
            AUTOMATIC_UNREGISTERED_CHECKIN_LOCATION
        )
        XCTAssertTrue(queue.enqueued.isEmpty)

        let snapshot = await journal.snapshot()
        let terminal = try! XCTUnwrap(snapshot.finishes.first?.terminal)
        XCTAssertEqual(terminal.outcome, .httpRejected)
        XCTAssertEqual(terminal.stage, .submit)
        XCTAssertEqual(terminal.http?.status, 422)
        XCTAssertEqual(terminal.http?.classification, .clientError)
        XCTAssertFalse(String(reflecting: terminal).contains(detailSentinel))
    }

    func test_sessionInvalidatedAfterDecisionBeforeSubmitDispatchesNeitherSubmitNorQueue() async {
        let clock = ArmableSessionInvalidatingClock(now)
        let coordinator = OrchestratorAuthSessionCoordinator(
            authRepository: NoopAuthRepository(),
            securePasswordStore: NoopSecurePasswordStore()
        )
        let provider = FakeLocationProvider(.success(sample()))
        let baseRepository = repository(
            matchResult: .success(match(.matched, local: "Unidade P80"))
        )
        baseRepository.getStateResult = .success(history(.checkOut))
        let repository = StateResultHookRepository(base: baseRepository) {
            clock.invalidateOnNextRead {
                _ = coordinator.invalidateCurrentIdentity()
            }
        }
        let queue = FakeOfflineQueue()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            queue: queue,
            clock: clock,
            authSessionCoordinator: coordinator
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(baseRepository.matchLocationCallCount, 1)
        XCTAssertEqual(baseRepository.getStateCallCount, 1)
        XCTAssertEqual(baseRepository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
    }

    func test_candidateOptionsUnauthorizedRefreshesOnceAndRetriesOnlyOptions() async {
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository()
        repository.queuedGetLocationsResults = [
            .failure(.unauthorized),
            repository.getLocationsResult,
        ]
        let auth = successfulAuthRepository()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            clock: FixedClock(now),
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            )
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .noAction)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(repository.getLocationsCallCount, 2)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.getStateCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
    }

    func test_candidateSecondOptionsUnauthorizedStopsAfterOneRefresh() async {
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository()
        repository.queuedGetLocationsResults = [
            .failure(.unauthorized),
            .failure(.unauthorized),
        ]
        let auth = successfulAuthRepository()
        let journal = RecordingEvaluationJournal()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            journal: journal,
            clock: FixedClock(now),
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            )
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .unauthorized)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(repository.getLocationsCallCount, 2)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.getStateCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.finishes.first?.terminal.stage, .options)
    }

    func test_candidateMatchUnauthorizedRetriesSameFreshSampleWithoutRecapture() async {
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository()
        repository.queuedMatchLocationResults = [
            .failure(.unauthorized),
            .success(match(.noKnownLocations)),
        ]
        let auth = successfulAuthRepository()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            clock: FixedClock(now),
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            )
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .noAction)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 2)
        XCTAssertEqual(repository.getStateCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        let matchCalls = repository.matchLocationCallsSnapshot
        XCTAssertEqual(matchCalls.count, 2)
        if matchCalls.count == 2 {
            XCTAssertEqual(
                matchCalls[0],
                matchCalls[1],
                "o retry deve repetir exatamente latitude/longitude/accuracy da primeira tentativa"
            )
        }
        XCTAssertEqual(repository.lastMatchLocationCall?.latitude, sample().latitude)
        XCTAssertEqual(repository.lastMatchLocationCall?.longitude, sample().longitude)
        XCTAssertEqual(
            repository.lastMatchLocationCall?.accuracyMeters,
            sample().horizontalAccuracyMeters
        )
    }

    func test_candidateSecondMatchUnauthorizedStopsAfterOneRefreshAndNoRecapture() async {
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository()
        repository.queuedMatchLocationResults = [
            .failure(.unauthorized),
            .failure(.unauthorized),
        ]
        let auth = successfulAuthRepository()
        let queue = FakeOfflineQueue()
        let journal = RecordingEvaluationJournal()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            queue: queue,
            journal: journal,
            clock: FixedClock(now),
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            )
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .unauthorized)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 2)
        XCTAssertEqual(repository.getStateCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.finishes.first?.terminal.stage, .match)
    }

    func test_candidateSecondStateUnauthorizedStopsAfterOneRefreshWithoutReplayingEarlierStages() async {
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository(
            matchResult: .success(
                match(.matched, local: "Unidade P80")
            )
        )
        repository.queuedGetStateResults = [
            .failure(.unauthorized),
            .failure(.unauthorized),
        ]
        let auth = successfulAuthRepository()
        let journal = RecordingEvaluationJournal()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            journal: journal,
            clock: FixedClock(now),
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            )
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .unauthorized)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.getStateCallCount, 2)
        XCTAssertEqual(repository.submitCount, 0)
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.finishes.first?.terminal.stage, .state)
    }

    func test_candidateMatchRetryRejectsSampleThatAgesDuringRefreshWithoutRecapture() async {
        let clock = ArmableClock(now)
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository()
        repository.queuedMatchLocationResults = [
            .failure(.unauthorized),
            .success(match(.noKnownLocations)),
        ]
        let auth = successfulAuthRepository()
        let journal = RecordingEvaluationJournal()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            journal: journal,
            clock: clock,
            authRepository: auth,
            securePasswordStore: ClockAdvancingPasswordStore(
                clock: clock,
                interval: LocationSamplePolicy.candidateTrial.maximumAge + 0.001
            )
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(
            repository.matchLocationCallCount,
            1,
            "a revalidação stale deve impedir a segunda chamada ao matcher"
        )
        XCTAssertEqual(repository.getStateCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.finishes.first?.terminal.stage, .acquisition)
    }

    func test_candidateMatchHTTP422NeverRefreshesOrRecaptures() async {
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository(
            matchResult: .failure(
                .http(status: 422, detail: "match-detail-sentinel")
            )
        )
        let auth = successfulAuthRepository()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            clock: FixedClock(now),
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            )
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .httpRejected)
        XCTAssertEqual(auth.callCount, 0)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.getStateCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
    }

    func test_candidateSubmitUnauthorizedNeverRefreshesRetriesOrQueues() async {
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository(
            matchResult: .success(
                match(.matched, local: "Unidade P80")
            )
        )
        repository.getStateResult = .success(history(.checkOut))
        repository.submitResult = .failure(.unauthorized)
        let queue = FakeOfflineQueue()
        let auth = successfulAuthRepository()
        let journal = RecordingEvaluationJournal()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            queue: queue,
            journal: journal,
            clock: FixedClock(now),
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            )
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .unauthorized)
        XCTAssertEqual(auth.callCount, 0)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.getStateCallCount, 1)
        XCTAssertEqual(repository.submitCount, 1)
        XCTAssertEqual(repository.submitCalls.count, 1)
        XCTAssertTrue(queue.enqueued.isEmpty)
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.finishes.first?.terminal.stage, .submit)
    }

    func test_candidateOneRefreshBudgetIsSharedAcrossOptionsAndState() async {
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository(
            matchResult: .success(
                match(.matched, local: "Unidade P80")
            )
        )
        repository.queuedGetLocationsResults = [
            .failure(.unauthorized),
            repository.getLocationsResult,
        ]
        repository.queuedGetStateResults = [
            .failure(.unauthorized),
            .success(history(.checkOut)),
        ]
        let auth = successfulAuthRepository()
        let journal = RecordingEvaluationJournal()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            journal: journal,
            clock: FixedClock(now),
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            )
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .unauthorized)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(repository.getLocationsCallCount, 2)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(
            repository.getStateCallCount,
            1,
            "o segundo unauthorized deve encerrar sem consumir um segundo refresh"
        )
        XCTAssertEqual(repository.submitCount, 0)
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.finishes.first?.terminal.stage, .state)
    }

    func test_legacyTimerUsesLegacyCompatibleCaptureAndRetainsTwoPhysicalCaptures() async {
        // A amostra deliberadamente antiga prova que o helper não injeta a política candidata no perfil
        // legado: o caminho legacyCompatible preserva o match observável existente.
        let provider = FakeLocationProvider(
            .success(sample(capturedAt: now.addingTimeInterval(-86_400)))
        )
        let repository = repository()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            clock: FixedClock(now),
            pipeline: .legacy
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .noAction)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
    }

    func test_candidateProfileLeavesGeofenceSignificantAndForegroundAtOneEngineCapture() async {
        let triggers: [OrchestratorTrigger] = [
            .geofence,
            .significantLocation,
            .foreground,
        ]

        for trigger in triggers {
            let provider = FakeLocationProvider(.success(sample()))
            let repository = repository()
            let sut = orchestrator(
                provider: provider,
                repository: repository,
                clock: FixedClock(now)
            )

            let completion = await sut.runOnce(trigger)

            XCTAssertEqual(completion.outcome, .noAction, trigger.name)
            XCTAssertEqual(provider.callCount, 1, trigger.name)
            XCTAssertEqual(
                repository.matchLocationCallCount,
                1,
                trigger.name
            )
        }
    }

    func test_candidateStateUnauthorizedReloginResumesWithoutRecaptureOrDuplicateSubmit() async {
        let provider = FakeLocationProvider(.success(sample()))
        let repository = repository(
            matchResult: .success(match(.matched, local: "Unidade P80"))
        )
        repository.queuedGetStateResults = [
            .failure(.unauthorized),
            .success(history(.checkOut)),
        ]
        repository.submitResult = .success(
            history(.checkIn, local: "Unidade P80")
        )
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
        let journal = RecordingEvaluationJournal()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            journal: journal,
            clock: FixedClock(now),
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(
                password: "password-sentinel"
            )
        )

        let completion = await sut.runOnce(.timer)

        XCTAssertEqual(completion.outcome, .submittedCheckIn)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.getStateCallCount, 2)
        XCTAssertEqual(repository.submitCount, 1)
        XCTAssertEqual(repository.submitCalls.count, 1)
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.begins.count, 1)
        XCTAssertEqual(snapshot.finishes.count, 1)
        XCTAssertEqual(
            snapshot.finishes.first?.terminal.outcome,
            .submittedCheckIn
        )
    }
}
