import Foundation

/// Contexto efêmero compartilhado por todos os owners capazes de sustentar o mesmo trabalho.
///
/// A primeira razão de cancelamento vence. O handler é instalado no máximo uma vez e é entregue
/// exatamente uma vez, inclusive quando o cancelamento acontece antes da instalação.
final class EvaluationCancellationContext: @unchecked Sendable {
    typealias CancellationHandler = @Sendable (EvaluationCancellationReason) -> Void

    private let lock = NSLock()
    private var cancellationReason: EvaluationCancellationReason?
    private var cancellationHandler: CancellationHandler?
    private var didInstallHandler = false
    private var didDeliverHandler = false
    private var isClosed = false

    var reason: EvaluationCancellationReason? {
        lock.withLock { cancellationReason }
    }

    var isCancelled: Bool {
        lock.withLock { cancellationReason != nil }
    }

    /// Instala o único handler. Se o cancelamento já venceu, a entrega ocorre imediatamente fora do
    /// lock; isso evita perder a expiração sem executar código arbitrário dentro da região crítica.
    @discardableResult
    func installCancellationHandler(
        _ handler: @escaping CancellationHandler
    ) -> Bool {
        let installation = lock.withLock {
            () -> (installed: Bool, pendingReason: EvaluationCancellationReason?) in
            guard !isClosed, !didInstallHandler else { return (false, nil) }
            didInstallHandler = true
            cancellationHandler = handler
            guard let cancellationReason, !didDeliverHandler else { return (true, nil) }
            didDeliverHandler = true
            cancellationHandler = nil
            return (true, cancellationReason)
        }

        guard installation.installed else { return false }
        if let pendingReason = installation.pendingReason {
            handler(pendingReason)
        }
        return true
    }

    /// Registra a razão first-wins. Retorna `true` somente para o caller que efetivou o cancelamento.
    @discardableResult
    func cancel(_ reason: EvaluationCancellationReason) -> Bool {
        let cancellation = lock.withLock {
            () -> (didWin: Bool, delivery: CancellationHandler?) in
            guard !isClosed, cancellationReason == nil else { return (false, nil) }
            cancellationReason = reason
            guard didInstallHandler, !didDeliverHandler else { return (true, nil) }
            didDeliverHandler = true
            defer { cancellationHandler = nil }
            return (true, cancellationHandler)
        }

        cancellation.delivery?(reason)
        return cancellation.didWin
    }

    /// Terminal normal: impede cancelamentos/instalações tardios e rompe a retenção do handler sem
    /// fabricar uma razão. Se um cancelamento já venceu, sua razão permanece disponível para diagnóstico.
    @discardableResult
    func finish() -> Bool {
        lock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            cancellationHandler = nil
            return true
        }
    }
}

/// Slots fixos de ownership. Um trabalho nunca acumula uma lista aberta de leases/waiters.
enum BackgroundWorkOwnerKind: CaseIterable, Hashable, Sendable {
    case bgAppRefresh
    case uiBackgroundTask
    case bgProcessing

    fileprivate var expirationReason: EvaluationCancellationReason {
        switch self {
        case .bgAppRefresh, .bgProcessing:
            .bgTaskExpired
        case .uiBackgroundTask:
            .uiBackgroundTimeExpired
        }
    }
}

/// Token efêmero que individualiza a lease dentro de seu slot. Não é persistido nem identifica usuário,
/// instalação ou avaliação.
struct BackgroundWorkOwnerToken: Hashable, Sendable {
    let kind: BackgroundWorkOwnerKind
    private let id: UUID

    fileprivate init(kind: BackgroundWorkOwnerKind, id: UUID = UUID()) {
        self.kind = kind
        self.id = id
    }
}

enum BackgroundWorkExpirationResult: Sendable, Equatable {
    case ignored
    case workContinues
    case workCancelled
}

enum BackgroundWorkOwnerAttachmentResult: Sendable, Equatable {
    case rejected
    case attached
    case pendingExpirationApplied(BackgroundWorkExpirationResult)
}

enum BackgroundWorkOwnerRegistrationExpirationResult: Sendable, Equatable {
    case ignored
    case pendingAttachment
    case applied(BackgroundWorkExpirationResult)

    var cancelledCanonicalWork: Bool {
        self == .applied(.workCancelled)
    }
}

