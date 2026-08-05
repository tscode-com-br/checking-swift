import Foundation
import XCTest
@testable import Checking

final class LocationAttemptPipelineTests: XCTestCase {
    private final class EffectGuardSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool]
        private var index = 0

        init(_ values: [Bool]) {
            precondition(!values.isEmpty)
            self.values = values
        }

        func next() -> Bool {
            lock.withLock {
                defer { index += 1 }
                return values[min(index, values.count - 1)]
            }
        }
    }

    private actor MultiWaiterGate {
        private var released = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func release() {
            released = true
            continuations.forEach { $0.resume() }
            continuations.removeAll()
        }
    }

    private final class SequenceClock: Clock, @unchecked Sendable {
        private let lock = NSLock()
        private let instants: [Date]
        private var index = 0

        init(_ instants: [Date]) {
            precondition(!instants.isEmpty)
            self.instants = instants
        }

        func now() -> Date {
            lock.withLock {
                let instant = instants[min(index, instants.count - 1)]
                index += 1
                return instant
            }
        }

        var readCount: Int {
            lock.withLock { index }
        }
    }

    private actor RoutingCapture: SampleAwareLocationCapturing {
        private let gate: MultiWaiterGate?
        private var recordedAttempts: [LocationAttemptInput] = []

        init(gate: MultiWaiterGate? = nil) {
            self.gate = gate
        }

        func callAsFunction(_ accuracyThresholdMeters: Int) async -> LocationCaptureResult {
            await execute(
                accuracyThresholdMeters,
                locationAttempt: .acquire
            ).result
        }

        func execute(
            _ accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> LocationCaptureExecution {
            recordedAttempts.append(locationAttempt)
            await gate?.wait()
            let result: LocationCaptureResult
            let failure: LocationCaptureExecutionFailure?
            let stage: AutomaticActivitiesStage
            let capture: AutomaticCaptureTrace?
            switch locationAttempt {
            case .acquire:
                result = .matched(ucMatch(.matched, "acquire"))
                failure = nil
                stage = .matched
                capture = AutomaticCaptureTrace(
                    source: .freshCapture,
                    physicalSource: .standardCapture,
                    reused: false,
                    quality: .usable
                )
            case .seedCandidate(let sample), .finalSample(let sample):
                let local = sample.latitude == 1 ? "first" : "second"
                result = .matched(ucMatch(.matched, local))
                failure = nil
                stage = .matched
                capture = nil
            }
            return LocationCaptureExecution(
                result: result,
                maximumStage: stage,
                capture: capture,
                failure: failure
            )
        }

        var attempts: [LocationAttemptInput] { recordedAttempts }
        var callCount: Int { recordedAttempts.count }
    }

    private let now = iso("2026-06-20T08:00:00Z")

    private var projects: UserProjects {
        UserProjects(projects: ["P80"], activeProject: "P80")
    }

    private func sample(
        latitude: Double = 1.3,
        longitude: Double = 103.8,
        accuracy: Double = 12,
        capturedAt: Date? = nil
    ) -> LocationSample {
        LocationSample(
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracyMeters: accuracy,
            capturedAt: capturedAt ?? now,
            source: .standardCapture
        )
    }

    private func captureUseCase(
        provider: FakeLocationProvider,
        repository: FakeCheckRepository,
        clock: any Clock,
        behavior: LocationCaptureBehavior = .freshnessValidated,
        logger: any ActivityLogging = NoopActivityLogger()
    ) -> CaptureLocationUseCase {
        CaptureLocationUseCase(
            locationProvider: provider,
            checkRepository: repository,
            activityLogger: logger,
            clock: clock,
            captureBehavior: behavior
        )
    }

    func test_defaultAcquirePreservesLegacyAndCandidateRejectsStaleFix() async {
        let stale = sample(capturedAt: now.addingTimeInterval(-60))

        let legacyProvider = FakeLocationProvider(.success(stale))
        let legacyRepository = FakeCheckRepository()
        legacyRepository.matchLocationResult = .success(ucMatch(.matched, "legacy"))
        let legacy = captureUseCase(
            provider: legacyProvider,
            repository: legacyRepository,
            clock: FixedClock(now),
            behavior: .legacyCompatible
        )

        let candidateProvider = FakeLocationProvider(.success(stale))
        let candidateRepository = FakeCheckRepository()
        candidateRepository.matchLocationResult = .success(ucMatch(.matched, "candidate"))
        let candidate = captureUseCase(
            provider: candidateProvider,
            repository: candidateRepository,
            clock: FixedClock(now)
        )

        let legacyResult = await legacy(50)
        let candidateResult = await candidate(
            50,
            locationAttempt: .acquire
        )

        XCTAssertEqual(legacyResult, .matched(ucMatch(.matched, "legacy")))
        XCTAssertEqual(candidateResult, .timeout)
        XCTAssertEqual(legacyProvider.callCount, 1)
        XCTAssertEqual(candidateProvider.callCount, 1)
        XCTAssertNil(legacyProvider.lastSeed)
        XCTAssertNil(candidateProvider.lastSeed)
        XCTAssertEqual(legacyRepository.matchLocationCallCount, 1)
        XCTAssertEqual(candidateRepository.matchLocationCallCount, 0)
    }

    func test_finalSampleValidHasTypedAcquisitionProviderZeroAndMatchOne() async {
        let final = sample(latitude: 1.234, longitude: 2.345, accuracy: 9)
        let provider = FakeLocationProvider(.failure(.unavailable))
        let repository = FakeCheckRepository()
        let expected = ucMatch(.matched, "Unidade P80")
        repository.matchLocationResult = .success(expected)
        let sut = captureUseCase(
            provider: provider,
            repository: repository,
            clock: FixedClock(now)
        )

        let acquisition = await sut.acquireSample(50, input: .finalSample(final))
        let result = await sut(50, locationAttempt: .finalSample(final))

        XCTAssertEqual(acquisition, .sample(final, reused: true))
        XCTAssertEqual(result, .matched(expected))
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(
            repository.lastMatchLocationCall,
            .init(
                latitude: final.latitude,
                longitude: final.longitude,
                accuracyMeters: final.horizontalAccuracyMeters
            )
        )
    }

    func test_matchResponseAfterContextInvalidationIsDiscardedBeforeLoggingOrRawProjection() async {
        let provider = FakeLocationProvider(.success(sample()))
        let repository = FakeCheckRepository()
        repository.matchLocationResult = .success(
            ucMatch(.matched, "must-not-be-logged")
        )
        let dao = CapturingDao()
        let logger = ActivityLogger(
            clock: FixedClock(now),
            activityLog: ActivityLog(dao: dao),
            scheduler: InlineLogScheduler()
        )
        let sut = captureUseCase(
            provider: provider,
            repository: repository,
            clock: FixedClock(now),
            logger: logger
        )
        // Entry + pre-match + dispatch commit are current; only the response-side fence is revoked.
        let validity = EffectGuardSequence([true, true, true, false])

        let execution = await sut.execute(
            50,
            locationAttempt: .acquire,
            effectGuard: AutomaticActivitiesEffectGuard(
                operationIsCurrent: { validity.next() }
            )
        )

        XCTAssertEqual(execution.result, .timeout)
        XCTAssertEqual(execution.failure, .cancelled(.contextInvalidated))
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertTrue(dao.rows.isEmpty)
    }

    func test_finalSampleStaleIsTypedRejectedWithProviderAndMatcherZero() async {
        let stale = sample(capturedAt: now.addingTimeInterval(-10.001))
        let provider = FakeLocationProvider(.failure(.unavailable))
        let repository = FakeCheckRepository()
        let sut = captureUseCase(
            provider: provider,
            repository: repository,
            clock: FixedClock(now)
        )

        let acquisition = await sut.acquireSample(50, input: .finalSample(stale))
        let result = await sut(50, locationAttempt: .finalSample(stale))

        XCTAssertEqual(acquisition, .rejected(.stale))
        XCTAssertEqual(result, .timeout)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
    }

    func test_finalFreshCoarseStillReachesMatcherAndPreservesAccuracyEpisodeResult() async {
        let coarse = sample(accuracy: 500)
        let provider = FakeLocationProvider(.failure(.unavailable))
        let repository = FakeCheckRepository()
        repository.matchLocationResult = .success(ucMatch(.accuracyTooLow))
        let capture = captureUseCase(
            provider: provider,
            repository: repository,
            clock: FixedClock(now)
        )
        let automatic = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: FakeOfflineQueue(),
            clock: FixedClock(now),
            activityLogger: NoopActivityLogger()
        )

        let result = await automatic(
            chave: "STSM",
            userProjects: projects,
            currentState: ucHistory(.checkOut),
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50,
            locationAttempt: .finalSample(coarse)
        )

        XCTAssertEqual(result, .accuracyTooLow(expectedAction: .checkIn))
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.submitCount, 0)
    }

    func test_staleSeedFallsBackOnceAndMatcherUsesOnlyNewFix() async {
        let staleSeed = sample(
            latitude: 10,
            longitude: 20,
            accuracy: 3,
            capturedAt: now.addingTimeInterval(-60)
        )
        let newFix = sample(latitude: 30, longitude: 40, accuracy: 18)
        let provider = FakeLocationProvider(.success(newFix))
        let repository = FakeCheckRepository()
        repository.matchLocationResult = .success(ucMatch(.matched, "new"))
        let sut = captureUseCase(
            provider: provider,
            repository: repository,
            clock: FixedClock(now)
        )

        let result = await sut(
            50,
            locationAttempt: .seedCandidate(staleSeed)
        )

        XCTAssertEqual(result, .matched(ucMatch(.matched, "new")))
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertNil(provider.lastSeed)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(
            repository.lastMatchLocationCall,
            .init(
                latitude: newFix.latitude,
                longitude: newFix.longitude,
                accuracyMeters: newFix.horizontalAccuracyMeters
            )
        )
    }

    func test_freshSeedIsForwardedUnchangedThroughTheSingleProviderBudget() async {
        let freshSeed = sample(latitude: 10, longitude: 20, accuracy: 7)
        let provider = FakeLocationProvider(.success(freshSeed))
        let repository = FakeCheckRepository()
        repository.matchLocationResult = .success(ucMatch(.matched, "seed"))
        let sut = captureUseCase(
            provider: provider,
            repository: repository,
            clock: FixedClock(now)
        )

        let result = await sut(
            50,
            locationAttempt: .seedCandidate(freshSeed)
        )

        XCTAssertEqual(result, .matched(ucMatch(.matched, "seed")))
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(provider.lastSeed, freshSeed)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(
            repository.lastMatchLocationCall,
            .init(
                latitude: freshSeed.latitude,
                longitude: freshSeed.longitude,
                accuracyMeters: freshSeed.horizontalAccuracyMeters
            )
        )
    }

    func test_seedFallbackFailureAndPermissionDoNotLoopOrMatch() async {
        let staleSeed = sample(capturedAt: now.addingTimeInterval(-60))
        let cases: [(LocationAcquisitionFailure, LocationCaptureResult)] = [
            (.timeout, .timeout),
            (.permissionDenied, .noPermission),
            (.unavailable, .noPermission),
            (.cancelled(.taskCancelled), .timeout),
        ]

        for (failure, expected) in cases {
            let provider = FakeLocationProvider(.failure(failure))
            let repository = FakeCheckRepository()
            let sut = captureUseCase(
                provider: provider,
                repository: repository,
                clock: FixedClock(now)
            )

            let result = await sut(
                50,
                locationAttempt: .seedCandidate(staleSeed)
            )

            XCTAssertEqual(result, expected)
            XCTAssertEqual(provider.callCount, 1)
            XCTAssertNil(provider.lastSeed)
            XCTAssertEqual(repository.matchLocationCallCount, 0)
        }
    }

    func test_providerReturningStaleSuccessDoesNotReacquireOrMatch() async {
        let stale = sample(capturedAt: now.addingTimeInterval(-60))
        let provider = FakeLocationProvider(.success(stale))
        let repository = FakeCheckRepository()
        let sut = captureUseCase(
            provider: provider,
            repository: repository,
            clock: FixedClock(now)
        )

        let result = await sut(
            50,
            locationAttempt: .seedCandidate(stale)
        )

        XCTAssertEqual(result, .timeout)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertNil(provider.lastSeed)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
    }

    func test_sameSampleIsRevalidatedAtLaterResolutionInstant() async {
        let final = sample()
        let provider = FakeLocationProvider(.failure(.unavailable))
        let repository = FakeCheckRepository()
        let clock = SequenceClock([
            now,
            now.addingTimeInterval(10.001)
        ])
        let sut = captureUseCase(
            provider: provider,
            repository: repository,
            clock: clock
        )

        let result = await sut(
            50,
            locationAttempt: .finalSample(final)
        )

        XCTAssertEqual(result, .timeout)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(clock.readCount, 2)
    }

    func test_preCancelledFinalSampleNeverCallsProviderOrMatcher() async {
        let provider = FakeLocationProvider(.failure(.unavailable))
        let repository = FakeCheckRepository()
        let sut = captureUseCase(
            provider: provider,
            repository: repository,
            clock: FixedClock(now)
        )
        let final = sample()

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await sut.execute(
                50,
                locationAttempt: .finalSample(final)
            )
        }
        let execution = await task.value

        XCTAssertEqual(execution.result, .timeout)
        XCTAssertEqual(
            execution.failure,
            .acquisition(.cancelled(.taskCancelled))
        )
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
    }

    func test_cancellationDuringMatcherCannotProduceConsumableSuccess() async {
        let provider = FakeLocationProvider(.failure(.unavailable))
        let repository = FakeCheckRepository()
        repository.matchLocationResult = .success(ucMatch(.matched, "late"))
        let gate = AsyncGate()
        repository.matchLocationGate = gate
        let sut = captureUseCase(
            provider: provider,
            repository: repository,
            clock: FixedClock(now)
        )
        let final = sample()
        let task = Task {
            await sut.execute(
                50,
                locationAttempt: .finalSample(final)
            )
        }
        await waitUntil { repository.matchLocationCallCount == 1 }

        task.cancel()
        await gate.release()
        let execution = await task.value

        XCTAssertEqual(execution.result, .timeout)
        XCTAssertEqual(execution.failure, .cancelled(.taskCancelled))
        XCTAssertEqual(execution.maximumStage, .captured)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
    }

    func test_matchFailuresPreserveReadingOnlyForNetworkAndRetrySampleOnlyForUnauthorized() async {
        let final = sample(latitude: 9, longitude: 8, accuracy: 7)
        let cases: [(ApiError, LocationCaptureResult)] = [
            (
                .network,
                .networkError(reading: LocationReading(
                    lat: final.latitude,
                    lon: final.longitude,
                    accuracyMeters: final.horizontalAccuracyMeters
                ))
            ),
            (.unauthorized, .networkError(reading: nil)),
            (.http(status: 422, detail: "unregistered"), .networkError(reading: nil)),
            (.http(status: 500, detail: "server"), .networkError(reading: nil)),
            (.conflict, .networkError(reading: nil)),
            (.unknown(description: "diagnostic"), .networkError(reading: nil)),
        ]

        for (error, expected) in cases {
            let provider = FakeLocationProvider(.failure(.unavailable))
            let repository = FakeCheckRepository()
            repository.matchLocationResult = .failure(error)
            let sut = captureUseCase(
                provider: provider,
                repository: repository,
                clock: FixedClock(now)
            )

            let execution = await sut.execute(
                50,
                locationAttempt: .finalSample(final)
            )

            XCTAssertEqual(execution.result, expected)
            XCTAssertEqual(execution.failure, .match(error))
            XCTAssertEqual(execution.maximumStage, .matched)
            if case .unauthorized = error {
                XCTAssertEqual(execution.retryableMatchSample, final)
            } else {
                XCTAssertNil(execution.retryableMatchSample)
            }
            XCTAssertEqual(provider.callCount, 0)
            XCTAssertEqual(repository.matchLocationCallCount, 1)
        }
    }

    func test_coalescerBypassesTwoDistinctSeededEvaluations() async {
        let gate = MultiWaiterGate()
        let base = RoutingCapture(gate: gate)
        let sut = CoalescingLocationCapture(base: base)
        let firstSample = sample(latitude: 1)
        let secondSample = sample(latitude: 2)
        let first = Task {
            await sut(
                50,
                locationAttempt: .seedCandidate(firstSample)
            )
        }
        await waitUntil { await base.callCount == 1 }
        let second = Task {
            await sut(
                50,
                locationAttempt: .seedCandidate(secondSample)
            )
        }
        await waitUntil { await base.callCount == 2 }
        await gate.release()

        let firstResult = await first.value
        let secondResult = await second.value

        XCTAssertEqual(firstResult, .matched(ucMatch(.matched, "first")))
        XCTAssertEqual(secondResult, .matched(ucMatch(.matched, "second")))
        let attempts = await base.attempts
        let waiterCounts = await sut.waiterCountsForTest
        XCTAssertEqual(
            attempts,
            [.seedCandidate(firstSample), .seedCandidate(secondSample)]
        )
        XCTAssertTrue(waiterCounts.isEmpty)
    }

    func test_explicitAcquirePathCoalescesConcurrentAutomaticConsumers() async {
        let gate = MultiWaiterGate()
        let base = RoutingCapture(gate: gate)
        let sut = CoalescingLocationCapture(base: base)
        let first = Task {
            await sut.execute(50, locationAttempt: .acquire)
        }
        await waitUntil { await base.callCount == 1 }
        let second = Task {
            await sut.execute(50, locationAttempt: .acquire)
        }
        await waitUntil { (await sut.waiterCountsForTest)[50] == 2 }

        let callsBeforeRelease = await base.callCount
        XCTAssertEqual(callsBeforeRelease, 1)
        await gate.release()
        let executions = await [first.value, second.value]
        let attempts = await base.attempts
        let waiterCounts = await sut.waiterCountsForTest

        XCTAssertEqual(
            executions.map(\.result),
            [
                .matched(ucMatch(.matched, "acquire")),
                .matched(ucMatch(.matched, "acquire")),
            ]
        )
        XCTAssertEqual(executions.map(\.capture?.reused), [false, true])
        XCTAssertEqual(executions.map(\.capture?.source), [.freshCapture, .freshCapture])
        XCTAssertEqual(attempts, [.acquire])
        XCTAssertTrue(waiterCounts.isEmpty)
    }

    func test_automaticExistentialDispatchesDefaultAcquireAndExplicitFinalSample() async {
        let capture = FakeCaptureLocation(.timeout)
        let automatic: any RunningAutomaticActivities = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: FakeCheckRepository(),
            offlineQueue: FakeOfflineQueue(),
            clock: FixedClock(now),
            activityLogger: NoopActivityLogger()
        )
        let final = sample()

        let defaultResult = await automatic(
            chave: "STSM",
            userProjects: projects,
            currentState: nil,
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50
        )
        let explicitResult = await automatic(
            chave: "STSM",
            userProjects: projects,
            currentState: nil,
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50,
            locationAttempt: .finalSample(final)
        )

        XCTAssertEqual(defaultResult, .locationTimeout)
        XCTAssertEqual(explicitResult, .locationTimeout)
        XCTAssertEqual(capture.thresholds, [50, 50])
        XCTAssertEqual(capture.attempts, [.acquire, .finalSample(final)])
    }

    func test_matchNetworkEnqueuesOneExactRawUsingEvaluationClock() async {
        let capturedAt = now.addingTimeInterval(-5)
        let final = sample(
            latitude: 1.5,
            longitude: 103.8,
            accuracy: 12,
            capturedAt: capturedAt
        )
        let provider = FakeLocationProvider(.failure(.unavailable))
        let repository = FakeCheckRepository()
        repository.matchLocationResult = .failure(.network)
        let queue = FakeOfflineQueue()
        let idCalls = LockedCounter()
        let capture = captureUseCase(
            provider: provider,
            repository: repository,
            clock: FixedClock(now)
        )
        let automatic = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: FixedClock(now),
            activityLogger: NoopActivityLogger(),
            makeClientEventID: {
                idCalls.increment()
                return "RAW-ID"
            }
        )

        let result = await automatic(
            chave: "HR70",
            userProjects: projects,
            currentState: ucHistory(.checkIn),
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50,
            locationAttempt: .finalSample(final)
        )

        XCTAssertEqual(result, .networkError)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertEqual(idCalls.value, 1)
        XCTAssertEqual(queue.enqueued.count, 1)
        guard case .raw(let raw) = queue.enqueued[0] else {
            return XCTFail("expected Raw")
        }
        XCTAssertEqual(raw.chave, "HR70")
        XCTAssertEqual(raw.projeto, "P80")
        XCTAssertEqual(raw.clientEventId, "RAW-ID")
        XCTAssertEqual(raw.capturedAtEpochMs, epochMilliseconds(now))
        XCTAssertNotEqual(raw.capturedAtEpochMs, epochMilliseconds(capturedAt))
        XCTAssertEqual(raw.latitude, final.latitude)
        XCTAssertEqual(raw.longitude, final.longitude)
        XCTAssertEqual(raw.accuracyMeters, final.horizontalAccuracyMeters)
    }

    func test_submitNetworkReusesExactContextInSingleDecidedEvent() async {
        let final = sample()
        let provider = FakeLocationProvider(.failure(.unavailable))
        let repository = FakeCheckRepository()
        repository.matchLocationResult = .success(ucMatch(.matched, "Unidade P80"))
        repository.submitResult = .failure(.network)
        let queue = FakeOfflineQueue()
        let idCalls = LockedCounter()
        let capture = captureUseCase(
            provider: provider,
            repository: repository,
            clock: FixedClock(now)
        )
        let automatic = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: FixedClock(now),
            activityLogger: NoopActivityLogger(),
            makeClientEventID: {
                idCalls.increment()
                return "DECIDED-ID"
            }
        )

        let result = await automatic(
            chave: "HR70",
            userProjects: projects,
            currentState: ucHistory(.checkOut),
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50,
            locationAttempt: .finalSample(final)
        )

        XCTAssertEqual(result, .networkError)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.submitCount, 1)
        XCTAssertEqual(idCalls.value, 1)
        XCTAssertEqual(
            repository.submitCalls,
            [.init(
                chave: "HR70",
                projeto: "P80",
                action: .checkIn,
                local: "Unidade P80",
                informe: .normal,
                eventTime: now,
                clientEventId: "DECIDED-ID",
                fillForms: true
            )]
        )
        XCTAssertEqual(queue.enqueued.count, 1)
        guard case .decided(let decided) = queue.enqueued[0] else {
            return XCTFail("expected Decided")
        }
        XCTAssertEqual(decided.chave, "HR70")
        XCTAssertEqual(decided.projeto, "P80")
        XCTAssertEqual(decided.action, "checkin")
        XCTAssertEqual(decided.local, "Unidade P80")
        XCTAssertEqual(decided.informe, "normal")
        XCTAssertEqual(decided.clientEventId, "DECIDED-ID")
        XCTAssertEqual(decided.capturedAtEpochMs, epochMilliseconds(now))
    }

    func test_unregisteredSubmit422RemainsBackendRejectionWithoutRetryOrGpsRemap() async {
        let bodySentinel = "SECRET_422_BODY"
        let provider = FakeLocationProvider(.failure(.unavailable))
        let repository = FakeCheckRepository()
        repository.matchLocationResult = .success(
            ucMatch(.notInKnownLocation, nearest: 500)
        )
        repository.submitResult = .failure(
            .http(status: 422, detail: bodySentinel)
        )
        let queue = FakeOfflineQueue()
        let dao = CapturingDao()
        let logger = ActivityLogger(
            clock: FixedClock(now),
            activityLog: ActivityLog(dao: dao),
            scheduler: InlineLogScheduler()
        )
        let capture = captureUseCase(
            provider: provider,
            repository: repository,
            clock: FixedClock(now),
            logger: logger
        )
        let automatic = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: FixedClock(now),
            activityLogger: logger,
            makeClientEventID: { "UNREGISTERED-ID" }
        )

        let result = await automatic(
            chave: "HR70",
            userProjects: projects,
            currentState: ucHistory(
                .checkIn,
                currentLocal: "Unidade P80"
            ),
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50,
            locationAttempt: .finalSample(sample(accuracy: 8))
        )

        XCTAssertEqual(result, .networkError)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.submitCount, 1)
        XCTAssertEqual(queue.enqueued.count, 0)
        XCTAssertEqual(repository.submitCalls.first?.action, .checkIn)
        XCTAssertEqual(
            repository.submitCalls.first?.local,
            "Localização não Cadastrada"
        )
        XCTAssertEqual(repository.submitCalls.first?.clientEventId, "UNREGISTERED-ID")
        XCTAssertEqual(
            dao.rows.map(\.description),
            [
                "Location fixed (±8m) → unknown.",
                "Check-in failed at Localização não Cadastrada.",
            ]
        )
        XCTAssertFalse(
            dao.rows.contains { $0.description.contains(bodySentinel) }
        )
    }

    func test_noActionCreatesNoSubmissionIdentityOrSubmit() async {
        let capture = FakeCaptureLocation(
            .matched(ucMatch(.matched, "Unidade P80"))
        )
        let repository = FakeCheckRepository()
        let queue = FakeOfflineQueue()
        let idCalls = LockedCounter()
        let automatic = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: FixedClock(now),
            activityLogger: NoopActivityLogger(),
            makeClientEventID: {
                idCalls.increment()
                return "MUST-NOT-BE-CREATED"
            }
        )

        let result = await automatic(
            chave: "HR70",
            userProjects: projects,
            currentState: ucHistory(
                .checkIn,
                currentLocal: "Unidade P80"
            ),
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50
        )

        XCTAssertEqual(result, .noAction)
        XCTAssertEqual(capture.attempts, [.acquire])
        XCTAssertEqual(idCalls.value, 0)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
    }

    func test_cancellationAfterDecisionBeforeSubmitDoesNotDispatchOrEnqueue() async {
        let capture = FakeCaptureLocation(
            .matched(ucMatch(.matched, "Unidade P80"))
        )
        let repository = FakeCheckRepository()
        let queue = FakeOfflineQueue()
        let idCalls = LockedCounter()
        let automatic = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: FixedClock(now),
            activityLogger: NoopActivityLogger(),
            makeClientEventID: {
                idCalls.increment()
                withUnsafeCurrentTask { $0?.cancel() }
                return "CANCELLED-BEFORE-SUBMIT"
            }
        )

        let result = await automatic(
            chave: "HR70",
            userProjects: projects,
            currentState: ucHistory(.checkOut),
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50
        )

        XCTAssertEqual(result, .locationTimeout)
        XCTAssertEqual(capture.attempts, [.acquire])
        XCTAssertEqual(idCalls.value, 1)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
    }

    private func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
