import Foundation

// DTOs do módulo Check + Geofence — port 1:1 de data/dto/CheckDtos.kt + GeofenceDtos.kt.
// Respostas: Decodable com defaults exatos (kotlinx encodeDefaults/coerceInputValues). §7/§10.
// Requests: Encodable com `null` EXPLÍCITO p/ opcionais (encodeDefaults=true, Pydantic exige presença). §8.
//
// Regra de fidelidade: `queued_forms` é Bool (não Int); Int vs Double distintos; chaves via CodingKeys.

// MARK: - Requests (explicit-null encoding)

struct WebLocationMatchRequest: Encodable, Sendable {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double?

    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case accuracyMeters = "accuracy_meters"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(latitude, forKey: .latitude)
        try c.encode(longitude, forKey: .longitude)
        if let accuracyMeters { try c.encode(accuracyMeters, forKey: .accuracyMeters) }
        else { try c.encodeNil(forKey: .accuracyMeters) }   // sempre presente, null explícito
    }
}

struct WebCheckSubmitRequest: Encodable, Sendable {
    let chave: String
    let projeto: String
    let action: DtoCheckAction
    let local: String?
    let informe: DtoInformeType
    let eventTime: String
    let clientEventId: String
    let fillForms: Bool

    enum CodingKeys: String, CodingKey {
        case chave, projeto, action, local, informe
        case eventTime = "event_time"
        case clientEventId = "client_event_id"
        case fillForms = "fill_forms"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chave, forKey: .chave)
        try c.encode(projeto, forKey: .projeto)
        try c.encode(action, forKey: .action)
        if let local { try c.encode(local, forKey: .local) } else { try c.encodeNil(forKey: .local) }
        try c.encode(informe, forKey: .informe)
        try c.encode(eventTime, forKey: .eventTime)
        try c.encode(clientEventId, forKey: .clientEventId)
        try c.encode(fillForms, forKey: .fillForms)          // default true, sempre enviado
    }
}

// MARK: - Responses

struct WebLocationMatchResponse: Decodable, Sendable {
    let matched: Bool
    let resolvedLocal: String?
    let label: String
    let status: DtoLocationMatchStatus
    let message: String
    let accuracyMeters: Double?
    let accuracyThresholdMeters: Int
    let minimumCheckoutDistanceMeters: Int
    let nearestWorkplaceDistanceMeters: Double?

    enum CodingKeys: String, CodingKey {
        case matched, label, status, message
        case resolvedLocal = "resolved_local"
        case accuracyMeters = "accuracy_meters"
        case accuracyThresholdMeters = "accuracy_threshold_meters"
        case minimumCheckoutDistanceMeters = "minimum_checkout_distance_meters"
        case nearestWorkplaceDistanceMeters = "nearest_workplace_distance_meters"
    }
    init(matched: Bool, resolvedLocal: String?, label: String, status: DtoLocationMatchStatus, message: String,
         accuracyMeters: Double?, accuracyThresholdMeters: Int, minimumCheckoutDistanceMeters: Int,
         nearestWorkplaceDistanceMeters: Double?) {
        self.matched = matched; self.resolvedLocal = resolvedLocal; self.label = label; self.status = status
        self.message = message; self.accuracyMeters = accuracyMeters; self.accuracyThresholdMeters = accuracyThresholdMeters
        self.minimumCheckoutDistanceMeters = minimumCheckoutDistanceMeters
        self.nearestWorkplaceDistanceMeters = nearestWorkplaceDistanceMeters
    }
}

struct WebCheckHistoryResponse: Decodable, Sendable {
    let found: Bool
    let chave: String
    let projeto: String?
    let currentAction: DtoCheckAction?
    let currentLocal: String?
    let hasCurrentDayCheckin: Bool
    let lastCheckinAt: String?
    let lastCheckoutAt: String?
    let transportEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case found, chave, projeto
        case currentAction = "current_action"
        case currentLocal = "current_local"
        case hasCurrentDayCheckin = "has_current_day_checkin"
        case lastCheckinAt = "last_checkin_at"
        case lastCheckoutAt = "last_checkout_at"
        case transportEnabled = "transport_enabled"
    }
    init(found: Bool, chave: String, projeto: String?, currentAction: DtoCheckAction?, currentLocal: String?,
         hasCurrentDayCheckin: Bool, lastCheckinAt: String?, lastCheckoutAt: String?, transportEnabled: Bool) {
        self.found = found; self.chave = chave; self.projeto = projeto; self.currentAction = currentAction
        self.currentLocal = currentLocal; self.hasCurrentDayCheckin = hasCurrentDayCheckin
        self.lastCheckinAt = lastCheckinAt; self.lastCheckoutAt = lastCheckoutAt; self.transportEnabled = transportEnabled
    }
}

