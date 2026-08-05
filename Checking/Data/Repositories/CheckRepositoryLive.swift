import Foundation

/// Implementação viva de `CheckRepository` — port de data/repository/CheckRepositoryImpl.kt.
/// Envolve cada chamada em `safeApiCall` e mapeia DTO→domínio (parse ISO no boundary, fallback nil).
/// Classe (não struct) para o cache TTL de geofences (@Volatile no Android → lock aqui).
/// Ver port_spec_network_contracts §5. (`streamEvents` fica no slice de background/SSE.)
final class CheckRepositoryLive: CheckRepository, @unchecked Sendable {
    private let api: any CheckApi
    private let clock: any Clock

    private let lock = NSLock()
    private var geofenceCache: [GeofenceCircle]?
    private var geofenceCachedChave: String?
    private var geofenceCachedAt: Date?
    private let geofenceCacheTTL: TimeInterval = 3600   // Duration.ofHours(1)

    init(api: any CheckApi, clock: any Clock) {
        self.api = api
        self.clock = clock
    }

    func getState(_ chave: String) async -> AppResult<HistoryState> {
        await safeApiCall { try await api.getState(chave).toDomain() }
    }

    func getHistory(_ chave: String) async -> AppResult<[CheckHistoryEntry]> {
        await safeApiCall { try await api.getHistory(chave).items.map { $0.toDomain() } }
    }

    func getLocations() async -> AppResult<LocationOptions> {
        await safeApiCall {
            let r = try await api.getLocations()
            return LocationOptions(items: r.items,
                                   accuracyThresholdMeters: r.locationAccuracyThresholdMeters,
                                   mixedZoneIntervalMinutes: r.mixedZoneIntervalMinutes)
        }
    }

    func matchLocation(_ lat: Double, _ lon: Double, _ accuracyMeters: Double?) async -> AppResult<LocationMatch> {
        await safeApiCall {
            try await api.matchLocation(WebLocationMatchRequest(latitude: lat, longitude: lon, accuracyMeters: accuracyMeters)).toDomain()
        }
    }

