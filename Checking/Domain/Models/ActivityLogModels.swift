import Foundation

// Modelo do log de atividades — port de domain/model/ActivityLogEntry.kt.
// rawValues = os `.name` exatos do Kotlin (persistidos como string). Ver port_spec_persistence_foundation §1.

enum ActivityActor: String, Sendable { case user = "USER", sys = "SYS" }

enum ActivityKind: String, Sendable {
    case checkIn = "CHECK_IN"
    case checkOut = "CHECK_OUT"
    case active = "ACTIVE"
    case inactive = "INACTIVE"
    case error = "ERROR"
    case trigger = "TRIGGER"
    case location = "LOCATION"
    case sync = "SYNC"
    case auth = "AUTH"
    case system = "SYSTEM"
}

enum ActivitySeverity: String, Sendable { case success = "SUCCESS", failure = "FAILURE", warning = "WARNING", info = "INFO" }

struct ActivityLogEntry: Sendable, Equatable {
    var at: Date
    var actor: ActivityActor
    var kind: ActivityKind
    var severity: ActivitySeverity
    var description: String
    var location: String?
}
