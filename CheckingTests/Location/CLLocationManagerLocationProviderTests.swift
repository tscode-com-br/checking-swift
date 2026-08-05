import CoreLocation
import XCTest
@testable import Checking

final class CaptureSessionStateTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func sample(
        accuracy: Double,
        capturedAt: Date? = nil,
        latitude: Double = 1,
        longitude: Double = 2
    ) -> LocationSample {
        LocationSample(
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracyMeters: accuracy,
            capturedAt: capturedAt ?? now,
            source: .standardCapture
        )
    }

    private func state(
        behavior: LocationCaptureBehavior = .freshnessValidated,
        threshold: Int = 50
    ) -> CaptureSessionState {
        CaptureSessionState(
            behavior: behavior,
            accuracyThresholdMeters: threshold,
            captureStartedAt: now,
            samplePolicy: .candidateTrial
        )
    }

    func test_candidateUsableSeedFinishesImmediately() {
        let seed = sample(accuracy: 10)
        var sut = state()

        XCTAssertEqual(
            sut.admit(seed: seed, now: now),
            .finish(.success(seed))
        )
        XCTAssertTrue(sut.isFinished)
    }

    func test_candidateCoarseSeedStartsAndBecomesBest() {
        let seed = sample(accuracy: 80)
        var sut = state()

        XCTAssertEqual(sut.admit(seed: seed, now: now), .start)
        XCTAssertEqual(sut.best, seed)
        XCTAssertFalse(sut.isFinished)
    }

    func test_candidateStaleFutureAndInvalidSeedsAreIgnored() {
        let seeds = [
            sample(accuracy: 1, capturedAt: now.addingTimeInterval(-10.001)),
            sample(accuracy: 1, capturedAt: now.addingTimeInterval(2.001)),
            sample(accuracy: 1, latitude: 91)
        ]

        for seed in seeds {
            var sut = state()
            XCTAssertEqual(sut.admit(seed: seed, now: now), .start)
            XCTAssertNil(sut.best)
            XCTAssertFalse(sut.isFinished)
        }
    }

    func test_callbackExactlyAtSessionWindowBoundaryIsAccepted() {
        let candidate = sample(
            accuracy: 10,
            capturedAt: now.addingTimeInterval(-2)
        )
        var sut = state()
        _ = sut.admit(seed: nil, now: now)

        XCTAssertEqual(
            sut.receive([candidate], now: now),
            .finish(.success(candidate))
        )
    }

    func test_callbackOneMillisecondBeforeSessionWindowIsRejected() {
        let cached = sample(
            accuracy: 1,
            capturedAt: now.addingTimeInterval(-2.001)
        )
        var sut = state()
        _ = sut.admit(seed: nil, now: now)

        XCTAssertEqual(sut.receive([cached], now: now), .keepWaiting)
        XCTAssertNil(sut.best)
    }

    func test_oldPreciseAndNewCoarseBatchKeepsOnlyNewCandidate() {
        let cachedPrecise = sample(
            accuracy: 1,
            capturedAt: now.addingTimeInterval(-3)
        )
        let currentCoarse = sample(
            accuracy: 500,
            capturedAt: now.addingTimeInterval(-1)
        )
        var sut = state(threshold: 50)
        _ = sut.admit(seed: nil, now: now)

        XCTAssertEqual(
            sut.receive([cachedPrecise, currentCoarse], now: now),
            .keepWaiting
        )
        XCTAssertEqual(sut.best, currentCoarse)
    }

    func test_allFreshBatchChoosesBestAccuracyRegardlessOfOrder() {
        let coarse = sample(accuracy: 40, capturedAt: now.addingTimeInterval(-1))
        let best = sample(accuracy: 20, capturedAt: now)
        let middle = sample(accuracy: 30, capturedAt: now.addingTimeInterval(-0.5))

        for batch in [[coarse, best, middle], [middle, best, coarse]] {
            var sut = state(threshold: 5)
            _ = sut.admit(seed: nil, now: now)

            XCTAssertEqual(sut.receive(batch, now: now), .keepWaiting)
            XCTAssertEqual(sut.best, best)
        }
    }

    func test_equalAccuracyUsesNewestTimestamp() {
        let older = sample(accuracy: 20, capturedAt: now.addingTimeInterval(-1))
        let newer = sample(accuracy: 20, capturedAt: now)
        var sut = state(threshold: 5)
        _ = sut.admit(seed: nil, now: now)

        XCTAssertEqual(sut.receive([newer, older], now: now), .keepWaiting)
        XCTAssertEqual(sut.best, newer)
    }

    func test_accuracyExactlyAtThresholdFinishes() {
        let candidate = sample(accuracy: 50)
        var sut = state(threshold: 50)
        _ = sut.admit(seed: nil, now: now)

        XCTAssertEqual(
            sut.receive([candidate], now: now),
            .finish(.success(candidate))
        )
    }

    func test_timeoutReturnsFreshBestPartial() {
        let seed = sample(accuracy: 80)
        var sut = state()
        _ = sut.admit(seed: seed, now: now)

        XCTAssertEqual(
            sut.timeout(now: now.addingTimeInterval(5)),
            .finish(.success(seed))
        )
    }

    func test_timeoutRejectsBestThatBecameStale() {
        let seed = sample(accuracy: 80)
        var sut = state()
        _ = sut.admit(seed: seed, now: now)

        XCTAssertEqual(
            sut.timeout(now: now.addingTimeInterval(10.001)),
            .finish(.failure(.timeout))
        )
    }

    func test_newFreshCoarseCallbackReplacesMorePreciseBestThatBecameStale() {
        let oldBest = sample(accuracy: 80)
        let callbackTime = now.addingTimeInterval(10.5)
        let freshCoarse = sample(
            accuracy: 100,
            capturedAt: callbackTime
        )
        var sut = state()
        _ = sut.admit(seed: oldBest, now: now)

        XCTAssertEqual(
            sut.receive([freshCoarse], now: callbackTime),
            .keepWaiting
        )
        XCTAssertEqual(sut.best, freshCoarse)
        XCTAssertEqual(
            sut.timeout(now: callbackTime),
            .finish(.success(freshCoarse))
        )
    }

    func test_timeoutWithoutBestIsTypedTimeout() {
        var sut = state()
        _ = sut.admit(seed: nil, now: now)

        XCTAssertEqual(
            sut.timeout(now: now),
            .finish(.failure(.timeout))
        )
    }

    func test_cancelWithBestDiscardsConsumableSample() {
        var sut = state()
        _ = sut.admit(seed: sample(accuracy: 80), now: now)

        XCTAssertEqual(
            sut.cancel(.taskCancelled),
            .finish(.failure(.cancelled(.taskCancelled)))
        )
    }

    func test_cancelWithoutBestIsTypedCancellation() {
        var sut = state()
        _ = sut.admit(seed: nil, now: now)

        XCTAssertEqual(
            sut.cancel(.bgTaskExpired),
            .finish(.failure(.cancelled(.bgTaskExpired)))
        )
    }

    func test_permissionFailureWinsEvenWhenBestExists() {
        var sut = state()
        _ = sut.admit(seed: sample(accuracy: 80), now: now)

        XCTAssertEqual(
            sut.fail(.permissionDenied),
            .finish(.failure(.permissionDenied))
        )
    }

    func test_locationUnknownKeepsWaiting() {
        let seed = sample(accuracy: 80)
        var sut = state()
        _ = sut.admit(seed: seed, now: now)

        XCTAssertEqual(sut.locationUnknown(), .keepWaiting)
        XCTAssertEqual(sut.best, seed)
        XCTAssertFalse(sut.isFinished)
    }

    func test_callbackThenTimeoutKeepsFirstTerminal() {
        let candidate = sample(accuracy: 10)
        var sut = state()
        _ = sut.admit(seed: nil, now: now)

        XCTAssertEqual(
            sut.receive([candidate], now: now),
            .finish(.success(candidate))
        )
        XCTAssertEqual(sut.timeout(now: now), .ignoredAfterFinish)
    }

    func test_timeoutThenCallbackKeepsFirstTerminal() {
        var sut = state()
        _ = sut.admit(seed: nil, now: now)

        XCTAssertEqual(
            sut.timeout(now: now),
            .finish(.failure(.timeout))
        )
        XCTAssertEqual(
            sut.receive([sample(accuracy: 1)], now: now),
            .ignoredAfterFinish
        )
    }

    func test_finishThenCancelKeepsFirstTerminal() {
        let seed = sample(accuracy: 10)
        var sut = state()
        _ = sut.admit(seed: seed, now: now)

        XCTAssertEqual(sut.cancel(.taskCancelled), .ignoredAfterFinish)
    }

    func test_legacyIgnoresSeedAndDoesNotApplyFreshness() {
        let seed = sample(accuracy: 1)
        let oldCallback = sample(
            accuracy: 10,
            capturedAt: now.addingTimeInterval(-3_600)
        )
        var sut = state(behavior: .legacyCompatible)

        XCTAssertEqual(sut.admit(seed: seed, now: now), .start)
        XCTAssertNil(sut.best)
        XCTAssertEqual(
            sut.receive([oldCallback], now: now),
            .finish(.success(oldCallback))
        )
    }

    func test_legacyPreservesLastLocationCallbackSelection() {
        let firstPrecise = sample(accuracy: 5)
        let lastCoarse = sample(accuracy: 100)
        var sut = state(behavior: .legacyCompatible, threshold: 50)
        _ = sut.admit(seed: nil, now: now)

        XCTAssertEqual(
            sut.receive([firstPrecise, lastCoarse], now: now),
            .keepWaiting
        )
        XCTAssertEqual(sut.best, lastCoarse)
    }
}

