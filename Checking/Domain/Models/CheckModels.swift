import Foundation

// Modelos de domínio do motor de decisão — port 1:1 de domain/model/CheckModels.kt + GeofenceCircle.kt.
// Ver docs/port_spec_decision_engine.md §2. `Instant` → `Date`.

enum CheckAction: Sendable, Equatable { case checkIn, checkOut }

enum InformeType: Sendable, Equatable { case normal, retroativo }

enum MatchStatus: Sendable, Equatable {
    case matched
    case accuracyTooLow
    case notInKnownLocation
    case outsideWorkplace
    case noKnownLocations
}

struct HistoryState: Sendable, Equatable {
    var found: Bool
    var chave: String
    var projeto: String?
    var currentAction: CheckAction?
    var currentLocal: String?
    var hasCurrentDayCheckin: Bool
    var lastCheckinAt: Date?
    var lastCheckoutAt: Date?
    var transportEnabled: Bool
}

struct LocationMatch: Sendable, Equatable {
    var matched: Bool
    var resolvedLocal: String?
    var label: String
    var status: MatchStatus
    var message: String
    var accuracyMeters: Double?
    var accuracyThresholdMeters: Int
    var minimumCheckoutDistanceMeters: Int
    var nearestWorkplaceDistanceMeters: Double?
}

struct LocationOptions: Sendable, Equatable {
    var items: [String]
    var accuracyThresholdMeters: Int
    var mixedZoneIntervalMinutes: Int
}

/// Círculo grosseiro só para armar geofences nativos; matching é sempre no servidor.
struct GeofenceCircle: Sendable, Equatable {
    var id: Int
    var local: String
    var centerLat: Double
    var centerLng: Double
    var radiusMeters: Double
}

struct AutomaticActivity: Sendable, Equatable {
    var action: CheckAction
    var local: String?
}
