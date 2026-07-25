import Foundation
import XCTest
@testable import Checking

final class BGTaskAppRefreshSchedulerTests: XCTestCase {
    private final class MutableNow: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) { self.value = value }
        func get() -> Date { lock.withLock { value } }
        func set(_ value: Date) { lock.withLock { self.value = value } }
    }

    private final class SubmittedDates: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Date] = []

        func append(_ value: Date) { lock.withLock { values.append(value) } }
        var all: [Date] { lock.withLock { values } }
    }

    private func makeDefaults() -> (suite: String, defaults: UserDefaults) {
        let suite = "bg_refresh_scheduler_\(UUID().uuidString)"
        return (suite, UserDefaults(suiteName: suite)!)
    }

    func test_regularRefreshUsesFifteenMinutes() {
        let storage = makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
        let now = MutableNow(iso("2026-06-18T12:00:00Z"))
        let submitted = SubmittedDates()
        let sut = BGTaskAppRefreshScheduler(
            defaults: storage.defaults,
            now: { now.get() },
            submitRequest: {
                submitted.append($0)
                return nil
            })

        sut.scheduleRegularRefresh()

        XCTAssertEqual(submitted.all, [now.get().addingTimeInterval(15 * 60)])
    }

    func test_threeMinuteRetryIsPersistedAndNotOverwrittenByRegularReschedule() {
        let storage = makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
        let current = iso("2026-06-18T12:00:00Z")
        let now = MutableNow(current)
        let submitted = SubmittedDates()
        let sut = BGTaskAppRefreshScheduler(
            defaults: storage.defaults,
            now: { now.get() },
            submitRequest: {
                submitted.append($0)
                return nil
            })
        let retry = current.addingTimeInterval(3 * 60)

        sut.scheduleAccuracyRetry(at: retry)
        sut.scheduleRegularRefresh()

        XCTAssertEqual(submitted.all, [retry, retry])
        XCTAssertNotNil(
            storage.defaults.object(
                forKey: BGTaskAppRefreshScheduler.accuracyRetryDeadlineDefaultsKey))
    }

    func test_triggerIsTimerBeforeRetryDeadlineAndAccuracyRetryWhenDue() {
        let storage = makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
        let current = iso("2026-06-18T12:00:00Z")
        let now = MutableNow(current)
        let sut = BGTaskAppRefreshScheduler(
            defaults: storage.defaults,
            now: { now.get() },
            submitRequest: { _ in nil })
        let retry = current.addingTimeInterval(3 * 60)
        sut.scheduleAccuracyRetry(at: retry)

        XCTAssertEqual(sut.triggerForPendingRefresh(), .timer)

        now.set(retry)
        XCTAssertEqual(sut.triggerForPendingRefresh(), .accuracyRetry)
    }

    func test_clearRemovesRetryDeadlineAndSchedulesRegularRefresh() {
        let storage = makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
        let current = iso("2026-06-18T12:00:00Z")
        let now = MutableNow(current)
        let submitted = SubmittedDates()
        let sut = BGTaskAppRefreshScheduler(
            defaults: storage.defaults,
            now: { now.get() },
            submitRequest: {
                submitted.append($0)
                return nil
            })
        sut.scheduleAccuracyRetry(at: current.addingTimeInterval(3 * 60))

        sut.clearAccuracyRetryDeadlineAndScheduleRegular()

        XCTAssertNil(
            storage.defaults.object(
                forKey: BGTaskAppRefreshScheduler.accuracyRetryDeadlineDefaultsKey))
        XCTAssertEqual(submitted.all.last, current.addingTimeInterval(15 * 60))
        XCTAssertEqual(sut.triggerForPendingRefresh(), .timer)
    }

    func test_retryLaterThanFifteenMinutesKeepsRegularDeadline() {
        let storage = makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
        let current = iso("2026-06-18T12:00:00Z")
        let now = MutableNow(current)
        let submitted = SubmittedDates()
        let sut = BGTaskAppRefreshScheduler(
            defaults: storage.defaults,
            now: { now.get() },
            submitRequest: {
                submitted.append($0)
                return nil
            })

        sut.scheduleAccuracyRetry(at: current.addingTimeInterval(30 * 60))

        XCTAssertEqual(submitted.all, [current.addingTimeInterval(15 * 60)])
    }

    func test_sharedRequestUsesMinimumOfAccuracyPauseTransitionAndGrace() {
        let storage = makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
        let current = iso("2026-06-18T12:00:00Z")
        let now = MutableNow(current)
        let submitted = SubmittedDates()
        let sut = BGTaskAppRefreshScheduler(
            defaults: storage.defaults,
            now: { now.get() },
            submitRequest: {
                submitted.append($0)
                return nil
            })
        let accuracy = current.addingTimeInterval(180)
        let transition = current.addingTimeInterval(60)
        let grace = current.addingTimeInterval(10)

        sut.scheduleAccuracyRetry(at: accuracy)
        sut.schedulePauseTransition(at: transition)
        sut.schedulePauseActivation(at: grace)
        sut.scheduleRegularRefresh()

        XCTAssertEqual(submitted.all, [accuracy, transition, grace, grace])
    }

    func test_duePauseTransitionHasPriority_thenDueGrace_thenAccuracy() {
        let storage = makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
        let current = iso("2026-06-18T12:00:00Z")
        let now = MutableNow(current)
        let sut = BGTaskAppRefreshScheduler(
            defaults: storage.defaults,
            now: { now.get() },
            submitRequest: { _ in nil })

        sut.scheduleAccuracyRetry(at: current)
        sut.schedulePauseActivation(at: current)
        sut.schedulePauseTransition(at: current)
        XCTAssertEqual(sut.triggerForPendingRefresh(), .pauseTransition)

        sut.clearPauseTransitionDeadlineAndScheduleRegular()
        XCTAssertEqual(sut.triggerForPendingRefresh(), .pauseActivation)

        sut.clearPauseActivationDeadlineAndScheduleRegular()
        XCTAssertEqual(sut.triggerForPendingRefresh(), .accuracyRetry)
    }

    func test_clearingPauseGracePreservesAccuracyAndRawTransitionDeadlines() {
        let storage = makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
        let current = iso("2026-06-18T12:00:00Z")
        let now = MutableNow(current)
        let submitted = SubmittedDates()
        let sut = BGTaskAppRefreshScheduler(
            defaults: storage.defaults,
            now: { now.get() },
            submitRequest: {
                submitted.append($0)
                return nil
            })
        let transition = current.addingTimeInterval(60)
        sut.scheduleAccuracyRetry(at: current.addingTimeInterval(180))
        sut.schedulePauseTransition(at: transition)
        sut.schedulePauseActivation(at: current.addingTimeInterval(10))

        sut.clearPauseActivationDeadlineAndScheduleRegular()

        XCTAssertNil(
            storage.defaults.object(
                forKey: BGTaskAppRefreshScheduler.pauseActivationDeadlineDefaultsKey))
        XCTAssertNotNil(
            storage.defaults.object(
                forKey: BGTaskAppRefreshScheduler.accuracyRetryDeadlineDefaultsKey))
        XCTAssertNotNil(
            storage.defaults.object(
                forKey: BGTaskAppRefreshScheduler.pauseTransitionDeadlineDefaultsKey))
        XCTAssertEqual(submitted.all.last, transition)
    }
}
