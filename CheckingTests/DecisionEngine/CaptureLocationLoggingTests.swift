import XCTest
@testable import Checking

private func typedCaptureExecution(
    _ result: LocationCaptureResult
) -> LocationCaptureExecution {
    let failure: LocationCaptureExecutionFailure?
    let stage: AutomaticActivitiesStage
    switch result {
    case .matched:
        failure = nil
        stage = .matched
    case .timeout:
        failure = .acquisition(.timeout)
        stage = .captureStarted
    case .noPermission:
        failure = .acquisition(.unavailable)
        stage = .captureStarted
    case .networkError:
        failure = .match(.network)
        stage = .matched
    }
    return LocationCaptureExecution(
        result: result,
        maximumStage: stage,
        capture: nil,
        failure: failure
    )
}

// Port de CaptureLocationLoggingTest.kt — o único chokepoint que escreve a linha LOCATION.
// Logger REAL + DAO in-memory + InlineLogScheduler. Ver docs/port_spec_decision_engine.md §9.3.
final class CaptureLocationLoggingTests: XCTestCase {

    private actor SlowCountingCapture: SampleAwareLocationCapturing {
        private(set) var callCount = 0
        let result: LocationCaptureResult

        init(result: LocationCaptureResult) {
            self.result = result
        }

        func callAsFunction(_ accuracyThresholdMeters: Int) async -> LocationCaptureResult {
            callCount += 1
            try? await Task.sleep(for: .milliseconds(50))
            return result
        }

        func execute(
            _ accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> LocationCaptureExecution {
            typedCaptureExecution(await callAsFunction(accuracyThresholdMeters))
        }
    }

    private actor GatedCapture: SampleAwareLocationCapturing {
        private(set) var callCount = 0
        let gate = AsyncGate()
        let result: LocationCaptureResult

        init(result: LocationCaptureResult) {
            self.result = result
        }

        func callAsFunction(_ accuracyThresholdMeters: Int) async -> LocationCaptureResult {
            callCount += 1
            await gate.wait()
            return result
        }

        func execute(
            _ accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> LocationCaptureExecution {
            typedCaptureExecution(await callAsFunction(accuracyThresholdMeters))
        }

        func release() async {
            await gate.release()
        }
    }

    private actor CancellationAwareCapture: SampleAwareLocationCapturing {
        private(set) var callCount = 0
        private(set) var cancellationCount = 0

        func callAsFunction(_ accuracyThresholdMeters: Int) async -> LocationCaptureResult {
            callCount += 1
            do {
                try await Task.sleep(for: .seconds(60))
                return .matched(ucMatch(.matched, "Escritório Principal"))
            } catch {
                cancellationCount += 1
                return .timeout
            }
        }

        func execute(
            _ accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> LocationCaptureExecution {
            typedCaptureExecution(await callAsFunction(accuracyThresholdMeters))
        }
    }

    private actor GatedLocationProvider: LocationProvider {
        private(set) var callCount = 0
        let gate = AsyncGate()
        let result: LocationCapture

        init(result: LocationCapture) {
            self.result = result
        }

        func capture(
            _ accuracyThresholdMeters: Int,
            seed: LocationSample?
        ) async -> LocationCapture {
            callCount += 1
            await gate.wait()
            return result
        }

        func release() async {
            await gate.release()
        }
    }

    private func run(provider: LocationCapture, match: AppResult<LocationMatch>, dao: CapturingDao) async -> LocationCaptureResult {
        let repo = FakeCheckRepository(); repo.matchLocationResult = match
        let logger = ActivityLogger(clock: FixedClock(iso("2026-06-20T08:00:00Z")),
                                    activityLog: ActivityLog(dao: dao), scheduler: InlineLogScheduler())
        let useCase = CaptureLocationUseCase(locationProvider: FakeLocationProvider(provider),
                                             checkRepository: repo, activityLogger: logger)
        return await useCase(50)
    }

    func test_matched_fix_writes_location_info_line() async {
        let dao = CapturingDao()
        let r = await run(provider: .success(ucLocationSample(accuracyMeters: 12.7)),
                          match: .success(ucMatch(.matched, "Unidade P80")), dao: dao)
        guard case .matched = r else { return XCTFail("expected matched, got \(r)") }
        let row = dao.rows.last!
        XCTAssertEqual(row.kind, "LOCATION")
        XCTAssertEqual(row.severity, "INFO")
        XCTAssertEqual(row.actor, "SYS")
        XCTAssertEqual(row.description, "Location fixed (±12m) → Unidade P80.")
        XCTAssertEqual(row.location, "Unidade P80")
    }

    func test_accuracy_too_low_writes_location_warning_line() async {
        let dao = CapturingDao()
        _ = await run(provider: .success(ucLocationSample(accuracyMeters: 80.4)),
                      match: .success(ucMatch(.accuracyTooLow, nil)), dao: dao)
        let row = dao.rows.last!
        XCTAssertEqual(row.kind, "LOCATION")
        XCTAssertEqual(row.severity, "WARNING")
        XCTAssertEqual(row.description, "Location accuracy too low (±80m).")
    }

    func test_logging_failure_never_breaks_capture() async {
        let dao = CapturingDao(throwOnInsert: true)
        let r = await run(provider: .success(ucLocationSample(accuracyMeters: 12.7)),
                          match: .success(ucMatch(.matched, "Unidade P80")), dao: dao)
        guard case .matched = r else { return XCTFail("expected matched, got \(r)") }
        XCTAssertEqual(dao.rows.count, 0)
    }

    func test_successPassesExactSampleToMatcherAndUsesNilSeed() async {
        let sample = ucLocationSample(
            lat: 1.234,
            lon: 2.345,
            accuracyMeters: 12.5
        )
        let provider = FakeLocationProvider(.success(sample))
        let repository = FakeCheckRepository()
        repository.matchLocationResult = .success(ucMatch(.matched, "Unidade P80"))
        let sut = CaptureLocationUseCase(
            locationProvider: provider,
            checkRepository: repository,
            activityLogger: NoopActivityLogger()
        )

        _ = await sut(50)

        XCTAssertEqual(
            repository.lastMatchLocationCall,
            FakeCheckRepository.MatchLocationCall(
                latitude: sample.latitude,
                longitude: sample.longitude,
                accuracyMeters: sample.horizontalAccuracyMeters
            )
        )
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertNil(provider.lastSeed)
    }

    func test_concurrentRequestsWithSameAccuracyShareOneCapture() async {
        let expected = LocationCaptureResult.matched(ucMatch(.matched, "Escritório Principal"))
        let base = SlowCountingCapture(result: expected)
        let sut = CoalescingLocationCapture(base: base)

        async let first = sut(30)
        async let second = sut(30)
        let results = await [first, second]
        let count = await base.callCount

        XCTAssertEqual(results, [expected, expected])
        XCTAssertEqual(count, 1)
    }

    func test_concurrentRequestsWithDifferentAccuracyRemainIndependent() async {
        let expected = LocationCaptureResult.matched(ucMatch(.matched, "Escritório Principal"))
        let base = SlowCountingCapture(result: expected)
        let sut = CoalescingLocationCapture(base: base)

        async let first = sut(30)
        async let second = sut(50)
        _ = await [first, second]
        let count = await base.callCount

        XCTAssertEqual(count, 2)
    }

    func test_cancellingOneCoalescedConsumerDoesNotCancelTheOther() async {
        let expected = LocationCaptureResult.matched(
            ucMatch(.matched, "Escritório Principal")
        )
        let base = GatedCapture(result: expected)
        let sut = CoalescingLocationCapture(base: base)
        let first = Task { await sut(30) }
        await waitUntil { await base.callCount == 1 }
        let second = Task { await sut(30) }
        await waitUntil { (await sut.waiterCountsForTest)[30] == 2 }

        first.cancel()
        let firstResult = await first.value
        let callsBeforeRelease = await base.callCount
        XCTAssertEqual(firstResult, .timeout)
        XCTAssertEqual(callsBeforeRelease, 1)

        await base.release()
        let secondResult = await second.value
        XCTAssertEqual(secondResult, expected)
    }

    func test_cancellingLastCoalescedConsumerCancelsBaseCapture() async {
        let base = CancellationAwareCapture()
        let sut = CoalescingLocationCapture(base: base)
        let consumer = Task { await sut(30) }
        await waitUntil { await base.callCount == 1 }
        await waitUntil { (await sut.waiterCountsForTest)[30] == 1 }

        consumer.cancel()
        let result = await consumer.value
        await waitUntil { await base.cancellationCount == 1 }
        let callCount = await base.callCount
        let cancellationCount = await base.cancellationCount

        XCTAssertEqual(result, .timeout)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(cancellationCount, 1)
    }

    func test_typedProviderCancellationNeverCallsMatcher() async {
        let provider = FakeLocationProvider(.failure(.cancelled(.taskCancelled)))
        let repository = FakeCheckRepository()
        repository.matchLocationResult = .success(ucMatch(.matched, "Unidade P80"))
        let sut = CaptureLocationUseCase(
            locationProvider: provider,
            checkRepository: repository,
            activityLogger: NoopActivityLogger()
        )

        let result = await sut(50)

        XCTAssertEqual(result, .timeout)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertNil(provider.lastSeed)
    }

    func test_taskCancelledAfterProviderResultNeverCallsMatcher() async {
        let provider = GatedLocationProvider(
            result: .success(ucLocationSample())
        )
        let repository = FakeCheckRepository()
        repository.matchLocationResult = .success(ucMatch(.matched, "Unidade P80"))
        let sut = CaptureLocationUseCase(
            locationProvider: provider,
            checkRepository: repository,
            activityLogger: NoopActivityLogger()
        )
        let task = Task { await sut(50) }
        await waitUntil { await provider.callCount == 1 }

        task.cancel()
        await provider.release()
        let result = await task.value

        XCTAssertEqual(result, .timeout)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
    }

    func test_cancelledAutomaticEvaluationNeverReachesDecisionOrSubmit() async {
        let capture = GatedCapture(
            result: .matched(ucMatch(.matched, "Unidade P80"))
        )
        let repository = FakeCheckRepository()
        let queue = FakeOfflineQueue()
        let sut = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: FixedClock(iso("2026-06-20T08:00:00Z")),
            activityLogger: NoopActivityLogger()
        )
        let task = Task {
            await sut(
                chave: "STSM",
                userProjects: UserProjects(projects: ["P80"], activeProject: "P80"),
                currentState: nil,
                mixedZoneIntervalMinutes: 15,
                accuracyThresholdMeters: 50
            )
        }
        await waitUntil { await capture.callCount == 1 }

        task.cancel()
        await capture.release()
        let result = await task.value

        XCTAssertEqual(result, .locationTimeout)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
    }
}
