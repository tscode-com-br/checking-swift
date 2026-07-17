import Foundation

/// Repositório de projetos — port de domain/repository/ProjectRepository.kt. Refina `ProjectListing`
/// (listProjects) — assim `ProjectRepositoryLive` também serve o wizard de autocadastro do `CheckViewModel`.
protocol ProjectRepository: ProjectListing {
    // listProjects herdado de ProjectListing
    func getUserProjects() async -> AppResult<UserProjects>
    func updateUserProjects(_ projectNames: [String]) async -> AppResult<UserProjects>
    func updateActiveProject(_ projectName: String) async -> AppResult<UserProjects>
}
