/// Contrato não-throwing do journal. Falhas de diagnóstico nunca podem alterar a decisão de negócio.
protocol EvaluationJournaling: Sendable {
    func begin(_ start: EvaluationStart) async
    func coalesce(_ event: EvaluationCoalescence) async
    func advance(_ progress: EvaluationProgress) async
    func recordOwnerExpiration(
        evaluationID: EvaluationID,
        owner: EvaluationJournalOwnerKind,
        cancelledCanonicalWork: Bool
    ) async
    func finish(id: EvaluationID, terminal: EvaluationTerminal) async
    func reconcileOrphans() async
    func recent(limit: Int) async -> [EvaluationRecord]
    func clear() async
}

extension EvaluationJournaling {
    func advance(_ progress: EvaluationProgress) async {}
    func recordOwnerExpiration(
        evaluationID: EvaluationID,
        owner: EvaluationJournalOwnerKind,
        cancelledCanonicalWork: Bool
    ) async {}
}

/// Preview/fakes não fazem I/O nem iniciam qualquer caminho funcional.
struct NoopEvaluationJournal: EvaluationJournaling {
    func begin(_ start: EvaluationStart) async {}
    func coalesce(_ event: EvaluationCoalescence) async {}
    func advance(_ progress: EvaluationProgress) async {}
    func recordOwnerExpiration(
        evaluationID: EvaluationID,
        owner: EvaluationJournalOwnerKind,
        cancelledCanonicalWork: Bool
    ) async {}
    func finish(id: EvaluationID, terminal: EvaluationTerminal) async {}
    func reconcileOrphans() async {}
    func recent(limit: Int) async -> [EvaluationRecord] { [] }
    func clear() async {}
}
