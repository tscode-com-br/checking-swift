import Foundation

// Enums de wire (rawValue = valor serializado EXATO) + conversões DTO↔domínio.
// DTO-enum e domínio-enum são tipos DISTINTOS com os mesmos casos (fidelidade Kotlin). §6/§12.

enum DtoCheckAction: String, Codable, Sendable { case checkin, checkout }
enum DtoInformeType: String, Codable, Sendable { case normal, retroativo }
enum DtoLocationMatchStatus: String, Codable, Sendable {
    case matched
    case accuracyTooLow = "accuracy_too_low"
    case notInKnownLocation = "not_in_known_location"
    case outsideWorkplace = "outside_workplace"
    case noKnownLocations = "no_known_locations"
}

extension DtoCheckAction {
    func toDomain() -> CheckAction { self == .checkin ? .checkIn : .checkOut }
}
extension CheckAction {
    func toDto() -> DtoCheckAction { self == .checkIn ? .checkin : .checkout }
}
extension DtoInformeType {
    func toDomain() -> InformeType { self == .normal ? .normal : .retroativo }
}
extension InformeType {
    func toDto() -> DtoInformeType { self == .normal ? .normal : .retroativo }
}
extension DtoLocationMatchStatus {
    func toDomain() -> MatchStatus {
        switch self {
        case .matched:            return .matched
        case .accuracyTooLow:     return .accuracyTooLow
        case .notInKnownLocation: return .notInKnownLocation
        case .outsideWorkplace:   return .outsideWorkplace
        case .noKnownLocations:   return .noKnownLocations
        }
    }
}
