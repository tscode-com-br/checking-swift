import Foundation

/// Validade efêmera compartilhada por todos os snapshots da mesma geração. Não contém identidade,
/// credenciais ou dado persistível; existe apenas para permitir um último fence síncrono imediatamente
/// antes de um side effect que não pode suspender para consultar o actor.
final class AuthSessionGenerationValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Bool

    init(isCurrent: Bool = true) {
        current = isCurrent
    }

    var isCurrentNow: Bool {
        lock.withLock { current }
    }

    func activate() {
        lock.withLock { current = true }
    }

    func invalidate() {
        lock.withLock { current = false }
    }

    /// Lineariza um efeito síncrono mínimo com a revogação. O lock desta validity é sempre adquirido
    /// primeiro e nunca atravessa `await`; o efeito não pode reentrar no coordenador de sessão.
    func performIfCurrent(_ operation: () -> Void) -> Bool {
        lock.withLock {
            guard current else { return false }
            operation()
            return true
        }
    }
}

/// Geração efêmera da identidade de sessão. Existe somente em memória e não identifica instalação,
/// usuário ou requisição. Callers usam o valor opaco apenas para rejeitar respostas de uma identidade
/// que deixou de ser atual enquanto havia um `await` em curso.
struct AuthSessionGeneration: Sendable, Equatable {
    let value: UInt64
    private let validity: AuthSessionGenerationValidity

    init(value: UInt64) {
        self.init(value: value, validity: AuthSessionGenerationValidity())
    }

    init(value: UInt64, validity: AuthSessionGenerationValidity) {
        self.value = value
        self.validity = validity
    }

    /// Fence síncrono e best-effort para o instante imediatamente anterior a match/enqueue/submit.
    /// A validação assíncrona por geração continua obrigatória ao redor dos demais `await`.
    var isCurrentNow: Bool {
        validity.isCurrentNow
    }

    /// Executa um efeito síncrono somente se esta geração ainda for atual no mesmo ponto de linearização.
    /// A closure deve ser curta, não suspender e não chamar `AuthSessionCoordinating`.
    func performIfCurrent(_ operation: () -> Void) -> Bool {
        validity.performIfCurrent(operation)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // `value` permanece a identidade pública do snapshot; o token apenas revoga side effects em voo.
        lhs.value == rhs.value
    }
}

/// Token opaco de uma transição já invalidada sincronicamente. O token garante que apenas o owner mais
/// recente consiga reabrir o uso da sessão quando invalidações rápidas forem coalescidas.
struct AuthSessionInvalidation: Sendable, Equatable {
    let value: UInt64
}

/// Terminal tipado de uma única tentativa de relogin silencioso. O coordenador nunca repete o login por
/// conta própria: o caller decide o terminal da avaliação depois desta tentativa compartilhada.
enum SilentReloginResult: Sendable, Equatable {
    case refreshed(AuthStatus)
    case missingPassword
    case failed(ApiError)
    case staleContext
}

/// Resultado da exclusão remota sob a autoridade de sessão. Sucesso mantém um barrier aberto até o
/// caller terminar o wipe local; falha preserva integralmente a identidade anterior.
enum DeleteAccountSessionResult: Sendable, Equatable {
    case deleted(AuthSessionInvalidation)
    case failed(ApiError)
    case staleContext
}

/// Autoridade environment-owned para as mutações que podem substituir ou limpar a sessão HTTP.
///
/// A API é deliberadamente fechada: não aceita closures arbitrárias e não conhece lifecycle, UI nem o
/// barrier do orquestrador. Isso mantém a ordem de dependências unidirecional e evita deadlocks entre a
/// serialização da sessão e a invalidação do contexto automático.
protocol AuthSessionCoordinating: Sendable {
    /// Invalida de forma síncrona a geração lógica e os `Set-Cookie` de requests já em voo. Callers de
    /// troca/logout/wipe chamam este método antes do primeiro ponto de suspensão da transição.
    func invalidateCurrentIdentity() -> AuthSessionInvalidation

    /// Aguarda todas as mutações já publicadas no tail e devolve a geração que permaneceu estável.
    /// Não limpa cookie, não faz login e não mantém exclusão mútua durante a futura chamada de rede.
    func useCurrentSession() async -> AuthSessionGeneration

    /// Confirma se um resultado obtido através de `await` ainda pertence à mesma identidade lógica.
    func isCurrent(_ generation: AuthSessionGeneration) async -> Bool

    /// Aguarda um tail estável sem iniciar trabalho de rede. Usado somente para drain ordenado de wipe.
    func awaitIdle() async

    // Operações capazes de receber Set-Cookie. Todas compartilham o mesmo tail serial.
    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus>
    func registerPassword(
        _ chave: String,
        _ project: String?,
        _ password: String
    ) async -> AppResult<AuthStatus>
    func changePassword(
        _ chave: String,
        _ oldPassword: String,
        _ newPassword: String
    ) async -> AppResult<AuthStatus>
    func selfRegister(
        _ chave: String,
        _ nome: String,
        _ projetos: [String],
        _ email: String?,
        _ password: String,
        _ confirmPassword: String
    ) async -> AppResult<AuthStatus>

    /// Coalesce refreshes concorrentes da mesma chave e geração em uma única tentativa de login.
    func silentRelogin(_ chave: String) async -> SilentReloginResult

    /// Troca de chave iniciada pelo usuário. Invalida respostas antigas antes de qualquer `await`.
    func replaceIdentity() async

    /// Logout explícito. É separado de `replaceIdentity` para manter o call site auditável.
    func explicitLogout() async

    /// Conclui, em ordem serial, o logout de uma identidade que o caller já invalidou sincronicamente.
    /// Não avança a geração novamente.
    func completeInvalidatedLogout(_ invalidation: AuthSessionInvalidation) async

    /// Fecha um barrier já invalidado quando nenhum POST logout adicional é necessário (por exemplo,
    /// depois de DELETE remoto bem-sucedido, que já limpou a sessão dentro do tail).
    func completeInvalidatedTransition(_ invalidation: AuthSessionInvalidation) async

    /// Exclusão remota: somente o sucesso invalida e limpa a sessão local.
    func deleteAccount() async -> DeleteAccountSessionResult
}
