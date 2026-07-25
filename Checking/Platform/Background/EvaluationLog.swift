import Foundation

/// Gatilho da avaliação — port de `OrchestratorTrigger`. `name` = enum `.name` do Kotlin.
enum OrchestratorTrigger: Sendable, Equatable {
    case timer, geofence, significantLocation, foreground, accuracyRetry, pauseActivation, pauseTransition
    var name: String {
        switch self {
        case .timer: return "TIMER"
        case .geofence: return "GEOFENCE"
        case .significantLocation: return "SIGNIFICANT_LOCATION"
        case .foreground: return "FOREGROUND"
        case .accuracyRetry: return "ACCURACY_RETRY"
        case .pauseActivation: return "PAUSE_ACTIVATION"
        case .pauseTransition: return "PAUSE_TRANSITION"
        }
    }
}

/// Desfecho de uma avaliação — port de `EvaluationOutcome` (6 casos exatos).
enum EvaluationOutcome: Sendable, Equatable {
    case submitted, noAction, skip, paused, networkError, toggleOff
}

/// Entrada do log de avaliação — port de `EvaluationEntry`.
struct EvaluationEntry: Sendable, Equatable {
    let at: Date
    let trigger: OrchestratorTrigger
    let accuracyMeters: Double?
    let resolvedLocal: String?
    let decidedAction: String?   // "CHECKIN"/"CHECKOUT" ou nil
    let outcome: EvaluationOutcome
}

/// Ring buffer volátil das últimas 50 avaliações — port de `object EvaluationLog` (@Synchronized).
/// Singleton (acessível pelo orquestrador e pela UI de diagnóstico) — classe com lock, síncrona como o Kotlin.
final class EvaluationLog: @unchecked Sendable {
    static let shared = EvaluationLog()
    static let maxEntries = 50

    private let lock = NSLock()
    private var ring: [EvaluationEntry] = []

    func record(_ entry: EvaluationEntry) {
        lock.withLock {
            ring.append(entry)
            if ring.count > Self.maxEntries { ring.removeFirst() }   // FIFO: descarta o mais antigo
        }
    }
    /// Snapshot mais-novo-primeiro.
    func snapshot() -> [EvaluationEntry] { lock.withLock { ring.reversed() } }
    func isEmpty() -> Bool { lock.withLock { ring.isEmpty } }
    func reset() { lock.withLock { ring.removeAll() } }   // p/ testes
}
