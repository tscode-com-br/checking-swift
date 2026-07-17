import Foundation

/// Implementação viva de `ProjectRepository` — port de data/repository/ProjectRepositoryImpl.kt.
struct ProjectRepositoryLive: ProjectRepository {
    let api: any ProjectsApi

    func listProjects() async -> AppResult<[Project]> {
        await safeApiCall {
            try await api.listProjects().map { row in
                Project(id: row.id, name: row.name, transportEnabled: row.transportEnabled)
            }
        }
    }

    func getUserProjects() async -> AppResult<UserProjects> {
        await safeApiCall {
            let r = try await api.getUserProjects()
            return UserProjects(projects: r.projects, activeProject: r.activeProject)
        }
    }

    func updateUserProjects(_ projectNames: [String]) async -> AppResult<UserProjects> {
        await safeApiCall {
            let r = try await api.updateUserProjects(WebUserProjectsUpdateRequest(projects: projectNames))
            return UserProjects(projects: r.projects, activeProject: r.activeProject)
        }
    }

    func updateActiveProject(_ projectName: String) async -> AppResult<UserProjects> {
        await safeApiCall {
            let r = try await api.updateActiveProject(WebProjectUpdateRequest(project: projectName))
            return UserProjects(projects: r.projects, activeProject: r.activeProject)
        }
    }
}
