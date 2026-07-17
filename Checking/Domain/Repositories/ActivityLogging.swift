import Foundation

/// Fachada de log de atividades (crash-proof) — port do contrato de ActivityLogger.kt.
/// Descrições em inglês, byte-exact. Ver port_spec_persistence_foundation.md §4.
protocol ActivityLogging: Sendable {
    func logCheckIn(_ actor: ActivityActor, _ location: String?, success: Bool)
    func logCheckOut(_ actor: ActivityActor, _ location: String?, success: Bool)
    func logActive(_ detail: String?)
    func logInactive(_ detail: String?)
    func logQueuedOffline(_ actor: ActivityActor, _ kind: ActivityKind, _ location: String?)
    func logSyncing(_ count: Int)
    func logSynced(_ kind: ActivityKind, _ location: String?)
    func logSyncDropped(_ kind: ActivityKind)
    func logTrigger(_ name: String)
    func logLocation(_ message: String, _ location: String?, _ severity: ActivitySeverity)
    func logAuth(_ message: String, _ severity: ActivitySeverity)
    func logSystem(_ message: String, _ severity: ActivitySeverity)
    func logWarning(_ message: String)
    func logError(_ message: String)
}

// Defaults no-op (para doubles nos testes). Assinaturas idênticas aos requisitos (sem valores padrão,
// para não gerar ambiguidade através de `any ActivityLogging`). Chamadas passam args explícitos.
extension ActivityLogging {
    func logCheckIn(_ actor: ActivityActor, _ location: String?, success: Bool) {}
    func logCheckOut(_ actor: ActivityActor, _ location: String?, success: Bool) {}
    func logActive(_ detail: String?) {}
    func logInactive(_ detail: String?) {}
    func logQueuedOffline(_ actor: ActivityActor, _ kind: ActivityKind, _ location: String?) {}
    func logSyncing(_ count: Int) {}
    func logSynced(_ kind: ActivityKind, _ location: String?) {}
    func logSyncDropped(_ kind: ActivityKind) {}
    func logTrigger(_ name: String) {}
    func logLocation(_ message: String, _ location: String?, _ severity: ActivitySeverity) {}
    func logAuth(_ message: String, _ severity: ActivitySeverity) {}
    func logSystem(_ message: String, _ severity: ActivitySeverity) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
}
