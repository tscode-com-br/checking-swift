import Foundation
import XCTest
@testable import Checking

final class SignificantLocationSeedTests: XCTestCase {
    private final class MutableClock: Clock, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        func now() -> Date {
            lock.withLock { value }
        }

        func advance(by interval: TimeInterval) {
            lock.withLock { value = value.addingTimeInterval(interval) }
        }
    }

    private final class AdvancingSeedProvider: LocationProvider, @unchecked Sendable {
        private let lock = NSLock()
        private let clock: MutableClock
        private let advanceBy: TimeInterval
        private var calls = 0
        private var seedValue: LocationSample?

        init(clock: MutableClock, advanceBy: TimeInterval) {
            self.clock = clock
            self.advanceBy = advanceBy
        }

        var callCount: Int { lock.withLock { calls } }
        var lastSeed: LocationSample? { lock.withLock { seedValue } }

        func capture(
            _ accuracyThresholdMeters: Int,
            seed: LocationSample?
        ) async -> LocationCapture {
            lock.withLock {
                calls += 1
                seedValue = seed
            }
            clock.advance(by: advanceBy)
            guard let seed else { return .failure(.unavailable) }
            return .success(seed)
        }
    }

    private final class TriggerRecordingLogger: ActivityLogging, @unchecked Sendable {
        private let lock = NSLock()
        private var recordedTriggers: [String] = []

        var triggers: [String] {
            lock.withLock { recordedTriggers }
        }

        func logTrigger(_ name: String) {
            lock.withLock { recordedTriggers.append(name) }
        }
    }

    private let now = iso("2026-07-31T08:00:00Z")

    override func setUp() {
        super.setUp()
        EvaluationLog.shared.reset()
    }

    private func sample(
        latitude: Double = 1.3,
        longitude: Double = 103.8,
        accuracy: Double = 9,
        capturedAt: Date? = nil,
        source: LocationSampleSource = .significantChange
    ) -> LocationSample {
        LocationSample(
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracyMeters: accuracy,
            capturedAt: capturedAt ?? now,
            source: source
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
        let prefs = FakeAppPreferences()
        prefs.chaveValue = "HR70"
        prefs.userSettingsJsonValue = String(decoding: data, as: UTF8.self)
        return prefs
    }

    private func repository() -> FakeCheckRepository {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(
            LocationOptions(
                items: ["configured-location"],
                accuracyThresholdMeters: 50,
                mixedZoneIntervalMinutes: 15
            )
        )
        repository.getStateResult = .success(ucHistory(.checkOut))
        repository.matchLocationResult = .success(
            ucMatch(.noKnownLocations)
        )
        return repository
    }

    private func orchestrator(
        provider: any LocationProvider,
        repository: FakeCheckRepository,
        pipeline: BackgroundAutomaticEvaluationPipeline,
        clock: any Clock,
        journal: any EvaluationJournaling = NoopEvaluationJournal(),
        logger: any ActivityLogging = NoopActivityLogger(),
        prefs: FakeAppPreferences? = nil
    ) -> BackgroundCheckOrchestrator {
        let capture = CaptureLocationUseCase(
            locationProvider: provider,
            checkRepository: repository,
            activityLogger: logger,
            clock: clock,
            captureBehavior:
                pipeline == .candidate
                    ? .freshnessValidated
                    : .legacyCompatible
        )
        let automatic = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: FakeOfflineQueue(),
            clock: clock,
            activityLogger: logger
        )
        return makeOrchestrator(
            prefs: prefs ?? preferences(),
            checkRepository: repository,
            autoActivities: automatic,
            locationProvider: provider,
            automaticEvaluationPipeline: pipeline,
            clock: clock,
            evaluationJournal: journal,
            activityLogger: logger
        )
    }

    func test_candidateFreshSeedFeedsProviderMatcherAndSanitizedJournal() async throws {
        let seed = sample(
            latitude: 1.23456789,
            longitude: 103.87654321,
            capturedAt: now.addingTimeInterval(-2)
        )
        let provider = FakeLocationProvider(.success(seed))
        let repository = repository()
        let journal = RecordingEvaluationJournal()
        let logger = TriggerRecordingLogger()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            pipeline: .candidate,
            clock: FixedClock(now),
            journal: journal,
            logger: logger
        )

        let completion = await sut.runOnce(
            .significantLocation,
            seedCandidate: seed
        )

        XCTAssertEqual(completion.outcome, .noAction)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(provider.lastSeed, seed)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(
            repository.lastMatchLocationCall,
            .init(
                latitude: seed.latitude,
                longitude: seed.longitude,
                accuracyMeters: seed.horizontalAccuracyMeters
            )
        )
        XCTAssertEqual(logger.triggers, ["SIGNIFICANT_LOCATION"])

        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.begins.count, 1)
        XCTAssertEqual(snapshot.begins.first?.trigger, .significantLocation)
        XCTAssertEqual(snapshot.finishes.count, 1)
        let terminal = try XCTUnwrap(snapshot.finishes.first?.terminal)
        XCTAssertEqual(terminal.locationSource, .seed)
        XCTAssertEqual(terminal.captureReused, true)
        XCTAssertEqual(terminal.accuracyBucket, .zeroTo10Meters)
        XCTAssertEqual(terminal.ageBucket, .oneTo5Seconds)
        let diagnostic = String(reflecting: terminal)
        XCTAssertFalse(diagnostic.contains("1.23456789"))
        XCTAssertFalse(diagnostic.contains("103.87654321"))
    }

    func test_legacyProfileDiscardsSeedAndPreservesAcquirePath() async {
        let seed = sample()
        let freshCapture = sample(
            latitude: 2,
            longitude: 3,
            source: .standardCapture
        )
        let provider = FakeLocationProvider(.success(freshCapture))
        let repository = repository()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            pipeline: .legacy,
            clock: FixedClock(now)
        )

        let completion = await sut.runOnce(
            .significantLocation,
            seedCandidate: seed
        )

        XCTAssertEqual(completion.outcome, .noAction)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertNil(provider.lastSeed)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(
            repository.lastMatchLocationCall?.latitude,
            freshCapture.latitude
        )
    }

    func test_staleOrInvalidSeedRecapturesOnceAndNeverMatchesRejectedReading() async {
        let rejectedSeeds = [
            sample(
                latitude: 10,
                longitude: 20,
                capturedAt: now.addingTimeInterval(-10.001)
            ),
            sample(capturedAt: now.addingTimeInterval(2.001)),
            sample(latitude: .nan, longitude: 30),
        ]

        for rejectedSeed in rejectedSeeds {
            let freshCapture = sample(
                latitude: 4,
                longitude: 5,
                source: .standardCapture
            )
            let provider = FakeLocationProvider(.success(freshCapture))
            let repository = repository()
            let sut = orchestrator(
                provider: provider,
                repository: repository,
                pipeline: .candidate,
                clock: FixedClock(now)
            )

            let completion = await sut.runOnce(
                .significantLocation,
                seedCandidate: rejectedSeed
            )

            XCTAssertEqual(completion.outcome, .noAction)
            XCTAssertEqual(provider.callCount, 1)
            XCTAssertNil(provider.lastSeed)
            XCTAssertEqual(repository.matchLocationCallCount, 1)
            XCTAssertEqual(
                repository.lastMatchLocationCall,
                .init(
                    latitude: freshCapture.latitude,
                    longitude: freshCapture.longitude,
                    accuracyMeters: freshCapture.horizontalAccuracyMeters
                )
            )
        }
    }

    func test_coarseSeedIsForwardedToOneImprovementCapture() async {
        let coarse = sample(accuracy: 500)
        let improved = sample(
            latitude: 2,
            longitude: 4,
            accuracy: 12,
            source: .standardCapture
        )
        let provider = FakeLocationProvider(.success(improved))
        let repository = repository()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            pipeline: .candidate,
            clock: FixedClock(now)
        )

        let completion = await sut.runOnce(
            .significantLocation,
            seedCandidate: coarse
        )

        XCTAssertEqual(completion.outcome, .noAction)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(provider.lastSeed, coarse)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(
            repository.lastMatchLocationCall?.latitude,
            improved.latitude
        )
    }

    func test_seedThatAgesAfterProviderReturnDoesNotMatchOrRecapture() async {
        let clock = MutableClock(now)
        let seed = sample(capturedAt: now)
        let provider = AdvancingSeedProvider(
            clock: clock,
            advanceBy: 10.001
        )
        let repository = repository()
        let journal = RecordingEvaluationJournal()
        let sut = orchestrator(
            provider: provider,
            repository: repository,
            pipeline: .candidate,
            clock: clock,
            journal: journal
        )

        let completion = await sut.runOnce(
            .significantLocation,
            seedCandidate: seed
        )

        XCTAssertEqual(completion.outcome, .staleContext)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(provider.lastSeed, seed)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.finishes.count, 1)
        XCTAssertEqual(
            snapshot.finishes.first?.terminal.outcome,
            .staleContext
        )
        XCTAssertEqual(
            snapshot.finishes.first?.terminal.locationSource,
            .seed
        )
    }

    func test_wrapperNilAndNonSignificantTriggersKeepAcquireIntent() async {
        let autoActivities = SpyAutoActivities()
        let repository = repository()
        let sut = makeOrchestrator(
            prefs: preferences(),
            checkRepository: repository,
            autoActivities: autoActivities,
            automaticEvaluationPipeline: .candidate,
            clock: FixedClock(now)
        )
        let seed = sample()

        _ = await sut.runOnce(.significantLocation)
        _ = await sut.runOnce(.geofence, seedCandidate: seed)
        _ = await sut.runOnce(.foreground, seedCandidate: seed)

        XCTAssertEqual(autoActivities.callCount, 3)
        XCTAssertEqual(
            autoActivities.calls.map(\.locationAttempt),
            [.acquire, .acquire, .acquire]
        )
    }

    func test_legacyProfile_concurrentSecondSignificantWakeKeepsHistoricalDrop() async {
        let prefs = preferences()
        let gate = AsyncGate()
        prefs.chaveGate = gate
        let autoActivities = SpyAutoActivities()
        let repository = repository()
        let sut = makeOrchestrator(
            prefs: prefs,
            checkRepository: repository,
            autoActivities: autoActivities,
            // Divergência iOS por build: candidate drena um pending bounded; legacy conserva o drop e
            // também conserva o descarte histórico da seed.
            automaticEvaluationPipeline: .legacy,
            clock: FixedClock(now)
        )
        let firstSeed = sample(latitude: 1)
        let secondSeed = sample(latitude: 2)

        let firstTask = Task {
            await sut.runOnce(
                .significantLocation,
                seedCandidate: firstSeed
            )
        }
        await waitUntil { prefs.chaveReadStarted }

        let second = await sut.runOnce(
            .significantLocation,
            seedCandidate: secondSeed
        )
        await gate.release()
        let first = await firstTask.value

        XCTAssertTrue(first.admitted)
        XCTAssertEqual(second.outcome, .notAdmitted)
        XCTAssertFalse(second.admitted)
        XCTAssertEqual(autoActivities.callCount, 1)
        XCTAssertEqual(
            autoActivities.calls.first?.locationAttempt,
            .acquire
        )
    }
}
