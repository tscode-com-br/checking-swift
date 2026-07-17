import Foundation
@testable import Checking

/// Fila fake para os testes do replayer — back por lista mutável, ordenada por captura. (§8)
actor FakePendingCheckQueue: PendingCheckQueueing {
    private(set) var pending: [PendingCheckEvent]
    init(_ pending: [PendingCheckEvent]) { self.pending = pending }
    func peekAll() -> [PendingCheckEvent] { pending.sorted { $0.capturedAtEpochMs < $1.capturedAtEpochMs } }
    func remove(_ clientEventId: String) { pending.removeAll { $0.clientEventId == clientEventId } }
    func size() -> Int { pending.count }
}

/// Spy estrito de `CheckRepository` para o replayer — grava as chamadas de `submit` (tupla completa)
/// e stuba match/state/locations por teste. §8 ("capturar args posicionalmente").
final class ReplaySpyRepository: CheckRepository, @unchecked Sendable {
    struct SubmitCall: Sendable, Equatable {
        let chave: String, projeto: String
        let action: CheckAction
        let local: String?
        let informe: InformeType
        let eventTime: Date
        let clientEventId: String
        let fillForms: Bool
    }

    private let lock = NSLock()
    private var recordedSubmits: [SubmitCall] = []
    var submitCalls: [SubmitCall] { lock.withLock { recordedSubmits } }

    var submitResult: AppResult<HistoryState> =
        .success(HistoryState(found: true, chave: "HR70", projeto: "P80", currentAction: .checkIn, currentLocal: nil,
                              hasCurrentDayCheckin: true, lastCheckinAt: nil, lastCheckoutAt: nil, transportEnabled: false))
    var matchLocationResult: AppResult<LocationMatch> = .failure(.unknown(description: nil))
    var getStateResult: AppResult<HistoryState> = .failure(.unknown(description: nil))
    var getLocationsResult: AppResult<LocationOptions> =
        .success(LocationOptions(items: ["Unidade P80"], accuracyThresholdMeters: 50, mixedZoneIntervalMinutes: 15))

    func matchLocation(_ lat: Double, _ lon: Double, _ accuracyMeters: Double?) async -> AppResult<LocationMatch> { matchLocationResult }
    func getState(_ chave: String) async -> AppResult<HistoryState> { getStateResult }
    func getHistory(_ chave: String) async -> AppResult<[CheckHistoryEntry]> { .success([]) }
    func getLocations() async -> AppResult<LocationOptions> { getLocationsResult }
    func getGeofences(_ chave: String) async -> AppResult<[GeofenceCircle]> { .success([]) }
    func submit(chave: String, projeto: String, action: CheckAction, local: String?, informe: InformeType,
                eventTime: Date, clientEventId: String, fillForms: Bool) async -> AppResult<HistoryState> {
        lock.withLock {
            recordedSubmits.append(SubmitCall(chave: chave, projeto: projeto, action: action, local: local,
                                              informe: informe, eventTime: eventTime, clientEventId: clientEventId, fillForms: fillForms))
        }
        return submitResult
    }
}

/// Logger que grava só as 3 chamadas de sync verificadas (demais via no-op default da extensão).
final class RecordingActivityLogger: ActivityLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSyncing: [Int] = []
    private var recordedSynced: [(kind: ActivityKind, location: String?)] = []
    private var recordedDropped: [ActivityKind] = []
    var syncingCounts: [Int] { lock.withLock { recordedSyncing } }
    var synced: [(kind: ActivityKind, location: String?)] { lock.withLock { recordedSynced } }
    var dropped: [ActivityKind] { lock.withLock { recordedDropped } }

    func logSyncing(_ count: Int) { lock.withLock { recordedSyncing.append(count) } }
    func logSynced(_ kind: ActivityKind, _ location: String?) { lock.withLock { recordedSynced.append((kind, location)) } }
    func logSyncDropped(_ kind: ActivityKind) { lock.withLock { recordedDropped.append(kind) } }
}