    func matchLocation(
        _ lat: Double,
        _ lon: Double,
        _ accuracyMeters: Double?,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> GuardedOperationResult<AppResult<LocationMatch>> {
        let authorization = dispatchAuthorization(for: effectGuard)
        let result = await safeApiCall {
            try await api.matchLocation(
                WebLocationMatchRequest(
                    latitude: lat,
                    longitude: lon,
                    accuracyMeters: accuracyMeters
                ),
                dispatchAuthorization: authorization
            )
        }
        switch result {
        case .success(.notDispatched):
            return .notDispatched
        case .success(.dispatched(let response)):
            return .dispatched(.success(response.toDomain()))
        case .failure(let error):
            return .dispatched(.failure(error))
        }
    }

    func submit(chave: String, projeto: String, action: CheckAction, local: String?, informe: InformeType,
                eventTime: Date, clientEventId: String, fillForms: Bool) async -> AppResult<HistoryState> {
        await safeApiCall {
            let request = WebCheckSubmitRequest(
                chave: chave, projeto: projeto, action: action.toDto(), local: local, informe: informe.toDto(),
                eventTime: ISOInstant.string(eventTime), clientEventId: clientEventId, fillForms: fillForms)
            return try await api.submit(request).state.toHistoryState()
        }
    }

    func submit(
        chave: String,
        projeto: String,
        action: CheckAction,
        local: String?,
        informe: InformeType,
        eventTime: Date,
        clientEventId: String,
        fillForms: Bool,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> GuardedOperationResult<AppResult<HistoryState>> {
        let request = WebCheckSubmitRequest(
            chave: chave,
            projeto: projeto,
            action: action.toDto(),
            local: local,
            informe: informe.toDto(),
            eventTime: ISOInstant.string(eventTime),
            clientEventId: clientEventId,
            fillForms: fillForms
        )
        let authorization = dispatchAuthorization(for: effectGuard)
        let result = await safeApiCall {
            try await api.submit(
                request,
                dispatchAuthorization: authorization
            )
        }
        switch result {
        case .success(.notDispatched):
            return .notDispatched
        case .success(.dispatched(let response)):
            return .dispatched(.success(response.state.toHistoryState()))
        case .failure(let error):
            return .dispatched(.failure(error))
        }
    }

    func getGeofences(_ chave: String) async -> AppResult<[GeofenceCircle]> {
        let now = clock.now()
        let cachedHit: [GeofenceCircle]? = lock.withLock {
            guard let cache = geofenceCache, geofenceCachedChave == chave,
                  let at = geofenceCachedAt, now.timeIntervalSince(at) < geofenceCacheTTL else { return nil }
            return cache
        }
        if let cachedHit { return .success(cachedHit) }

        let result = await safeApiCall { try await api.getGeofences(chave).locations.map { $0.toDomain() } }
        if case .success(let data) = result {        // cacheia só em sucesso
            lock.withLock {
                geofenceCache = data; geofenceCachedChave = chave; geofenceCachedAt = now
            }
        }
        return result
    }

    func invalidateGeofenceCache() {
        lock.withLock {
            geofenceCache = nil
            geofenceCachedChave = nil
            geofenceCachedAt = nil
        }
    }
}

private func dispatchAuthorization(
    for effectGuard: AutomaticActivitiesEffectGuard
) -> HTTPRequestDispatchAuthorization {
    HTTPRequestDispatchAuthorization(performIfAuthorized: { operation in
        effectGuard.performIfCurrent(operation)
    })
}

// MARK: - DTO → domínio (mappers 1:1, exatos do CheckRepositoryImpl.kt)

private extension WebCheckHistoryResponse {
    // getState/getHistory: hasCurrentDayCheckin e transportEnabled vêm DIRETO do DTO.
    func toDomain() -> HistoryState {
        HistoryState(found: found, chave: chave, projeto: projeto,
                     currentAction: currentAction?.toDomain(), currentLocal: currentLocal,
                     hasCurrentDayCheckin: hasCurrentDayCheckin,
                     lastCheckinAt: ISOInstant.parse(lastCheckinAt),
                     lastCheckoutAt: ISOInstant.parse(lastCheckoutAt),
                     transportEnabled: transportEnabled)
    }
}

private extension WebCheckHistoryItemDto {
    func toDomain() -> CheckHistoryEntry {
        CheckHistoryEntry(action: action.toDomain(), projeto: projeto, local: local,
                          time: ISOInstant.parse(time), informe: informe.toDomain())
    }
}

private extension WebLocationMatchResponse {
    func toDomain() -> LocationMatch {
        LocationMatch(matched: matched, resolvedLocal: resolvedLocal, label: label, status: status.toDomain(),
                      message: message, accuracyMeters: accuracyMeters, accuracyThresholdMeters: accuracyThresholdMeters,
                      minimumCheckoutDistanceMeters: minimumCheckoutDistanceMeters,
                      nearestWorkplaceDistanceMeters: nearestWorkplaceDistanceMeters)
    }
}

private extension MobileSyncStateResponse {
    // submit: DOIS deltas vs o mapper de history — hasCurrentDayCheckin DERIVADO, transportEnabled HARDCODED.
    func toHistoryState() -> HistoryState {
        HistoryState(found: found, chave: chave, projeto: projeto,
                     currentAction: currentAction?.toDomain(), currentLocal: currentLocal,
                     hasCurrentDayCheckin: currentAction == .checkin,
                     lastCheckinAt: ISOInstant.parse(lastCheckinAt),
                     lastCheckoutAt: ISOInstant.parse(lastCheckoutAt),
                     transportEnabled: false)
    }
}

private extension GeofenceCircleDto {
    func toDomain() -> GeofenceCircle {
        GeofenceCircle(id: id, local: local, centerLat: centerLat, centerLng: centerLng, radiusMeters: radiusMeters)
    }
}
