import Foundation

/// Agenda a escrita off-thread do log. Nos testes, síncrono (linha observável imediatamente,
/// equivalente ao UnconfinedTestDispatcher do Kotlin).
protocol ActivityLogScheduler: Sendable {
    func schedule(_ work: @escaping @Sendable () -> Void)
}
/// Produção: best-effort fora da thread do chamador.
struct BackgroundLogScheduler: ActivityLogScheduler {
    func schedule(_ work: @escaping @Sendable () -> Void) { Task.detached(priority: .utility) { work() } }
}
/// Testes: executa imediatamente.
struct InlineLogScheduler: ActivityLogScheduler {
    func schedule(_ work: @escaping @Sendable () -> Void) { work() }
}

/// Fachada CRASH-PROOF (golden rule 2) — port de platform/activitylog/ActivityLogger.kt.
/// Descrições em inglês, byte-exact. `verbose` muta só o `logTrigger`.
final class ActivityLogger: ActivityLogging, @unchecked Sendable {
    private let clock: any Clock
    private let activityLog: ActivityLog
    private let scheduler: any ActivityLogScheduler
    var verbose: Bool = true

    init(clock: any Clock, activityLog: ActivityLog, scheduler: any ActivityLogScheduler = BackgroundLogScheduler()) {
        self.clock = clock
        self.activityLog = activityLog
        self.scheduler = scheduler
    }

    func logCheckIn(_ actor: ActivityActor, _ location: String?, success: Bool) {
        log(actor, .checkIn, success ? .success : .failure,
            (success ? "Check-in at " : "Check-in failed at ") + locText(location) + ".", location)
    }
    func logCheckOut(_ actor: ActivityActor, _ location: String?, success: Bool) {
        log(actor, .checkOut, success ? .success : .failure,
            (success ? "Check-out at " : "Check-out failed at ") + locText(location) + ".", location)
    }
    func logActive(_ detail: String?) { log(.sys, .active, .info, "Checking is now active." + detailSuffix(detail), nil) }
    func logInactive(_ detail: String?) { log(.sys, .inactive, .info, "Checking is now inactive." + detailSuffix(detail), nil) }
    func logQueuedOffline(_ actor: ActivityActor, _ kind: ActivityKind, _ location: String?) {
        log(actor, .sync, .warning, actText(kind) + " queued (offline) at " + locText(location) + ".", location)
    }
    func logSyncing(_ count: Int) { log(.sys, .sync, .info, "Syncing \(count) queued event(s).", nil) }
    func logSynced(_ kind: ActivityKind, _ location: String?) {
        log(.sys, .sync, .success, "Queued " + actText(kind).lowercased() + " synced at " + locText(location) + ".", location)
    }
    func logSyncDropped(_ kind: ActivityKind) {
        log(.sys, .sync, .failure, "Queued " + actText(kind).lowercased() + " dropped (invalid).", nil)
    }
    func logTrigger(_ name: String) {
        if !verbose { return } // alta frequência, baixo sinal
        log(.sys, .trigger, .info, "Background evaluation (\(name)).", nil)
    }
    func logLocation(_ message: String, _ location: String?, _ severity: ActivitySeverity) { log(.sys, .location, severity, message, location) }
    func logAuth(_ message: String, _ severity: ActivitySeverity) { log(.sys, .auth, severity, message, nil) }
    func logSystem(_ message: String, _ severity: ActivitySeverity) { log(.sys, .system, severity, message, nil) }
    func logWarning(_ message: String) { log(.sys, .system, .warning, message, nil) }
    func logError(_ message: String) { log(.sys, .error, .failure, message, nil) }

    // Core — duplo guard: nunca lança no caminho do chamador.
    private func log(_ actor: ActivityActor, _ kind: ActivityKind, _ severity: ActivitySeverity, _ description: String, _ location: String?) {
        let entry = ActivityLogEntry(at: clock.now(), actor: actor, kind: kind, severity: severity, description: description, location: location)
        scheduler.schedule { [activityLog] in try? activityLog.record(entry) }
    }
    private func locText(_ location: String?) -> String {
        if let l = location, !l.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return l }
        return "an unknown location"
    }
    private func detailSuffix(_ detail: String?) -> String {
        if let d = detail, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return " (\(d))" }
        return ""
    }
    private func actText(_ kind: ActivityKind) -> String {
        switch kind {
        case .checkIn: return "Check-in"
        case .checkOut: return "Check-out"
        default: return "Activity"
        }
    }
}
