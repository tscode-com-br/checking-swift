import CoreLocation
import XCTest
@testable import Checking

private final class SignificantWakeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let onAppend: @Sendable () -> Void
    private var recorded: [LocationSample?] = []

    init(onAppend: @escaping @Sendable () -> Void = {}) {
        self.onAppend = onAppend
    }

    func append(_ sample: LocationSample?) {
        lock.withLock { recorded.append(sample) }
        onAppend()
    }

    var values: [LocationSample?] {
        lock.withLock { recorded }
    }
}

private final class SignificantWarningRecorder: ActivityLogging, @unchecked Sendable {
    private let lock = NSLock()
    private let onWarning: @Sendable () -> Void
    private var recorded: [String] = []

    init(onWarning: @escaping @Sendable () -> Void) {
        self.onWarning = onWarning
    }

    func logWarning(_ message: String) {
        lock.withLock { recorded.append(message) }
        onWarning()
    }

    var warnings: [String] {
        lock.withLock { recorded }
    }
}

@MainActor
final class CLLocationManagerSignificantChangeMonitorTests: XCTestCase {
    private let now = iso("2026-07-31T08:00:00Z")

    private func location(
        latitude: Double = 1.3,
        longitude: Double = 103.8,
        accuracy: Double = 12,
        capturedAt: Date? = nil
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: latitude,
                longitude: longitude
            ),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 0,
            timestamp: capturedAt ?? now
        )
    }

    private func monitor(
        recorder: SignificantWakeRecorder,
        activityLogger: any ActivityLogging = NoopActivityLogger(),
        startsImmediately: Bool = false
    ) -> CLLocationManagerSignificantChangeMonitor {
        CLLocationManagerSignificantChangeMonitor(
            activityLogger: activityLogger,
            startsImmediately: startsImmediately,
            clock: FixedClock(now),
            monitoringAvailable: { true },
            startMonitoringAction: { _ in },
            stopMonitoringAction: { _ in },
            onSignificantLocationWake: recorder.append
        )
    }

    func test_delegateIsInstalledImmediatelyAndValidSampleIsTransportedWhenActive() async throws {
        let wake = expectation(description: "delegate wake")
        let recorder = SignificantWakeRecorder(onAppend: wake.fulfill)
        let monitor = monitor(recorder: recorder)

        XCTAssertTrue(monitor.isDelegateActiveForTest)
        let initiallyActive = await monitor.isActive()
        XCTAssertFalse(initiallyActive)

        await monitor.start()
        monitor.locationManager(
            CLLocationManager(),
            didUpdateLocations: [
                location(
                    latitude: 1.234,
                    longitude: 103.456,
                    accuracy: 9,
                    capturedAt: now.addingTimeInterval(-2)
                ),
            ]
        )
        await fulfillment(of: [wake], timeout: 1)

        let activeAfterStart = await monitor.isActive()
        XCTAssertTrue(activeAfterStart)
        let sample = try XCTUnwrap(recorder.values.first ?? nil)
        XCTAssertEqual(sample.latitude, 1.234)
        XCTAssertEqual(sample.longitude, 103.456)
        XCTAssertEqual(sample.horizontalAccuracyMeters, 9)
        XCTAssertEqual(sample.capturedAt, now.addingTimeInterval(-2))
        XCTAssertEqual(sample.source, .significantChange)
        await monitor.stop()
    }

    func test_startsImmediatelyActivatesMonitorWithDelegateInstalled() async {
        let recorder = SignificantWakeRecorder()
        let monitor = monitor(
            recorder: recorder,
            startsImmediately: true
        )

        XCTAssertTrue(monitor.isDelegateActiveForTest)
        let active = await monitor.isActive()
        XCTAssertTrue(active)
        await monitor.stop()
    }

    func test_emptyDelegateBatchIsIgnoredWithoutWake() async {
        let noWake = expectation(description: "empty batch must not wake")
        noWake.isInverted = true
        let recorder = SignificantWakeRecorder(onAppend: noWake.fulfill)
        let monitor = monitor(recorder: recorder)
        await monitor.start()

        monitor.locationManager(
            CLLocationManager(),
            didUpdateLocations: []
        )
        await fulfillment(of: [noWake], timeout: 0.1)

        XCTAssertTrue(recorder.values.isEmpty)
        await monitor.stop()
    }

    func test_nonemptyBatchWithOnlyInvalidOrStaleSamplesStillWakesWithNil() async {
        let recorder = SignificantWakeRecorder()
        let monitor = monitor(recorder: recorder)
        await monitor.start()

        monitor.simulateSignificantLocationsForTest([
            location(accuracy: -1),
            location(capturedAt: now.addingTimeInterval(-10.001)),
            location(latitude: .nan),
        ])

        XCTAssertEqual(recorder.values.count, 1)
        XCTAssertNil(recorder.values[0])
        await monitor.stop()
    }

    func test_batchUsesApprovedComparatorInsteadOfNewestOnly() async throws {
        let recorder = SignificantWakeRecorder()
        let monitor = monitor(recorder: recorder)
        await monitor.start()
        let preciseOlder = location(
            latitude: 1,
            longitude: 2,
            accuracy: 5,
            capturedAt: now.addingTimeInterval(-2)
        )
        let coarseNewer = location(
            latitude: 3,
            longitude: 4,
            accuracy: 500,
            capturedAt: now.addingTimeInterval(-1)
        )

        monitor.simulateSignificantLocationsForTest([
            coarseNewer,
            preciseOlder,
        ])

        let sample = try XCTUnwrap(recorder.values.first ?? nil)
        XCTAssertEqual(sample.horizontalAccuracyMeters, 5)
        XCTAssertEqual(sample.capturedAt, now.addingTimeInterval(-2))
        await monitor.stop()
    }

    func test_callbackAfterStopIsIgnored() async {
        let recorder = SignificantWakeRecorder()
        let monitor = monitor(recorder: recorder)
        await monitor.start()
        await monitor.stop()

        monitor.simulateSignificantLocationsForTest([location()])

        XCTAssertTrue(recorder.values.isEmpty)
        let activeAfterStop = await monitor.isActive()
        XCTAssertFalse(activeAfterStop)
    }

    func test_coreLocationErrorsAreReducedToWhitelistWithoutDescription() {
        let sentinel = "private-error-detail-sentinel"
        let known = NSError(
            domain: kCLErrorDomain,
            code: CLError.network.rawValue,
            userInfo: [NSLocalizedDescriptionKey: sentinel]
        )
        let external = NSError(
            domain: "private.external.domain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: sentinel]
        )

        let knownCategory =
            CLLocationManagerSignificantChangeMonitor
                .sanitizedCoreLocationErrorCategory(known)
        let externalCategory =
            CLLocationManagerSignificantChangeMonitor
                .sanitizedCoreLocationErrorCategory(external)

        XCTAssertEqual(knownCategory, .network)
        XCTAssertEqual(externalCategory, .unknown)
        XCTAssertFalse(knownCategory.rawValue.contains(sentinel))
        XCTAssertFalse(externalCategory.rawValue.contains(sentinel))
    }

    func test_delegateFailureEmitsOnlyGenericActivityWarning() async {
        let warning = expectation(description: "generic warning")
        let logger = SignificantWarningRecorder(onWarning: warning.fulfill)
        let monitor = monitor(
            recorder: SignificantWakeRecorder(),
            activityLogger: logger
        )
        let sentinel = "private-error-detail-sentinel"

        monitor.locationManager(
            CLLocationManager(),
            didFailWithError: NSError(
                domain: kCLErrorDomain,
                code: CLError.network.rawValue,
                userInfo: [NSLocalizedDescriptionKey: sentinel]
            )
        )
        await fulfillment(of: [warning], timeout: 1)

        XCTAssertEqual(
            logger.warnings,
            ["Significant location monitoring failed."]
        )
        XCTAssertFalse(logger.warnings.joined().contains(sentinel))
    }
}
