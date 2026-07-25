import Foundation

/// Projeto (catálogo) — port de domain/model Project (id, name, transportEnabled).
struct Project: Sendable, Equatable {
    let id: Int
    let name: String
    let transportEnabled: Bool
}

/// Lista o catálogo de projetos (para o dialog de autocadastro). Impl concreta no slice de projetos.
protocol ProjectListing: Sendable {
    func listProjects() async -> AppResult<[Project]>
}

/// Dispara o orquestrador (narrow seam para o `onForegroundResume`).
protocol OrchestratorRunning: Sendable {
    func runOnce(_ trigger: OrchestratorTrigger) async
    /// Cancela o episódio/retry de baixa precisão e invalida resultados automáticos ainda em voo.
    func invalidateAccuracyRetry() async
    /// Troca de chave/projeto/toggle invalida todos os trabalhos ligados ao contexto anterior.
    func invalidateAutomationContext() async
    /// Edição da configuração invalida somente um adiamento ainda não ativado.
    func scheduledPauseSettingsDidChange() async
    /// Um submit aceito só é confirmado pelo `HistoryState` devolvido pelo servidor.
    func acceptedCheck(
        chave: String,
        project: String,
        action: CheckAction,
        newState: HistoryState
    ) async
    /// GET/SSE confirmado, inclusive quando a atividade veio de outro cliente.
    func confirmedState(chave: String, newState: HistoryState) async
}

extension OrchestratorRunning {
    func invalidateAutomationContext() async {
        await invalidateAccuracyRetry()
    }
    func scheduledPauseSettingsDidChange() async {}
    func acceptedCheck(
        chave: String,
        project: String,
        action: CheckAction,
        newState: HistoryState
    ) async {
        await invalidateAccuracyRetry()
    }
    func confirmedState(chave: String, newState: HistoryState) async {}
}
extension BackgroundCheckOrchestrator: OrchestratorRunning {}

/// Stream SSE de eventos de check (para o `startCheckStream`).
protocol CheckEventStreaming: Sendable {
    func events(chave: String) -> AsyncStream<String>
}
extension CheckEventStream: CheckEventStreaming {}