/// Snapshot sanitizado e bounded para observabilidade. Registra somente categorias fechadas de owner;
/// nunca inclui token, ID de avaliação, identidade, região ou coordenada.
struct BackgroundWorkExpirationSnapshot: Sendable, Equatable {
    let expiredOwners: Set<BackgroundWorkOwnerKind>
    let cancellingOwner: BackgroundWorkOwnerKind?

    var cancelledCanonicalWork: Bool { cancellingOwner != nil }
}

/// Ownership bounded de um trabalho compartilhado. Expirar uma lease remove somente seu token; o
/// cancelamento do trabalho ocorre quando a última lease válida expira. Liberação normal e `finish()`
/// nunca fabricam cancelamento.
final class BackgroundWorkOwnership: @unchecked Sendable {
    static let maximumOwnerCount = BackgroundWorkOwnerKind.allCases.count

    let cancellationContext: EvaluationCancellationContext

    private let lock = NSLock()
    private var owners: [BackgroundWorkOwnerKind: BackgroundWorkOwnerToken] = [:]
    private var expiredOwners: Set<BackgroundWorkOwnerKind> = []
    private var expirationCancellingOwner: BackgroundWorkOwnerKind?
    private var isClosed = false

    init(cancellationContext: EvaluationCancellationContext = EvaluationCancellationContext()) {
        self.cancellationContext = cancellationContext
    }

    var activeOwnerCount: Int {
        lock.withLock { owners.count }
    }

    var isFinished: Bool {
        lock.withLock { isClosed }
    }

    var expirationSnapshot: BackgroundWorkExpirationSnapshot {
        lock.withLock {
            BackgroundWorkExpirationSnapshot(
                expiredOwners: expiredOwners,
                cancellingOwner: expirationCancellingOwner
            )
        }
    }

    /// Admite no máximo um owner por categoria e nunca admite novos owners depois de cancelamento/finish.
    func acquire(_ kind: BackgroundWorkOwnerKind) -> BackgroundWorkOwnerToken? {
        guard !cancellationContext.isCancelled else { return nil }
        let token = lock.withLock { () -> BackgroundWorkOwnerToken? in
            guard !isClosed, owners[kind] == nil else { return nil }
            let token = BackgroundWorkOwnerToken(kind: kind)
            owners[kind] = token
            return token
        }
        guard let token else { return nil }

        // Fecha a corrida em que o contexto foi cancelado entre o primeiro check e a inserção.
        guard !cancellationContext.isCancelled else {
            _ = release(token)
            return nil
        }
        return token
    }

    /// Libera uma lease concluída normalmente. A ausência de owners depois de uma liberação normal não
    /// significa expiração e, portanto, não cancela o contexto.
    @discardableResult
    func release(_ token: BackgroundWorkOwnerToken) -> Bool {
        lock.withLock {
            guard owners[token.kind] == token else { return false }
            owners[token.kind] = nil
            return true
        }
    }

    /// Expira somente o token informado. A razão do último owner é encaminhada ao contexto first-wins.
    func expire(_ token: BackgroundWorkOwnerToken) -> BackgroundWorkExpirationResult {
        expire(token, reason: token.kind.expirationReason)
    }

    /// Variante usada por um registration cuja expiração pode ter ocorrido antes da associação ao
    /// trabalho canônico. A razão continua first-wins no contexto compartilhado.
    func expire(
        _ token: BackgroundWorkOwnerToken,
        reason: EvaluationCancellationReason
    ) -> BackgroundWorkExpirationResult {
        let shouldCancel = lock.withLock { () -> Bool? in
            guard !isClosed, owners[token.kind] == token else { return nil }
            owners[token.kind] = nil
            expiredOwners.insert(token.kind)
            guard owners.isEmpty else { return false }
            // Impede que um novo owner seja admitido entre a decisão "último expirou" e a entrega do
            // cancelamento ao contexto, que ocorre fora do lock para permitir handler reentrante.
            isClosed = true
            expirationCancellingOwner = token.kind
            return true
        }
        guard let shouldCancel else { return .ignored }
        guard shouldCancel else { return .workContinues }
        _ = cancellationContext.cancel(reason)
        return .workCancelled
    }

