import BackgroundTasks
import Foundation
import OSLog

/// Dono único do `BGAppRefreshTaskRequest`. O iOS admite somente um pedido pendente desse tipo por app;
/// por isso refresh regular, baixa precisão e transições da pausa compartilham identificador/submissão.
/// `earliestBeginDate` é apenas limite inferior: o iOS continua decidindo se/quando executará o pedido.
final class BGTaskAppRefreshScheduler: AppRefreshScheduling, @unchecked Sendable {
    static let taskIdentifier = "br.com.tscode.checking.refresh"
    static let regularInterval: TimeInterval = 15 * 60
    static let accuracyRetryDeadlineDefaultsKey = "pref_bg_refresh_accuracy_retry_deadline_epoch_ms"
    static let pauseActivationDeadlineDefaultsKey = "pref_bg_refresh_pause_activation_deadline_epoch_ms"
    static let pauseTransitionDeadlineDefaultsKey = "pref_bg_refresh_pause_transition_deadline_epoch_ms"

    typealias RequestCanceller = @Sendable () -> Void
    typealias RequestSubmitter = @Sendable (Date) -> String?

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let cancelPendingRequest: RequestCanceller
    private let submitRequest: RequestSubmitter
    private let lock = NSLock()
    /// Cache apenas do processo atual. Um novo lançamento sempre reconfirma o pedido no scheduler do iOS.
    private var submittedRequestDeadline: Date?

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            now: { Date() },
            cancelPendingRequest: {
                BGTaskScheduler.shared.cancel(
                    taskRequestWithIdentifier: BGTaskAppRefreshScheduler.taskIdentifier)
            },
            submitRequest: { earliestBeginDate in
                let request = BGAppRefreshTaskRequest(
                    identifier: BGTaskAppRefreshScheduler.taskIdentifier)
                request.earliestBeginDate = earliestBeginDate
                do {
                    try BGTaskScheduler.shared.submit(request)
                    return nil
                } catch {
                    return String(describing: error)
                }
            })
    }

    init(
        defaults: UserDefaults,
        now: @escaping @Sendable () -> Date,
        cancelPendingRequest: @escaping RequestCanceller = {},
        submitRequest: @escaping RequestSubmitter
    ) {
        self.defaults = defaults
        self.now = now
        self.cancelPendingRequest = cancelPendingRequest
        self.submitRequest = submitRequest
    }

    @discardableResult
    func scheduleRegularRefresh() -> String? {
        lock.withLock {
            submitNextLocked(now: now())
        }
    }

    @discardableResult
    func scheduleAccuracyRetry(at deadline: Date) -> String? {
        lock.withLock {
            let current = now()
            let previousDeadline = nextDeadlineLocked(now: current)
            let milliseconds = Int64((deadline.timeIntervalSince1970 * 1_000).rounded())
            defaults.set(milliseconds, forKey: Self.accuracyRetryDeadlineDefaultsKey)
            return submitNextLocked(
                now: current,
                forceReplacement: nextDeadlineLocked(now: current) != previousDeadline)
        }
    }

    @discardableResult
    func clearAccuracyRetryDeadlineAndScheduleRegular() -> String? {
        lock.withLock {
            let current = now()
            let previousDeadline = nextDeadlineLocked(now: current)
            defaults.removeObject(forKey: Self.accuracyRetryDeadlineDefaultsKey)
            return submitNextLocked(
                now: current,
                forceReplacement: nextDeadlineLocked(now: current) != previousDeadline)
        }
    }

    @discardableResult
    func schedulePauseActivation(at deadline: Date) -> String? {
        lock.withLock {
            let current = now()
            let previousDeadline = nextDeadlineLocked(now: current)
            let milliseconds = Int64((deadline.timeIntervalSince1970 * 1_000).rounded())
            defaults.set(milliseconds, forKey: Self.pauseActivationDeadlineDefaultsKey)
            return submitNextLocked(
                now: current,
                forceReplacement: nextDeadlineLocked(now: current) != previousDeadline)
        }
    }

    @discardableResult
    func clearPauseActivationDeadlineAndScheduleRegular() -> String? {
        lock.withLock {
            let current = now()
            let previousDeadline = nextDeadlineLocked(now: current)
            defaults.removeObject(forKey: Self.pauseActivationDeadlineDefaultsKey)
            return submitNextLocked(
                now: current,
                forceReplacement: nextDeadlineLocked(now: current) != previousDeadline)
        }
    }

    @discardableResult
    func schedulePauseTransition(at deadline: Date) -> String? {
        lock.withLock {
            let current = now()
            let previousDeadline = nextDeadlineLocked(now: current)
            let milliseconds = Int64((deadline.timeIntervalSince1970 * 1_000).rounded())
            defaults.set(milliseconds, forKey: Self.pauseTransitionDeadlineDefaultsKey)
            return submitNextLocked(
                now: current,
                forceReplacement: nextDeadlineLocked(now: current) != previousDeadline)
        }
    }

    @discardableResult
    func clearPauseTransitionDeadlineAndScheduleRegular() -> String? {
        lock.withLock {
            let current = now()
            let previousDeadline = nextDeadlineLocked(now: current)
            defaults.removeObject(forKey: Self.pauseTransitionDeadlineDefaultsKey)
            return submitNextLocked(
                now: current,
                forceReplacement: nextDeadlineLocked(now: current) != previousDeadline)
        }
    }

    func triggerForPendingRefresh() -> OrchestratorTrigger {
        lock.withLock {
            if let transitionDeadline = pauseTransitionDeadlineLocked(),
               transitionDeadline <= now() {
                return .pauseTransition
            }
            if let pauseDeadline = pauseActivationDeadlineLocked(),
               pauseDeadline <= now() {
                return .pauseActivation
            }
            guard let retryDeadline = accuracyRetryDeadlineLocked(),
                  retryDeadline <= now() else { return .timer }
            return .accuracyRetry
        }
    }

    private func submitNextLocked(now: Date, forceReplacement: Bool = false) -> String? {
        let earliestBeginDate = nextDeadlineLocked(now: now)
        if !forceReplacement,
           let submittedDeadline = submittedRequestDeadlineLocked(),
           submittedDeadline > now,
           submittedDeadline <= earliestBeginDate {
            return nil
        }

        // `BGTaskScheduler` não substitui atomicamente um pedido pendente. Como o app possui um único
        // identificador de App Refresh, cancelamos o pedido anterior antes de enviar o novo mínimo.
        cancelPendingRequest()
        if let error = submitRequest(earliestBeginDate) {
            submittedRequestDeadline = nil
            AppLog.background.error(
                "BGAppRefresh submission failed: \(error, privacy: .public)")
            return error
        }
        submittedRequestDeadline = earliestBeginDate
        return nil
    }

    private func nextDeadlineLocked(now: Date) -> Date {
        let regularDeadline = now.addingTimeInterval(Self.regularInterval)
        return [
            accuracyRetryDeadlineLocked(),
            pauseActivationDeadlineLocked(),
            pauseTransitionDeadlineLocked(),
            regularDeadline
        ].compactMap { $0 }.min() ?? regularDeadline
    }

    private func submittedRequestDeadlineLocked() -> Date? {
        submittedRequestDeadline
    }

    private func accuracyRetryDeadlineLocked() -> Date? {
        deadlineLocked(forKey: Self.accuracyRetryDeadlineDefaultsKey)
    }

    private func pauseActivationDeadlineLocked() -> Date? {
        deadlineLocked(forKey: Self.pauseActivationDeadlineDefaultsKey)
    }

    private func pauseTransitionDeadlineLocked() -> Date? {
        deadlineLocked(forKey: Self.pauseTransitionDeadlineDefaultsKey)
    }

    private func deadlineLocked(forKey key: String) -> Date? {
        guard defaults.object(forKey: key) != nil else { return nil }
        let milliseconds = defaults.object(forKey: key) as? NSNumber
        guard let milliseconds else { return nil }
        return Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
    }
}
