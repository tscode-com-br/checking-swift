import Foundation

/// Implementação viva de `AuthRepository` — port de data/repository/AuthRepositoryImpl.kt (mapeamento §4).
struct AuthRepositoryLive: AuthRepository {
    let api: any AuthApi
    let checkRepository: any CheckRepository      // getHistory (o Kotlin usa checkApi; delega a getState)
    let cookieStore: any SessionCookieStore

    func getStatus(_ chave: String) async -> AppResult<AuthStatus> {
        await safeApiCall {
            let r = try await api.getStatus(chave)
            // queueFull NÃO é setado (default false).
            return AuthStatus(found: r.found, chave: r.chave, hasPassword: r.hasPassword,
                              authenticated: r.authenticated, message: r.message, pendingApproval: r.pendingApproval)
        }
    }

    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus> {
        await safeApiCall {
            let r = try await api.login(WebPasswordLoginRequest(chave: chave, senha: password))
            return AuthStatus(found: true, chave: chave, hasPassword: r.hasPassword, authenticated: r.authenticated, message: r.message)
        }
    }

    func registerPassword(_ chave: String, _ project: String?, _ password: String) async -> AppResult<AuthStatus> {
        await safeApiCall {
            let r = try await api.registerPassword(WebPasswordRegisterRequest(chave: chave, projeto: project, senha: password))
            return AuthStatus(found: true, chave: chave, hasPassword: r.hasPassword, authenticated: r.authenticated, message: r.message)
        }
    }

    func changePassword(_ chave: String, _ oldPassword: String, _ newPassword: String) async -> AppResult<AuthStatus> {
        await safeApiCall {
            let r = try await api.changePassword(WebPasswordChangeRequest(chave: chave, senhaAntiga: oldPassword, novaSenha: newPassword))
            return AuthStatus(found: true, chave: chave, hasPassword: r.hasPassword, authenticated: r.authenticated, message: r.message)
        }
    }

    func selfRegister(_ chave: String, _ nome: String, _ projetos: [String], _ email: String?, _ password: String, _ confirmPassword: String) async -> AppResult<AuthStatus> {
        await safeApiCall {
            let emailArg = email.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let r = try await api.registerUser(WebUserSelfRegistrationRequest(
                chave: chave, nome: nome, projetos: projetos, email: emailArg, senha: password, confirmarSenha: confirmPassword))
            // found = SÓ "registered" (pending/queue_full não têm User ainda); chave do ARGUMENTO.
            return AuthStatus(found: r.status == "registered", chave: chave, hasPassword: r.hasPassword,
                              authenticated: r.authenticated, message: r.message,
                              pendingApproval: r.pendingApproval, queueFull: r.queueFull)
        }
    }

    /// SEMPRE limpa o cookie e SEMPRE retorna sucesso (engole a exceção do POST).
    func logout() async -> AppResult<Void> {
        _ = await safeApiCall { try? await api.logout() }
        cookieStore.clear()
        return .success(())
    }

    /// Limpa o cookie SÓ em sucesso — um 409 (admin/abridor de acidente) mantém a conta e a sessão.
    func deleteAccount() async -> AppResult<Void> {
        let result = await safeApiCall { try await api.deleteAccount() }
        if case .success = result { cookieStore.clear() }
        return result.map { _ in () }
    }

    func getHistory(_ chave: String) async -> AppResult<HistoryState> {
        await checkRepository.getState(chave)
    }
}
