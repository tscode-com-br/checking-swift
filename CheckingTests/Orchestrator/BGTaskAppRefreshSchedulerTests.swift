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

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private final class PendingRequestProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: Bool
        private var cancellations = 0
        private var submissions: [Date] = []

        init(pending: Bool) { self.pending = pending }

        func cancel() {
            lock.withLock {
                pending = false
                cancellations += 1
            }
        }

        func submit(_ deadline: Date) -> String? {
            lock.withLock {
                guard !pending else { return "BGTaskSchedulerErrorDomain Code=2" }
                pending = true
                submissions.append(deadline)
                return nil
            }
        }

        var cancelCount: Int { lock.withLock { cancellations } }
        var submittedDates: [Date] { lock.withLock { submissions } }
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

    func test_repeatedRegularRefreshIsIdempotentWhileEarlierRequestIsPending() {
        let storage = makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
        let current = iso("2026-06-18T12:00:00Z")
        let probe = PendingRequestProbe(pending: false)
        let sut = BGTaskAppRefreshScheduler(
            defaults: storage.defaults,
            now: { current },
            cancelPendingRequest: { probe.cancel() },
            submitRequest: { probe.submit($0) })

        sut.scheduleRegularRefresh()
        sut.scheduleRegularRefresh()
        sut.clearPauseTransitionDeadlineAndScheduleRegular()

        XCTAssertEqual(probe.cancelCount, 1)
        XCTAssertEqual(probe.submittedDates, [current.addingTimeInterval(15 * 60)])
    }

    func test_newSchedulerInstanceReconfirmsRequestInsteadOfTrustingStaleProcessCache() {
        let storage = makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
        let current = iso("2026-06-18T12:00:00Z")
        let firstProbe = PendingRequestProbe(pending: false)
        let first = BGTaskAppRefreshScheduler(
            defaults: storage.defaults,
            now: { current },
            cancelPendingRequest: { firstProbe.cancel() },
            submitRequest: { firstProbe.submit($0) })
        first.scheduleRegularRefresh()

        let relaunchedProbe = PendingRequestProbe(pending: true)
        let relaunched = BGTaskAppRefreshScheduler(
            defaults: storage.defaults,
            now: { current },
            cancelPendingRequest: { relaunchedProbe.cancel() },
            submitRequest: { relaunchedProbe.submit($0) })
        let error = relaunched.scheduleRegularRefresh()

        XCTAssertNil(error)
        XCTAssertEqual(relaunchedProbe.cancelCount, 1)
        XCTAssertEqual(
            relaunchedProbe.submittedDates,
            [current.addingTimeInterval(15 * 60)])
    }

    func test_existingPlatformRequestIsCancelledBeforeReplacementSubmission() {
        let storage = makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
        let current = iso("2026-06-18T12:00:00Z")
        let probe = PendingRequestProbe(pending: true)
        let sut = BGTaskAppRefreshScheduler(
            defaults: storage.defaults,
            now: { current },
            cancelPendingRequest: { probe.cancel() },
            submitRequest: { probe.submit($0) })

        let error = sut.scheduleRegularRefresh()

        XCTAssertNil(error)
        XCTAssertEqual(probe.cancelCount, 1)
        XCTAssertEqual(probe.submittedDates, [current.addingTimeInterval(15 * 60)])
    }

    func test_failedSubmissionIsReturnedAndRetriedBecauseItIsNotMarkedPending() {
        let storage = makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
        let current = iso("2026-06-18T12:00:00Z")
        let submitted = SubmittedDates()
        let cancellations = LockedCounter()
        let sut = BGTaskAppRefreshScheduler(
            defaults: storage.defaults,
            now: { current },
            cancelPendingRequest: { cancellations.increment() },
            submitRequest: {
                submitted.append($0)
                return "BGTaskSchedulerErrorDomain Code=2"
            })

        let firstError = sut.scheduleRegularRefresh()
        let secondError = sut.scheduleRegularRefresh()

        XCTAssertEqual(firstError, "BGTaskSchedulerErrorDomain Code=2")
        XCTAssertEqual(secondError, firstError)
        XCTAssertEqual(cancellations.value, 2)
        XCTAssertEqual(
            submitted.all,
            [current.addingTimeInterval(15 * 60), current.addingTimeInterval(15 * 60)])
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

        XCTAssertEqual(submitted.all, [retry])
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

        XCTAssertEqual(submitted.all, [accuracy, transition, grace])
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