/// Compatibilidade da comparação pura usada pelo pipeline legado.
final class CLLocationManagerLocationProviderComparisonTests: XCTestCase {
    private func fix(accuracy: CLLocationAccuracy, secondsFromNow: TimeInterval = 0) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 0,
            timestamp: Date(timeIntervalSinceNow: secondsFromNow)
        )
    }

    func test_isBetter_noCurrentFix_alwaysTrue() {
        XCTAssertTrue(CLLocationManagerLocationProvider.isBetter(fix(accuracy: 100), than: nil))
    }

    func test_isBetter_lowerAccuracyWins() {
        XCTAssertTrue(
            CLLocationManagerLocationProvider.isBetter(
                fix(accuracy: 10),
                than: fix(accuracy: 50)
            )
        )
    }

    func test_isBetter_higherAccuracyLoses() {
        XCTAssertFalse(
            CLLocationManagerLocationProvider.isBetter(
                fix(accuracy: 50),
                than: fix(accuracy: 10)
            )
        )
    }

    func test_isBetter_tieAccuracy_newerTimestampWins() {
        XCTAssertTrue(
            CLLocationManagerLocationProvider.isBetter(
                fix(accuracy: 20),
                than: fix(accuracy: 20, secondsFromNow: -10)
            )
        )
    }

    func test_isBetter_tieAccuracy_olderTimestampLoses() {
        XCTAssertFalse(
            CLLocationManagerLocationProvider.isBetter(
                fix(accuracy: 20, secondsFromNow: -10),
                than: fix(accuracy: 20)
            )
        )
    }

    func test_isBetter_invalidCandidateAccuracy_alwaysFalse() {
        let current = fix(accuracy: 999)
        XCTAssertFalse(
            CLLocationManagerLocationProvider.isBetter(fix(accuracy: -1), than: current)
        )
        XCTAssertFalse(
            CLLocationManagerLocationProvider.isBetter(fix(accuracy: .infinity), than: current)
        )
        XCTAssertFalse(
            CLLocationManagerLocationProvider.isBetter(fix(accuracy: .nan), than: current)
        )
    }

    func test_isBetter_validCandidate_invalidCurrent_alwaysTrue() {
        XCTAssertTrue(
            CLLocationManagerLocationProvider.isBetter(
                fix(accuracy: 500),
                than: fix(accuracy: -1)
            )
        )
    }

    func test_isBetter_bothInvalid_false() {
        XCTAssertFalse(
            CLLocationManagerLocationProvider.isBetter(
                fix(accuracy: .nan),
                than: fix(accuracy: -1)
            )
        )
    }

    func test_isValidAccuracy_negativeIsInvalid() {
        XCTAssertFalse(CLLocationManagerLocationProvider.isValidAccuracy(-1))
    }

    func test_isValidAccuracy_nanAndInfiniteAreInvalid() {
        XCTAssertFalse(CLLocationManagerLocationProvider.isValidAccuracy(.nan))
        XCTAssertFalse(CLLocationManagerLocationProvider.isValidAccuracy(.infinity))
    }

    func test_isValidAccuracy_zeroAndPositiveAreValid() {
        XCTAssertTrue(CLLocationManagerLocationProvider.isValidAccuracy(0))
        XCTAssertTrue(CLLocationManagerLocationProvider.isValidAccuracy(30))
    }

    func test_coreLocationErrorClassifierRecognizesNSErrorDenied() {
        let error = NSError(
            domain: kCLErrorDomain,
            code: CLError.Code.denied.rawValue
        )

        XCTAssertEqual(CoreLocationErrorClassifier.classify(error), .denied)
    }

    func test_coreLocationErrorClassifierRecognizesNSErrorLocationUnknown() {
        let error = NSError(
            domain: kCLErrorDomain,
            code: CLError.Code.locationUnknown.rawValue
        )

        XCTAssertEqual(
            CoreLocationErrorClassifier.classify(error),
            .locationUnknown
        )
    }

    func test_coreLocationErrorClassifierRejectsWrongDomainAndOtherCodes() {
        let wrongDomain = NSError(
            domain: "sanitized.test.domain",
            code: CLError.Code.denied.rawValue
        )
        let otherCoreLocationCode = NSError(
            domain: kCLErrorDomain,
            code: CLError.Code.network.rawValue
        )

        XCTAssertEqual(CoreLocationErrorClassifier.classify(wrongDomain), .other)
        XCTAssertEqual(
            CoreLocationErrorClassifier.classify(otherCoreLocationCode),
            .other
        )
    }
}