    /// Invalidação de contexto é global: fecha a ownership, descarta todos os owners e cancela uma vez.
    @discardableResult
    func invalidateContext() -> Bool {
        let shouldCancel = lock.withLock { () -> Bool in
            guard !isClosed else { return false }
            isClosed = true
            owners.removeAll(keepingCapacity: false)
            return true
        }
        guard shouldCancel else { return false }
        return cancellationContext.cancel(.contextInvalidated)
    }

    /// Cancelamento cooperativo externo que não representa expiração de uma lease específica.
    @discardableResult
    func cancelTask() -> Bool {
        cancellationContext.cancel(.taskCancelled)
    }

    /// Terminal normal: fecha novas admissões e libera todos os owners sem mudar o resultado do trabalho.
    @discardableResult
    func finish() -> Bool {
        let didFinish = lock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            owners.removeAll(keepingCapacity: false)
            return true
        }
        // Mesmo se uma expiração já tiver fechado os slots, o terminal canônico precisa soltar qualquer
        // handler ainda retido pelo contexto.
        _ = cancellationContext.finish()
        return didFinish
    }
}

/// One-shot interno. Apenas a task canônica criada pelo registration instala continuation; qualquer
/// quantidade de consumidores pode aguardar essa mesma task sem acumular waiters no registration.
private final class BackgroundWorkExpirationSignal: @unchecked Sendable {
    private enum ImmediateResult {
        case suspended
        case resolved(EvaluationCancellationReason)
        case cancelled
    }

    private let lock = NSLock()
    private var value: EvaluationCancellationReason?
    private var waiterID: UUID?
    private var continuation: CheckedContinuation<EvaluationCancellationReason?, Never>?
    private var cancelledBeforeRegistration: UUID?

