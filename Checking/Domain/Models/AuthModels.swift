import Foundation

/// Status de autenticação/conta — port de domain/model/AuthModels.kt (`AuthStatus`).
/// Ver port_spec_auth_lifecycle.md §2.
struct AuthStatus: Sendable, Equatable {
    var found: Bool
    var chave: String
    var hasPassword: Bool
    var authenticated: Bool
    var message: String
    var pendingApproval: Bool = false   // autocadastro aguardando aprovação (sem User ainda)
    var queueFull: Bool = false         // fila de aprovação cheia (transitório; só do selfRegister)
}