@MainActor
final class CLLocationManagerLocationProviderSessionTests: XCTestCase {
    private final class FakeDriver: LocationUpdateDriving {
        var authorization: LocationUpdateAuthorization
        private(set) var startCount = 0
        private(set) var stopCount = 0
        var synchronousLocations: [LocationSample]?
        private var onLocations: (@MainActor @Sendable ([LocationSample]) -> Void)?
        private var onFailure: (@MainActor @Sendable (LocationUpdateFailure) -> Void)?

        init(authorization: LocationUpdateAuthorization = .allowed) {
            self.authorization = authorization
        }

        func start(
            onLocations: @escaping @MainActor @Sendable ([LocationSample]) -> Void,
            onFailure: @escaping @MainActor @Sendable (LocationUpdateFailure) -> Void
        ) {
            startCount += 1
            self.onLocations = onLocations
            self.onFailure = onFailure
            if let synchronousLocations {
                onLocations(synchronousLocations)
            }
        }

        func stop() {
            stopCount += 1
            onLocations = nil
            onFailure = nil
        }

        func send(_ samples: [LocationSample]) {
            onLocations?(samples)
        }

        func fail(_ failure: LocationUpdateFailure) {
            onFailure?(failure)
        }
    }

    private final class FakeTimeoutToken: CaptureTimeoutCancellable {
        private(set) var cancelCount = 0
        private var operation: (@MainActor @Sendable () -> Void)?

