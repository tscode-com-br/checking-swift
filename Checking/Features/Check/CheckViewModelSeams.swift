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
}
extension BackgroundCheckOrchestrator: OrchestratorRunning {}

/// Stream SSE de eventos de check (para o `startCheckStream`).
protocol CheckEventStreaming: Sendable {
    func events(chave: String) -> AsyncStream<String>
}
extension CheckEventStream: CheckEventStreaming {}
