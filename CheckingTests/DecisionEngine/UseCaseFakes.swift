import Foundation
@testable import Checking

// ── Fakes ─────────────────────────────────────────────────────────────────────

final class FakeCaptureLocation: LocationCapturing, @unchecked Sendable {
    var result: LocationCaptureResult
    init(_ result: LocationCaptureResult) { self.result = result }
    func callAsFunction(_ accuracyThresholdMeters: Int) async -> LocationCaptureResult { result }
}

final class FakeLocationProvider: LocationProvider, @unchecked Sendable {
    var result: LocationCapture
    init(_ result: LocationCapture) { self.result = result }
    func capture(_ accuracyThresholdMeters: Int) async -> LocationCapture { result }
}

final class FakeCheckRepository: CheckRepository, @unchecked Sendable {
    var matchLocationResult: AppResult<LocationMatch> = .failure(.unknown(description: nil))
    var getStateResult: AppResult<HistoryState> = .failure(.unknown(description: nil))
    var getHistoryResult: AppResult<[CheckHistoryEntry]> = .success([])
    var getGeofencesResult: AppResult<[GeofenceCircle]> = .success([])
    var getLocationsResult: AppResult<LocationOptions> =
        .success(LocationOptions(items: ["Unidade P80"], accuracyThresholdMeters: 50, mixedZoneIntervalMinutes: 15))
    var submitResult: AppResult<HistoryState> = .success(ucHistory(.checkIn))
    var submitHandler: (@Sendable (CheckAction, String?) -> AppResult<HistoryState>)?
    private(set) var submitCount = 0
    private(set) var lastSubmitAction: CheckAction?
    private(set) var lastSubmitLocal: String?

    func matchLocation(_ lat: Double, _ lon: Double, _ accuracyMeters: Double?) async -> AppResult<LocationMatch> { matchLocationResult }
    func getState(_ chave: String) async -> AppResult<HistoryState> { getStateResult }
    func getHistory(_ chave: String) async -> AppResult<[CheckHistoryEntry]> { getHistoryResult }
    func getGeofences(_ chave: String) async -> AppResult<[GeofenceCircle]> { getGeofencesResult }
    func getLocations() async -> AppResult<LocationOptions> { getLocationsResult }
    func submit(chave: String, projeto: String, action: CheckAction, local: String?, informe: InformeType,
                eventTime: Date, clientEventId: String, fillForms: Bool) async -> AppResult<HistoryState> {
        submitCount += 1
        lastSubmitAction = action
        lastSubmitLocal = local
        if let handler = submitHandler { return handler(action, local) }
        return submitResult
    }
}

final class FakeOfflineQueue: OfflineCheckQueueing, @unchecked Sendable {
    private(set) var enqueued: [PendingCheckEvent] = []
    func enqueue(_ event: PendingCheckEvent) async { enqueued.append(event) }
}

struct NoopActivityLogger: ActivityLogging {}

final class CapturingDao: ActivityLogDao, @unchecked Sendable {
    struct Boom: Error {}
    let throwOnInsert: Bool
    private(set) var rows: [ActivityLogRow] = []
    init(throwOnInsert: Bool = false) { self.throwOnInsert = throwOnInsert }
    func insert(_ row: ActivityLogRow) throws {
        if throwOnInsert { throw Boom() }
        rows.append(row)
    }
    func deleteOlderThan(_ epochMs: Int64) {}
    func trimToMax(_ max: Int) {}
    func pageNewestFirst(limit: Int, offset: Int) -> [ActivityLogRow] { Array(rows.suffix(limit)) }
    func count() -> Int { rows.count }
    func clearAll() { rows.removeAll() }
}

// ── Builders (nível de caso de uso) ──────────────────────────────────────────

func ucMatch(_ status: MatchStatus, _ resolvedLocal: String? = nil, nearest: Double? = nil) -> LocationMatch {
    LocationMatch(matched: status == .matched, resolvedLocal: resolvedLocal, label: resolvedLocal ?? "",
                  status: status, message: "", accuracyMeters: 10.0, accuracyThresholdMeters: 50,
                  minimumCheckoutDistanceMeters: 2000, nearestWorkplaceDistanceMeters: nearest)
}

func ucHistory(_ last: CheckAction?, currentLocal: String? = nil,
               lastCheckinAt: Date? = nil, lastCheckoutAt: Date? = nil) -> HistoryState {
    HistoryState(found: true, chave: "STSM", projeto: "P80", currentAction: last, currentLocal: currentLocal,
                 hasCurrentDayCheckin: last == .checkIn,
                 lastCheckinAt: lastCheckinAt ?? (last == .checkIn ? Date() : nil),
                 lastCheckoutAt: lastCheckoutAt ?? (last == .checkOut ? Date() : nil),
                 transportEnabled: false)
}
