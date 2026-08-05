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
        guard !Task.isCancelled else { return .retry }
        var pass = 0
        var finalAcceptedCheck: AcceptedCheck?
        while pass < Self.maxPasses {
            guard !Task.isCancelled else { return .retry }
            let pending = await queue.peekAll()
            guard !Task.isCancelled else { return .retry }
            if pending.isEmpty {
                guard await notifyAcceptedCheck(finalAcceptedCheck) else { return .retry }
                return .completed
            }
            // Âncora da janela FORMS 24h = evento mais novo da fila (NÃO o relógio). Estável entre passes.
            let newest = pending.map(\.capturedAtEpochMs).max()!
            guard !Task.isCancelled else { return .retry }
            logger.logSyncing(pending.count)
            for event in pending {
                guard !Task.isCancelled else { return .retry }
                let result = await replay(event, newest)
                // `safeApiCall` reduz CancellationError a `.unknown`; este fence impede que essa perda de
                // resposta seja confundida com falha permanente e remova o evento durável.
                guard !Task.isCancelled else { return .retry }
                if let accepted = result.acceptedCheck {
                    finalAcceptedCheck = accepted
                }
                switch result.outcome {
                case .done, .drop:
                    guard !Task.isCancelled else { return .retry }
                    await queue.remove(event.clientEventId)
                    guard !Task.isCancelled else { return .retry }
                case .retry:       return .retry                     // aborta o drain INTEIRO; reagenda depois
                }
            }
            pass += 1
        }
        guard !Task.isCancelled else { return .retry }
        let remainingCount = await queue.size()
        guard !Task.isCancelled, remainingCount == 0 else { return .retry }
        guard await notifyAcceptedCheck(finalAcceptedCheck) else { return .retry }
        return .completed
    }

    private func replay(_ event: PendingCheckEvent, _ newest: Int64) async -> ReplayResult {
        switch event {
        case .decided(let decided): return await replayDecided(decided, newest)
        case .raw(let raw):         return await replayRaw(raw, newest)
        }
    }

    private func replayDecided(_ e: PendingCheckEvent.Decided, _ newest: Int64) async -> ReplayResult {
        guard !Task.isCancelled else {
            return ReplayResult(outcome: .retry, acceptedCheck: nil)
        }
        let action: CheckAction = e.action == "checkout" ? .checkOut : .checkIn
        let informe: InformeType = e.informe == "retroativo" ? .retroativo : .normal
        let result = await repository.submit(
            chave: e.chave, projeto: e.projeto, action: action, local: e.local, informe: informe,
            eventTime: Self.instant(e.capturedAtEpochMs), clientEventId: e.clientEventId,
            fillForms: fillFormsFor(e.capturedAtEpochMs, newest))
        guard !Task.isCancelled else {
            return ReplayResult(outcome: .retry, acceptedCheck: nil)
        }
        let replay = replaySubmitResult(
            result,
            chave: e.chave,
            project: e.projeto,
            action: action)
        guard !Task.isCancelled else {
            return ReplayResult(outcome: .retry, acceptedCheck: nil)
        }
        logReplayOutcome(replay.outcome, action, e.local)
        return replay
    }

    private func replayRaw(_ e: PendingCheckEvent.Raw, _ newest: Int64) async -> ReplayResult {
        guard !Task.isCancelled else {
            return ReplayResult(outcome: .retry, acceptedCheck: nil)
        }
        let match: LocationMatch
        let matchResult = await repository.matchLocation(
            e.latitude,
            e.longitude,
            e.accuracyMeters
        )
        guard !Task.isCancelled else {
            return ReplayResult(outcome: .retry, acceptedCheck: nil)
        }
        switch matchResult {
        case .success(let value): match = value
        case .failure(let error): return ReplayResult(outcome: failureOutcome(error), acceptedCheck: nil)
        }
        guard !Task.isCancelled else {
            return ReplayResult(outcome: .retry, acceptedCheck: nil)
        }
        let state: HistoryState
        let stateResult = await repository.getState(e.chave)
        guard !Task.isCancelled else {
            return ReplayResult(outcome: .retry, acceptedCheck: nil)
        }
        switch stateResult {
        case .success(let value): state = value
        case .failure(let error): return ReplayResult(outcome: failureOutcome(error), acceptedCheck: nil)
        }
        guard !Task.isCancelled else {
            return ReplayResult(outcome: .retry, acceptedCheck: nil)
        }
        let options: LocationOptions
        let optionsResult = await repository.getLocations()
        guard !Task.isCancelled else {
            return ReplayResult(outcome: .retry, acceptedCheck: nil)
        }
        switch optionsResult {
        case .success(let value): options = value
        case .failure(let error): return ReplayResult(outcome: failureOutcome(error), acceptedCheck: nil)
        }
        guard let activity = resolveAutomaticActivityForMatch(match, state, options.mixedZoneIntervalMinutes) else {
            return ReplayResult(outcome: .done, acceptedCheck: nil) // sem ação → consome sem submit
        }
        guard !Task.isCancelled else {
            return ReplayResult(outcome: .retry, acceptedCheck: nil)
        }
        let result = await repository.submit(
            chave: e.chave, projeto: e.projeto, action: activity.action, local: activity.local, informe: .normal,
            eventTime: Self.instant(e.capturedAtEpochMs), clientEventId: e.clientEventId,
            fillForms: fillFormsFor(e.capturedAtEpochMs, newest))
        guard !Task.isCancelled else {
            return ReplayResult(outcome: .retry, acceptedCheck: nil)
        }
        let replay = replaySubmitResult(
            result,
            chave: e.chave,
            project: e.projeto,
            action: activity.action)
        guard !Task.isCancelled else {
            return ReplayResult(outcome: .retry, acceptedCheck: nil)
        }
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

    private func notifyAcceptedCheck(_ accepted: AcceptedCheck?) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let accepted, let acceptedCheckObserver else { return true }
        await acceptedCheckObserver.acceptedCheck(
            chave: accepted.chave,
            project: accepted.project,
            action: accepted.action,
            newState: accepted.state)
        return !Task.isCancelled
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
        guard !Task.isCancelled else { return }
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
