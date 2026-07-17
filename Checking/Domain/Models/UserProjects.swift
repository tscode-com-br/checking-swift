import Foundation

/// Projetos do usuário — port de domain/model/ProjectModels (UserProjects).
struct UserProjects: Sendable, Equatable {
    var projects: [String]
    var activeProject: String
}
