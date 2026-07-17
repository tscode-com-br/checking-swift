import Foundation

enum DrainResult: Sendable, Equatable { case completed, retry }

/// Drena a fila offline — port de PendingCheckReplayer.kt. Lógica pura sobre `CheckRepository` +
/// `ActivityLogging` + a fila; reusa `resolveAutomaticActivityForMatch` (mesmo motor do fluxo ao vivo).
/// Ver port_spec_offline_replay.md §5. Invariantes: exactly-once (id+time originais), janela FORMS 24h
/// ancorada no evento mais novo, RETRY aborta o drain inteiro.
final class PendingCheckReplayer: Sendable {
    static let maxPasses = 5
    static let formsRecencyWindowMs: Int64 = 24 * 60 * 60 * 1000   // 24h

    private enum Outcome { case done, drop, retry }

    private let queue: any PendingCheckQueueing
    private let repository: any CheckRepository
    private let logger: any ActivityLogging

    init(queue: any PendingCheckQueueing, repository: any CheckRepository, logger: any ActivityLogging) {
        self.queue = queue
        self.repository = repository
        self.logger = logger
    }

    func drain() async -> DrainResult {
        var pass = 0
        while pass < Self.maxPasses {
            let pending = await queue.peekAll()
            if pending.isEmpty { return .completed }
            // Âncora da janela FORMS 24h = evento mais novo da fila (NÃO o relógio). Estável entre passes.
            let newest = pending.map(\.capturedAtEpochMs).max()!
            logger.logSyncing(pending.count)
            for event in pending {
                switch await replay(event, newest) {
                case .done, .drop: await queue.remove(event.clientEventId)
                case .retry:       return .retry                     // aborta o drain INTEIRO; reagenda depois
                }
            }
            pass += 1
        }
        return await queue.size() == 0 ? .completed : .retry
    }

    private func replay(_ event: PendingCheckEvent, _ newest: Int64) async -> Outcome {
        switch event {
        case .decided(let decided): return await replayDecided(decided, newest)
        case .raw(let raw):         return await replayRaw(raw, newest)
        }
    }

    private func replayDecided(_ e: PendingCheckEvent.Decided, _ newest: Int64) async -> Outcome {
        let action: CheckAction = e.action == "checkout" ? .checkOut : .checkIn
        let informe: InformeType = e.informe == "retroativo" ? .retroativo : .normal
        let outcome = outcomeOf(await repository.submit(
            chave: e.chave, projeto: e.projeto, action: action, local: e.local, informe: informe,
            eventTime: Self.instant(e.capturedAtEpochMs), clientEventId: e.clientEventId,
            fillForms: fillFormsFor(e.capturedAtEpochMs, newest)))
        logReplayOutcome(outcome, action, e.local)
        return outcome
    }

    private func replayRaw(_ e: PendingCheckEvent.Raw, _ newest: Int64) async -> Outcome {
        let match: LocationMatch
        switch await repository.matchLocation(e.latitude, e.longitude, e.accuracyMeters) {
        case .success(let value): match = value
        case .failure(let error): return failureOutcome(error)
        }
        let state: HistoryState
        switch await repository.getState(e.chave) {
        case .success(let value): state = value
        case .failure(let error): return failureOutcome(error)
        }
        let options: LocationOptions
        switch await repository.getLocations() {
        case .success(let value): options = value
        case .failure(let error): return failureOutcome(error)
        }
        guard let activity = resolveAutomaticActivityForMatch(match, state, options.mixedZoneIntervalMinutes) else {
            return .done                                            // sem ação → consome o evento (sem submit)
        }
        let outcome = outcomeOf(await repository.submit(
            chave: e.chave, projeto: e.projeto, action: activity.action, local: activity.local, informe: .normal,
            eventTime: Self.instant(e.capturedAtEpochMs), clientEventId: e.clientEventId,
            fillForms: fillFormsFor(e.capturedAtEpochMs, newest)))
        logReplayOutcome(outcome, activity.action, activity.local)
        return outcome
    }

    private func fillFormsFor(_ capturedAt: Int64, _ newest: Int64) -> Bool {
        (newest - capturedAt) <= Self.formsRecencyWindowMs
    }

    private func outcomeOf<T>(_ result: AppResult<T>) -> Outcome {
        switch result {
        case .success: return .done
        case .failure(let error): return failureOutcome(error)
        }
    }

    // Transitório → RETRY (mantém): rede, sessão expirada, HTTP ≥500. Permanente → DROP (remove): 4xx, Conflict, Unknown.
    private func failureOutcome(_ error: ApiError) -> Outcome {
        switch error {
        case .network, .unauthorized:  return .retry
        case .http(let status, _):     return status >= 500 ? .retry : .drop
        default:                       return .drop      // conflict, unknown
        }
    }

    private func logReplayOutcome(_ outcome: Outcome, _ action: CheckAction, _ local: String?) {
        let kind: ActivityKind = action == .checkOut ? .checkOut : .checkIn
        switch outcome {
        case .done:  logger.logSynced(kind, local)
        case .drop:  logger.logSyncDropped(kind)
        case .retry: break                               // RETRY não loga (evento fica na fila)
        }
    }

    private static func instant(_ epochMs: Int64) -> Date {
        Date(timeIntervalSince1970: Double(epochMs) / 1000)
    }
}