        init(operation: @escaping @MainActor @Sendable () -> Void) {
            self.operation = operation
        }

        func fire() {
            guard let operation else { return }
            self.operation = nil
            operation()
        }

        func cancel() {
            cancelCount += 1
            operation = nil
        }
    }

    private final class FakeTimeoutScheduler: CaptureTimeoutScheduling {
        private(set) var delays: [TimeInterval] = []
        private(set) var tokens: [FakeTimeoutToken] = []

        func schedule(
            after delay: TimeInterval,
            operation: @escaping @MainActor @Sendable () -> Void
        ) -> any CaptureTimeoutCancellable {
            let token = FakeTimeoutToken(operation: operation)
            delays.append(delay)
            tokens.append(token)
            return token
        }

        func fireLatest() {
            tokens.last?.fire()
        }
    }

    private final class DriverFactory {
        private var drivers: [FakeDriver]
        private(set) var callCount = 0

        init(_ drivers: [FakeDriver]) {
            self.drivers = drivers
        }

        func make() -> any LocationUpdateDriving {
            let index = min(callCount, drivers.count - 1)
            callCount += 1
            return drivers[index]
        }
    }

    private final class MutableDate: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        func now() -> Date {
            lock.withLock { value }
        }

        func set(_ value: Date) {
            lock.withLock { self.value = value }
        }
    }

    private let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func sample(
        accuracy: Double,
        capturedAt: Date? = nil,
        source: LocationSampleSource = .standardCapture
    ) -> LocationSample {
        LocationSample(
            latitude: 1,
            longitude: 2,
            horizontalAccuracyMeters: accuracy,
            capturedAt: capturedAt ?? now,
            source: source
        )
    }

    private func provider(
        factory: DriverFactory,
        scheduler: FakeTimeoutScheduler,
        behavior: LocationCaptureBehavior = .freshnessValidated
    ) -> CLLocationManagerLocationProvider {
        CLLocationManagerLocationProvider(
            behavior: behavior,
            samplePolicy: .candidateTrial,
            now: { [now] in now },
            makeDriver: { factory.make() },
            makeTimeoutScheduler: { scheduler }
        )
    }

    private func waitUntilStarted(_ driver: FakeDriver) async {
        for _ in 0 ..< 100 where driver.startCount == 0 {
            await Task.yield()
        }
    }

    func test_usableSeedDoesNotCreateOrStartDriverOrTimer() async {
        let driver = FakeDriver()
        let factory = DriverFactory([driver])
        let scheduler = FakeTimeoutScheduler()
        let sut = provider(factory: factory, scheduler: scheduler)
        let seed = sample(
            accuracy: 10,
            source: .significantChange
        )

        let result = await sut.capture(50, seed: seed)

        XCTAssertEqual(result, .success(seed))
        XCTAssertEqual(factory.callCount, 0)
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertTrue(scheduler.delays.isEmpty)
    }

    func test_coarseSeedStartsAndRecentBestIsReturnedAtFifteenSecondTimeout() async {
        let driver = FakeDriver()
        let factory = DriverFactory([driver])
        let scheduler = FakeTimeoutScheduler()
        let clock = MutableDate(now)
        let sut = CLLocationManagerLocationProvider(
            behavior: .freshnessValidated,
            samplePolicy: .candidateTrial,
            now: { clock.now() },
            makeDriver: { factory.make() },
            makeTimeoutScheduler: { scheduler }
        )
        let seed = sample(
            accuracy: 80,
            source: .significantChange
        )
        let task = Task { await sut.capture(50, seed: seed) }
        await waitUntilStarted(driver)

        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(scheduler.delays, [15])
        let timeoutAt = now.addingTimeInterval(15)
        let recentBest = sample(
            accuracy: 70,
            capturedAt: now.addingTimeInterval(8)
        )
        clock.set(timeoutAt)
        driver.send([recentBest])
        scheduler.fireLatest()
        let result = await task.value

        XCTAssertEqual(result, .success(recentBest))
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(scheduler.tokens.first?.cancelCount, 1)
    }

    func test_staleSeedIsIgnoredAndFreshCallbackFinishes() async {
        let driver = FakeDriver()
        let scheduler = FakeTimeoutScheduler()
        let sut = provider(factory: DriverFactory([driver]), scheduler: scheduler)
        let stale = sample(
            accuracy: 1,
            capturedAt: now.addingTimeInterval(-11)
        )
        let fresh = sample(accuracy: 10)
        let task = Task { await sut.capture(50, seed: stale) }
        await waitUntilStarted(driver)

        driver.send([fresh])
        let result = await task.value

        XCTAssertEqual(result, .success(fresh))
        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(driver.stopCount, 1)
    }

    func test_mixedCallbackRejectsCachedPreciseAndKeepsFreshCoarse() async {
        let driver = FakeDriver()
        let scheduler = FakeTimeoutScheduler()
        let sut = provider(factory: DriverFactory([driver]), scheduler: scheduler)
        let cached = sample(
            accuracy: 1,
            capturedAt: now.addingTimeInterval(-3)
        )
        let fresh = sample(
            accuracy: 100,
            capturedAt: now.addingTimeInterval(-1)
        )
        let task = Task { await sut.capture(50, seed: nil) }
        await waitUntilStarted(driver)

        driver.send([cached, fresh])
        XCTAssertEqual(driver.stopCount, 0)
        scheduler.fireLatest()
        let result = await task.value

        XCTAssertEqual(result, .success(fresh))
        XCTAssertEqual(driver.stopCount, 1)
    }

    func test_freshBatchUsesBestFixAndStopsExactlyOnce() async {
        let driver = FakeDriver()
        let scheduler = FakeTimeoutScheduler()
        let sut = provider(factory: DriverFactory([driver]), scheduler: scheduler)
        let best = sample(accuracy: 20)
        let task = Task { await sut.capture(25, seed: nil) }
        await waitUntilStarted(driver)

        driver.send([
            sample(accuracy: 40, capturedAt: now.addingTimeInterval(-1)),
            best,
            sample(accuracy: 30)
        ])
        let result = await task.value

        XCTAssertEqual(result, .success(best))
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(scheduler.tokens.first?.cancelCount, 1)
        scheduler.fireLatest()
        driver.send([sample(accuracy: 1)])
        XCTAssertEqual(driver.stopCount, 1)
    }

    func test_timeoutWithoutBestStopsAndReturnsTypedTimeout() async {
        let driver = FakeDriver()
        let scheduler = FakeTimeoutScheduler()
        let sut = provider(factory: DriverFactory([driver]), scheduler: scheduler)
        let task = Task { await sut.capture(50, seed: nil) }
        await waitUntilStarted(driver)

        scheduler.fireLatest()
        let result = await task.value

        XCTAssertEqual(result, .failure(.timeout))
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(scheduler.tokens.first?.cancelCount, 1)
    }

    func test_freshCallbackReplacesSeedThatAgedOutDuringSession() async {
        let driver = FakeDriver()
        let factory = DriverFactory([driver])
        let scheduler = FakeTimeoutScheduler()
        let clock = MutableDate(now)
        let sut = CLLocationManagerLocationProvider(
            behavior: .freshnessValidated,
            samplePolicy: .candidateTrial,
            now: { clock.now() },
            makeDriver: { factory.make() },
            makeTimeoutScheduler: { scheduler }
        )
        let oldSeed = sample(accuracy: 80)
        let task = Task { await sut.capture(50, seed: oldSeed) }
        await waitUntilStarted(driver)
        let callbackTime = now.addingTimeInterval(10.5)
        let freshCoarse = sample(
            accuracy: 100,
            capturedAt: callbackTime
        )
        clock.set(callbackTime)

        driver.send([freshCoarse])
        XCTAssertEqual(driver.stopCount, 0)
        scheduler.fireLatest()
        let result = await task.value

        XCTAssertEqual(result, .success(freshCoarse))
        XCTAssertEqual(driver.stopCount, 1)
    }

    func test_cancelWithBestStopsAndNeverReturnsSuccess() async {
        let driver = FakeDriver()
        let scheduler = FakeTimeoutScheduler()
        let sut = provider(factory: DriverFactory([driver]), scheduler: scheduler)
        let task = Task { await sut.capture(50, seed: nil) }
        await waitUntilStarted(driver)
        driver.send([sample(accuracy: 80)])

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .failure(.cancelled(.taskCancelled)))
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(scheduler.tokens.first?.cancelCount, 1)
    }

    func test_cancelWithoutBestStopsAndReturnsTypedCancellation() async {
        let driver = FakeDriver()
        let scheduler = FakeTimeoutScheduler()
        let sut = provider(factory: DriverFactory([driver]), scheduler: scheduler)
        let task = Task { await sut.capture(50, seed: nil) }
        await waitUntilStarted(driver)

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .failure(.cancelled(.taskCancelled)))
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(scheduler.tokens.first?.cancelCount, 1)
    }

    func test_preCancelledTaskDoesNotCreateDriverOrTimer() async {
        let driver = FakeDriver()
        let factory = DriverFactory([driver])
        let scheduler = FakeTimeoutScheduler()
        let sut = provider(factory: factory, scheduler: scheduler)

        let task = Task { await sut.capture(50, seed: nil) }
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .failure(.cancelled(.taskCancelled)))
        XCTAssertEqual(factory.callCount, 0)
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertTrue(scheduler.delays.isEmpty)
    }

    func test_initialDeniedPermissionDoesNotStartDriver() async {
        let driver = FakeDriver(authorization: .permissionDenied)
        let scheduler = FakeTimeoutScheduler()
        let sut = provider(factory: DriverFactory([driver]), scheduler: scheduler)

        let result = await sut.capture(50, seed: nil)

        XCTAssertEqual(result, .failure(.permissionDenied))
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(driver.stopCount, 0)
        XCTAssertTrue(scheduler.delays.isEmpty)
    }

    func test_runtimeDeniedWinsOverBestAndStops() async {
        let driver = FakeDriver()
        let scheduler = FakeTimeoutScheduler()
        let sut = provider(factory: DriverFactory([driver]), scheduler: scheduler)
        let task = Task { await sut.capture(50, seed: nil) }
        await waitUntilStarted(driver)
        driver.send([sample(accuracy: 80)])

        driver.fail(.permissionDenied)
        let result = await task.value

        XCTAssertEqual(result, .failure(.permissionDenied))
        XCTAssertEqual(driver.stopCount, 1)
    }

    func test_locationUnknownContinuesUntilUsefulCallback() async {
        let driver = FakeDriver()
        let scheduler = FakeTimeoutScheduler()
        let sut = provider(factory: DriverFactory([driver]), scheduler: scheduler)
        let candidate = sample(accuracy: 10)
        let task = Task { await sut.capture(50, seed: nil) }
        await waitUntilStarted(driver)

        driver.fail(.locationUnknown)
        XCTAssertEqual(driver.stopCount, 0)
        driver.send([candidate])
        let result = await task.value

        XCTAssertEqual(result, .success(candidate))
        XCTAssertEqual(driver.stopCount, 1)
    }

    func test_synchronousCallbackDuringStartResolvesOnce() async {
        let candidate = sample(accuracy: 10)
        let driver = FakeDriver()
        driver.synchronousLocations = [candidate]
        let scheduler = FakeTimeoutScheduler()
        let sut = provider(factory: DriverFactory([driver]), scheduler: scheduler)

        let result = await sut.capture(50, seed: nil)

        XCTAssertEqual(result, .success(candidate))
        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(scheduler.tokens.first?.cancelCount, 1)
    }

    func test_timeoutThenLateCallbackKeepsSingleTerminalAndStop() async {
        let driver = FakeDriver()
        let scheduler = FakeTimeoutScheduler()
        let sut = provider(factory: DriverFactory([driver]), scheduler: scheduler)
        let task = Task { await sut.capture(50, seed: nil) }
        await waitUntilStarted(driver)

        scheduler.fireLatest()
        let result = await task.value
        XCTAssertEqual(result, .failure(.timeout))
        driver.send([sample(accuracy: 1)])
        driver.fail(.permissionDenied)

        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(scheduler.tokens.first?.cancelCount, 1)
    }

    func test_twoConcurrentSessionsKeepDriversAndResultsIndependent() async {
        let firstDriver = FakeDriver()
        let secondDriver = FakeDriver()
        let factory = DriverFactory([firstDriver, secondDriver])
        let scheduler = FakeTimeoutScheduler()
        let sut = provider(factory: factory, scheduler: scheduler)
        let firstSample = sample(accuracy: 10)
        let secondSample = sample(accuracy: 20)

        let firstTask = Task { await sut.capture(15, seed: nil) }
        await waitUntilStarted(firstDriver)
        let secondTask = Task { await sut.capture(25, seed: nil) }
        await waitUntilStarted(secondDriver)
        firstDriver.send([firstSample])
        secondDriver.send([secondSample])
        let firstResult = await firstTask.value
        let secondResult = await secondTask.value

        XCTAssertEqual(firstResult, .success(firstSample))
        XCTAssertEqual(secondResult, .success(secondSample))
        XCTAssertEqual(factory.callCount, 2)
        XCTAssertEqual(firstDriver.stopCount, 1)
        XCTAssertEqual(secondDriver.stopCount, 1)
    }
}
