import Foundation

/// Repositório de auth — port de domain/repository/AuthRepository.kt. Refina `AuthRepositoring` (login),
/// então o seam do orquestrador aceita qualquer `AuthRepository`. Ver port_spec_auth_lifecycle §4.
protocol AuthRepository: AuthRepositoring {
    func getStatus(_ chave: String) async -> AppResult<AuthStatus>
    // login herdado de AuthRepositoring
    func logout() async -> AppResult<Void>
    func deleteAccount() async -> AppResult<Void>              // LGPD art. 18
    func registerPassword(_ chave: String, _ project: String?, _ password: String) async -> AppResult<AuthStatus>
    func changePassword(_ chave: String, _ oldPassword: String, _ newPassword: String) async -> AppResult<AuthStatus>
    func selfRegister(_ chave: String, _ nome: String, _ projetos: [String], _ email: String?, _ password: String, _ confirmPassword: String) async -> AppResult<AuthStatus>
    func getHistory(_ chave: String) async -> AppResult<HistoryState>
}