struct WebCheckHistoryItemDto: Decodable, Sendable {
    let action: DtoCheckAction
    let projeto: String
    let local: String?
    let time: String
    let informe: DtoInformeType
    // Sem @SerialName no Kotlin → chaves = nomes das props (camelCase). Init memberwise para fakes/testes.
    init(action: DtoCheckAction, projeto: String, local: String?, time: String, informe: DtoInformeType) {
        self.action = action; self.projeto = projeto; self.local = local; self.time = time; self.informe = informe
    }
}

struct WebCheckHistoryListResponseDto: Decodable, Sendable {
    let items: [WebCheckHistoryItemDto]

    enum CodingKeys: String, CodingKey { case items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([WebCheckHistoryItemDto].self, forKey: .items) ?? []   // default []
    }
    init(items: [WebCheckHistoryItemDto]) { self.items = items }
}

struct WebLocationOptionsResponse: Decodable, Sendable {
    let items: [String]
    let locationAccuracyThresholdMeters: Int
    let mixedZoneIntervalMinutes: Int

    enum CodingKeys: String, CodingKey {
        case items
        case locationAccuracyThresholdMeters = "location_accuracy_threshold_meters"
        case mixedZoneIntervalMinutes = "mixed_zone_interval_minutes"
    }
    init(items: [String], locationAccuracyThresholdMeters: Int, mixedZoneIntervalMinutes: Int) {
        self.items = items; self.locationAccuracyThresholdMeters = locationAccuracyThresholdMeters
        self.mixedZoneIntervalMinutes = mixedZoneIntervalMinutes
    }
}

struct MobileSyncStateResponse: Decodable, Sendable {
    let found: Bool
    let chave: String
    let nome: String?
    let projeto: String?
    let currentAction: DtoCheckAction?
    let currentEventTime: String?
    let currentLocal: String?
    let lastCheckinAt: String?
    let lastCheckoutAt: String?

    enum CodingKeys: String, CodingKey {
        case found, chave, nome, projeto
        case currentAction = "current_action"
        case currentEventTime = "current_event_time"
        case currentLocal = "current_local"
        case lastCheckinAt = "last_checkin_at"
        case lastCheckoutAt = "last_checkout_at"
    }
    init(found: Bool, chave: String, nome: String? = nil, projeto: String? = nil, currentAction: DtoCheckAction? = nil,
         currentEventTime: String? = nil, currentLocal: String? = nil, lastCheckinAt: String? = nil, lastCheckoutAt: String? = nil) {
        self.found = found; self.chave = chave; self.nome = nome; self.projeto = projeto; self.currentAction = currentAction
        self.currentEventTime = currentEventTime; self.currentLocal = currentLocal
        self.lastCheckinAt = lastCheckinAt; self.lastCheckoutAt = lastCheckoutAt
    }
}

/// `typealias WebCheckSubmitResponse = MobileSubmitResponse` no Android.
typealias WebCheckSubmitResponse = MobileSubmitResponse

struct MobileSubmitResponse: Decodable, Sendable {
    let ok: Bool
    let duplicate: Bool
    let queuedForms: Bool
    let workerHealthy: Bool
    let message: String
    let state: MobileSyncStateResponse

    enum CodingKeys: String, CodingKey {
        case ok, duplicate, message, state
        case queuedForms = "queued_forms"
        case workerHealthy = "worker_healthy"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        duplicate = try c.decodeIfPresent(Bool.self, forKey: .duplicate) ?? false
        queuedForms = try c.decodeIfPresent(Bool.self, forKey: .queuedForms) ?? true    // Bool, default true (§10)
        workerHealthy = try c.decodeIfPresent(Bool.self, forKey: .workerHealthy) ?? true
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        state = try c.decode(MobileSyncStateResponse.self, forKey: .state)
    }
    init(ok: Bool, duplicate: Bool = false, queuedForms: Bool = true, workerHealthy: Bool = true,
         message: String = "", state: MobileSyncStateResponse) {
        self.ok = ok; self.duplicate = duplicate; self.queuedForms = queuedForms
        self.workerHealthy = workerHealthy; self.message = message; self.state = state
    }
}

struct GeofenceCircleDto: Decodable, Sendable {
    let id: Int
    let local: String
    let centerLat: Double
    let centerLng: Double
    let radiusMeters: Double

    enum CodingKeys: String, CodingKey {
        case id, local
        case centerLat = "center_lat"
        case centerLng = "center_lng"
        case radiusMeters = "radius_meters"
    }
    init(id: Int, local: String, centerLat: Double, centerLng: Double, radiusMeters: Double) {
        self.id = id; self.local = local; self.centerLat = centerLat; self.centerLng = centerLng; self.radiusMeters = radiusMeters
    }
}

struct WebGeofencesResponse: Decodable, Sendable {
    let locations: [GeofenceCircleDto]
    init(locations: [GeofenceCircleDto]) { self.locations = locations }
}