    func wait() async -> EvaluationCancellationReason? {
        if Task.isCancelled { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = lock.withLock { () -> ImmediateResult in
                    if let value { return .resolved(value) }
                    if cancelledBeforeRegistration == id || Task.isCancelled {
                        cancelledBeforeRegistration = nil
                        return .cancelled
                    }
                    precondition(
                        waiterID == nil,
                        "BackgroundWorkExpirationSignal accepts one canonical waiter."
                    )
                    waiterID = id
                    self.continuation = continuation
                    return .suspended
                }
                switch immediate {
                case .suspended:
                    break
                case .resolved(let reason):
                    continuation.resume(returning: reason)
                case .cancelled:
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            self.cancelWaiter(id)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        let continuation = lock.withLock {
            () -> CheckedContinuation<EvaluationCancellationReason?, Never>? in
            guard value == nil else { return nil }
            if waiterID == id {
                waiterID = nil
                defer { self.continuation = nil }
                return self.continuation
            }
            if waiterID == nil {
                cancelledBeforeRegistration = id
            }
            return nil
        }
        continuation?.resume(returning: nil)
    }

    func resolve(_ reason: EvaluationCancellationReason) {
        let continuation = lock.withLock {
            () -> CheckedContinuation<EvaluationCancellationReason?, Never>? in
            guard value == nil else { return nil }
            value = reason
            waiterID = nil
            cancelledBeforeRegistration = nil
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: reason)
    }
}

/// Ponte entre o owner do sistema e o ownership de uma avaliação que talvez ainda não tenha sido
/// admitida. A expiração fica registrada antes de qualquer `await`; quando o ticket canônico aparece,
/// `attach` adquire seu token e aplica a expiração pendente sem cancelar leases de outros owners.
final class BackgroundWorkOwnerRegistration: @unchecked Sendable {
    let kind: BackgroundWorkOwnerKind

    private struct Attachment {
        let ownership: BackgroundWorkOwnership
        let token: BackgroundWorkOwnerToken
    }

    private let signal: BackgroundWorkExpirationSignal
    private let lock = NSLock()
    private var attachment: Attachment?
    private var pendingExpiration: EvaluationCancellationReason?
    private var appliedExpiration: BackgroundWorkExpirationResult?
    private var didAttemptAttachment = false
    private var didRequestRelease = false

    init(kind: BackgroundWorkOwnerKind) {
        self.kind = kind
        signal = BackgroundWorkExpirationSignal()
    }

    var expirationReason: EvaluationCancellationReason? {
        lock.withLock { pendingExpiration }
    }

    var isAttached: Bool {
        lock.withLock { attachment != nil }
    }

    var isReleased: Bool {
        lock.withLock { didRequestRelease }
    }

    /// Resultado da aplicação ao ownership canônico. Permanece `nil` enquanto a expiração ainda aguarda
    /// attach; permite ao controller decidir se outro owner sustentou o trabalho ou se deve aguardar seu
    /// terminal cancelado antes de completar o BGTask.
    var appliedExpirationResult: BackgroundWorkExpirationResult? {
        lock.withLock { appliedExpiration }
    }

    /// Associa uma única vez. Se a expiração ganhou durante a admissão, o token é imediatamente expirado
    /// no ownership canônico. Um release antecipado só impede attach quando não existe expiração pendente.
    func waitForExpiration() async -> EvaluationCancellationReason? {
        await signal.wait()
    }

    @discardableResult
    func attach(to ownership: BackgroundWorkOwnership) -> BackgroundWorkOwnerAttachmentResult {
        let action = lock.withLock {
            () -> (token: BackgroundWorkOwnerToken, expiration: EvaluationCancellationReason?)? in
            guard !didAttemptAttachment else { return nil }
            didAttemptAttachment = true
            guard pendingExpiration != nil || !didRequestRelease,
                  let token = ownership.acquire(kind) else { return nil }
            attachment = Attachment(ownership: ownership, token: token)
            return (token, pendingExpiration)
        }
        guard let action else { return .rejected }

        if let expiration = action.expiration {
            let result = ownership.expire(action.token, reason: expiration)
            lock.withLock {
                attachment = nil
                appliedExpiration = result
            }
            return .pendingExpirationApplied(result)
        } else if isReleased {
            _ = ownership.release(action.token)
            lock.withLock { attachment = nil }
            return .rejected
        }
        return .attached
    }

    /// Registra a expiração first-wins e sinaliza o waiter individual. A aplicação ao ownership ocorre
    /// agora, se já attached, ou posteriormente em `attach(to:)`.
    func expire(
        reason: EvaluationCancellationReason
    ) -> BackgroundWorkOwnerRegistrationExpirationResult {
        let expiration = lock.withLock {
            () -> (didWin: Bool, attachment: Attachment?) in
            guard pendingExpiration == nil, !didRequestRelease else { return (false, nil) }
            pendingExpiration = reason
            defer { attachment = nil }
            return (true, attachment)
        }
        guard expiration.didWin else { return .ignored }

        let result: BackgroundWorkOwnerRegistrationExpirationResult
        if let attached = expiration.attachment {
            let applied = attached.ownership.expire(attached.token, reason: reason)
            lock.withLock { appliedExpiration = applied }
            result = .applied(applied)
        } else {
            result = .pendingAttachment
        }
        signal.resolve(reason)
        return result
    }

    /// Liberação idempotente. Quando a expiração já está pendente mas o attach ainda não ocorreu, mantém
    /// apenas a obrigação de aplicar essa expiração futura; nenhuma lease viva é retida.
    @discardableResult
    func release() -> Bool {
        let release = lock.withLock {
            () -> (didRelease: Bool, attachment: Attachment?) in
            guard !didRequestRelease else { return (false, nil) }
            didRequestRelease = true
            guard pendingExpiration == nil else { return (true, nil) }
            defer { attachment = nil }
            return (true, attachment)
        }
        guard release.didRelease else { return false }
        if let attachment = release.attachment {
            _ = attachment.ownership.release(attachment.token)
        }
        return true
    }
}

/// Gate de conclusão do BGTask. A disputa é resolvida sob lock, mas o callback do sistema é executado
/// fora dele para permitir reentrância segura.
final class BGTaskCompletionGate: @unchecked Sendable {
    typealias Completion = @Sendable (Bool) -> Void

    private let lock = NSLock()
    private let completion: Completion
    private var completedSuccess: Bool?

    init(completion: @escaping Completion) {
        self.completion = completion
    }

    var result: Bool? {
        lock.withLock { completedSuccess }
    }

    @discardableResult
    func complete(success: Bool) -> Bool {
        let didWin = lock.withLock {
            guard completedSuccess == nil else { return false }
            completedSuccess = success
            return true
        }
        guard didWin else { return false }
        completion(success)
        return true
    }
}
