import Foundation

// DTOs de acidente — port de data/dto/AccidentDtos.kt + data/api/AccidentApi.kt (EmergencyCallChaveRequest).
// Ver port_spec_network_contracts.md §7 e port_spec_accident_video.md §8.

// MARK: - Wire enums (DTO ≠ domínio, mesma convenção de CheckWireEnums.swift)

enum DtoAccidentZone: String, Codable, Sendable { case safety, accident }
enum DtoAccidentSafetyStatus: String, Codable, Sendable { case ok, help }

extension DtoAccidentZone {
    func toDomain() -> AccidentZone { self == .safety ? .safety : .accident }
}
extension AccidentZone {
    func toDto() -> DtoAccidentZone { self == .safety ? .safety : .accident }
}
extension DtoAccidentSafetyStatus {
    func toDomain() -> AccidentSafetyStatus { self == .ok ? .ok : .help }
}
extension AccidentSafetyStatus {
    func toDto() -> DtoAccidentSafetyStatus { self == .ok ? .ok : .help }
}

// MARK: - Responses

struct WebAccidentUserReport: Decodable, Sendable {
    let zone: DtoAccidentZone?
    let status: DtoAccidentSafetyStatus?
    let reportedAt: String?
    enum CodingKeys: String, CodingKey { case zone, status; case reportedAt = "reported_at" }
    init(zone: DtoAccidentZone? = nil, status: DtoAccidentSafetyStatus? = nil, reportedAt: String? = nil) {
        self.zone = zone; self.status = status; self.reportedAt = reportedAt
    }
}

struct WebAccidentActiveItem: Decodable, Sendable {
    let accidentId: Int
    let accidentNumberLabel: String
    let projectId: Int
    let projectName: String
    let locationName: String
    let description: String?
    let awarenessStatus: String
    let currentUserReport: WebAccidentUserReport?
    enum CodingKeys: String, CodingKey {
        case description
        case accidentId = "accident_id"
        case accidentNumberLabel = "accident_number_label"
        case projectId = "project_id"
        case projectName = "project_name"
        case locationName = "location_name"
        case awarenessStatus = "awareness_status"
        case currentUserReport = "current_user_report"
    }
    init(accidentId: Int, accidentNumberLabel: String, projectId: Int, projectName: String, locationName: String,
         description: String? = nil, awarenessStatus: String, currentUserReport: WebAccidentUserReport? = nil) {
        self.accidentId = accidentId; self.accidentNumberLabel = accidentNumberLabel; self.projectId = projectId
        self.projectName = projectName; self.locationName = locationName; self.description = description
        self.awarenessStatus = awarenessStatus; self.currentUserReport = currentUserReport
    }
}

struct WebAccidentStateResponse: Decodable, Sendable {
    let isActive: Bool
    let accidentId: Int?
    let accidentNumberLabel: String?
    let projectId: Int?
    let projectName: String?
    let locationName: String?
    let description: String?
    let awarenessStatus: String?
    let currentUserReport: WebAccidentUserReport?
    let activeAccidents: [WebAccidentActiveItem]
    enum CodingKeys: String, CodingKey {
        case description
        case isActive = "is_active"
        case accidentId = "accident_id"
        case accidentNumberLabel = "accident_number_label"
        case projectId = "project_id"
        case projectName = "project_name"
        case locationName = "location_name"
        case awarenessStatus = "awareness_status"
        case currentUserReport = "current_user_report"
        case activeAccidents = "active_accidents"
    }
    init(isActive: Bool, accidentId: Int? = nil, accidentNumberLabel: String? = nil, projectId: Int? = nil,
         projectName: String? = nil, locationName: String? = nil, description: String? = nil,
         awarenessStatus: String? = nil, currentUserReport: WebAccidentUserReport? = nil, activeAccidents: [WebAccidentActiveItem]) {
        self.isActive = isActive; self.accidentId = accidentId; self.accidentNumberLabel = accidentNumberLabel
        self.projectId = projectId; self.projectName = projectName; self.locationName = locationName
        self.description = description; self.awarenessStatus = awarenessStatus
        self.currentUserReport = currentUserReport; self.activeAccidents = activeAccidents
    }
}

struct AccidentVideoUploadResponse: Decodable, Sendable {
    let videoId: Int
    let publicUrl: String
    let capturedAt: String
    enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case publicUrl = "public_url"
        case capturedAt = "captured_at"
    }
}

struct EmergencyCallResponse: Decodable, Sendable {
    let callNumber: Int
    let callNumberLabel: String
    let callSid: String?
    let callStatus: String
    let message: String
    enum CodingKeys: String, CodingKey {
        case message
        case callNumber = "call_number"
        case callNumberLabel = "call_number_label"
        case callSid = "call_sid"
        case callStatus = "call_status"
    }
    init(callNumber: Int, callNumberLabel: String, callSid: String? = nil, callStatus: String, message: String) {
        self.callNumber = callNumber; self.callNumberLabel = callNumberLabel
        self.callSid = callSid; self.callStatus = callStatus; self.message = message
    }
}

/// SEM @SerialName no Kotlin → wire = camelCase (ao contrário do resto, snake_case). §10 do spec de rede.
struct AccidentProjectOption: Decodable, Sendable {
    let id: Int
    let name: String
}
/// SEM @SerialName → wire = camelCase.
struct AccidentLocationOption: Decodable, Sendable {
    let id: Int
    let name: String
    let registered: Bool
}

// MARK: - Requests (null explícito p/ opcionais — §8 do spec de rede)

struct WebAccidentOpenRequest: Encodable, Sendable {
    let chave: String
    let projectId: Int
    let locationId: Int?
    let customLocationName: String?
    let zone: DtoAccidentZone
    let status: DtoAccidentSafetyStatus
    let description: String?
    enum CodingKeys: String, CodingKey {
        case chave, zone, status, description
        case projectId = "project_id"
        case locationId = "location_id"
        case customLocationName = "custom_location_name"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chave, forKey: .chave)
        try c.encode(projectId, forKey: .projectId)
        if let locationId { try c.encode(locationId, forKey: .locationId) } else { try c.encodeNil(forKey: .locationId) }
        if let customLocationName { try c.encode(customLocationName, forKey: .customLocationName) } else { try c.encodeNil(forKey: .customLocationName) }
        try c.encode(zone, forKey: .zone)
        try c.encode(status, forKey: .status)
        if let description { try c.encode(description, forKey: .description) } else { try c.encodeNil(forKey: .description) }
    }
}

struct WebAccidentReportRequest: Encodable, Sendable {
    let chave: String
    let zone: DtoAccidentZone
    let status: DtoAccidentSafetyStatus
}

struct WebAccidentAcknowledgeRequest: Encodable, Sendable {
    let chave: String
    let accidentId: Int?
    enum CodingKeys: String, CodingKey { case chave; case accidentId = "accident_id" }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chave, forKey: .chave)
        if let accidentId { try c.encode(accidentId, forKey: .accidentId) } else { try c.encodeNil(forKey: .accidentId) }
    }
}

struct EmergencyCallChaveRequest: Encodable, Sendable {
    let chave: String
}
