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
    private struct AcceptedCheck: Sendable {
        let chave: String
        let project: String
        let action: CheckAction
        let state: HistoryState
    }
    private struct ReplayResult {
        let outcome: Outcome
        let acceptedCheck: AcceptedCheck?
    }

    private let queue: any PendingCheckQueueing
    private let repository: any CheckRepository
    private let logger: any ActivityLogging
    private let acceptedCheckObserver: (any OrchestratorRunning)?

    init(
        queue: any PendingCheckQueueing,
        repository: any CheckRepository,
        logger: any ActivityLogging,
        acceptedCheckObserver: (any OrchestratorRunning)? = nil
    ) {
        self.queue = queue
        self.repository = repository
        self.logger = logger
        self.acceptedCheckObserver = acceptedCheckObserver
    }

    func drain() async -> DrainResult {
        var pass = 0
        var finalAcceptedCheck: AcceptedCheck?
        while pass < Self.maxPasses {
            let pending = await queue.peekAll()
            if pending.isEmpty {
                await notifyAcceptedCheck(finalAcceptedCheck)
                return .completed
            }
            // Âncora da janela FORMS 24h = evento mais novo da fila (NÃO o relógio). Estável entre passes.
            let newest = pending.map(\.capturedAtEpochMs).max()!
            logger.logSyncing(pending.count)
            for event in pending {
                let result = await replay(event, newest)
                if let accepted = result.acceptedCheck {
                    finalAcceptedCheck = accepted
                }
                switch result.outcome {
                case .done, .drop: await queue.remove(event.clientEventId)
                case .retry:       return .retry                     // aborta o drain INTEIRO; reagenda depois
                }
            }
            pass += 1
        }
        guard await queue.size() == 0 else { return .retry }
        await notifyAcceptedCheck(finalAcceptedCheck)
        return .completed
    }

    private func replay(_ event: PendingCheckEvent, _ newest: Int64) async -> ReplayResult {
        switch event {
        case .decided(let decided): return await replayDecided(decided, newest)
        case .raw(let raw):         return await replayRaw(raw, newest)
        }
    }

    private func replayDecided(_ e: PendingCheckEvent.Decided, _ newest: Int64) async -> ReplayResult {
        let action: CheckAction = e.action == "checkout" ? .checkOut : .checkIn
        let informe: InformeType = e.informe == "retroativo" ? .retroativo : .normal
        let result = await repository.submit(
            chave: e.chave, projeto: e.projeto, action: action, local: e.local, informe: informe,
            eventTime: Self.instant(e.capturedAtEpochMs), clientEventId: e.clientEventId,
            fillForms: fillFormsFor(e.capturedAtEpochMs, newest))
        let replay = replaySubmitResult(
            result,
            chave: e.chave,
            project: e.projeto,
            action: action)
        logReplayOutcome(replay.outcome, action, e.local)
        return replay
    }

    private func replayRaw(_ e: PendingCheckEvent.Raw, _ newest: Int64) async -> ReplayResult {
        let match: LocationMatch
        switch await repository.matchLocation(e.latitude, e.longitude, e.accuracyMeters) {
        case .success(let value): match = value
        case .failure(let error): return ReplayResult(outcome: failureOutcome(error), acceptedCheck: nil)
        }
        let state: HistoryState
        switch await repository.getState(e.chave) {
        case .success(let value): state = value
        case .failure(let error): return ReplayResult(outcome: failureOutcome(error), acceptedCheck: nil)
        }
        let options: LocationOptions
        switch await repository.getLocations() {
        case .success(let value): options = value
        case .failure(let error): return ReplayResult(outcome: failureOutcome(error), acceptedCheck: nil)
        }
        guard let activity = resolveAutomaticActivityForMatch(match, state, options.mixedZoneIntervalMinutes) else {
            return ReplayResult(outcome: .done, acceptedCheck: nil) // sem ação → consome sem submit
        }
        let result = await repository.submit(
            chave: e.chave, projeto: e.projeto, action: activity.action, local: activity.local, informe: .normal,
            eventTime: Self.instant(e.capturedAtEpochMs), clientEventId: e.clientEventId,
            fillForms: fillFormsFor(e.capturedAtEpochMs, newest))
        let replay = replaySubmitResult(
            result,
            chave: e.chave,
            project: e.projeto,
            action: activity.action)
        logReplayOutcome(replay.outcome, activity.action, activity.local)
        return replay
    }

    private func fillFormsFor(_ capturedAt: Int64, _ newest: Int64) -> Bool {
        (newest - capturedAt) <= Self.formsRecencyWindowMs
    }

    private func replaySubmitResult(
        _ result: AppResult<HistoryState>,
        chave: String,
        project: String,
        action: CheckAction
    ) -> ReplayResult {
        switch result {
        case .success(let state):
            return ReplayResult(
                outcome: .done,
                acceptedCheck: AcceptedCheck(
                    chave: chave,
                    project: project,
                    action: action,
                    state: state))
        case .failure(let error):
            return ReplayResult(outcome: failureOutcome(error), acceptedCheck: nil)
        }
    }

    private func notifyAcceptedCheck(_ accepted: AcceptedCheck?) async {
        guard let accepted, let acceptedCheckObserver else { return }
        await acceptedCheckObserver.acceptedCheck(
            chave: accepted.chave,
            project: accepted.project,
            action: accepted.action,
            newState: accepted.state)
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
