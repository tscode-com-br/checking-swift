import BackgroundTasks
import Foundation

/// Dono único do `BGAppRefreshTaskRequest`. O iOS admite somente um pedido pendente desse tipo por app;
/// por isso refresh regular, baixa precisão e transições da pausa compartilham identificador/submissão.
/// `earliestBeginDate` é apenas limite inferior: o iOS continua decidindo se/quando executará o pedido.
final class BGTaskAppRefreshScheduler: AppRefreshScheduling, @unchecked Sendable {
    static let taskIdentifier = "br.com.tscode.checking.refresh"
    static let regularInterval: TimeInterval = 15 * 60
    static let accuracyRetryDeadlineDefaultsKey = "pref_bg_refresh_accuracy_retry_deadline_epoch_ms"
    static let pauseActivationDeadlineDefaultsKey = "pref_bg_refresh_pause_activation_deadline_epoch_ms"
    static let pauseTransitionDeadlineDefaultsKey = "pref_bg_refresh_pause_transition_deadline_epoch_ms"

    typealias RequestSubmitter = @Sendable (Date) -> String?

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let submitRequest: RequestSubmitter
    private let lock = NSLock()

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            now: { Date() },
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
        submitRequest: @escaping RequestSubmitter
    ) {
        self.defaults = defaults
        self.now = now
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
            let milliseconds = Int64((deadline.timeIntervalSince1970 * 1_000).rounded())
            defaults.set(milliseconds, forKey: Self.accuracyRetryDeadlineDefaultsKey)
            return submitNextLocked(now: now())
        }
    }

    @discardableResult
    func clearAccuracyRetryDeadlineAndScheduleRegular() -> String? {
        lock.withLock {
            defaults.removeObject(forKey: Self.accuracyRetryDeadlineDefaultsKey)
            return submitNextLocked(now: now())
        }
    }

    @discardableResult
    func schedulePauseActivation(at deadline: Date) -> String? {
        lock.withLock {
            let milliseconds = Int64((deadline.timeIntervalSince1970 * 1_000).rounded())
            defaults.set(milliseconds, forKey: Self.pauseActivationDeadlineDefaultsKey)
            return submitNextLocked(now: now())
        }
    }

    @discardableResult
    func clearPauseActivationDeadlineAndScheduleRegular() -> String? {
        lock.withLock {
            defaults.removeObject(forKey: Self.pauseActivationDeadlineDefaultsKey)
            return submitNextLocked(now: now())
        }
    }

    @discardableResult
    func schedulePauseTransition(at deadline: Date) -> String? {
        lock.withLock {
            let milliseconds = Int64((deadline.timeIntervalSince1970 * 1_000).rounded())
            defaults.set(milliseconds, forKey: Self.pauseTransitionDeadlineDefaultsKey)
            return submitNextLocked(now: now())
        }
    }

    @discardableResult
    func clearPauseTransitionDeadlineAndScheduleRegular() -> String? {
        lock.withLock {
            defaults.removeObject(forKey: Self.pauseTransitionDeadlineDefaultsKey)
            return submitNextLocked(now: now())
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

    private func submitNextLocked(now: Date) -> String? {
        let regularDeadline = now.addingTimeInterval(Self.regularInterval)
        let earliestBeginDate = [
            accuracyRetryDeadlineLocked(),
            pauseActivationDeadlineLocked(),
            pauseTransitionDeadlineLocked(),
            regularDeadline
        ].compactMap { $0 }.min() ?? regularDeadline
        return submitRequest(earliestBeginDate)
    }

    private func accuracyRetryDeadlineLocked() -> Date? {
        guard defaults.object(forKey: Self.accuracyRetryDeadlineDefaultsKey) != nil else { return nil }
        let milliseconds = defaults.object(forKey: Self.accuracyRetryDeadlineDefaultsKey) as? NSNumber
        guard let milliseconds else { return nil }
        return Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
    }

    private func pauseActivationDeadlineLocked() -> Date? {
        guard defaults.object(forKey: Self.pauseActivationDeadlineDefaultsKey) != nil else { return nil }
        let milliseconds = defaults.object(forKey: Self.pauseActivationDeadlineDefaultsKey) as? NSNumber
        guard let milliseconds else { return nil }
        return Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
    }

    private func pauseTransitionDeadlineLocked() -> Date? {
        guard defaults.object(forKey: Self.pauseTransitionDeadlineDefaultsKey) != nil else { return nil }
        let milliseconds = defaults.object(forKey: Self.pauseTransitionDeadlineDefaultsKey) as? NSNumber
        guard let milliseconds else { return nil }
        return Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
    }
}
