import Foundation

/// Executa um único owner de `BGAppRefresh` sem depender de `BackgroundTasks`.
///
/// O adapter de `BGTask` fica no `AppDelegate`; este controller recebe apenas closures `Sendable`, o
/// registration que será associado à avaliação canônica e o callback exactly-once do sistema. Assim os
/// testes exercitam admissão pending/coalesced, expiração e reagendamento sem fabricar um `BGTask` real.
struct BGAppRefreshExecutionController: Sendable {
    typealias EvaluationStarter = @Sendable (
        _ trigger: OrchestratorTrigger,
        _ ownerRegistration: BackgroundWorkOwnerRegistration
    ) async -> EvaluationTicket
    typealias RegularRefreshScheduler = @Sendable () -> Void
    typealias SystemCompletion = @Sendable (_ success: Bool) -> Void

    private let startEvaluation: EvaluationStarter
    private let scheduleRegularRefresh: RegularRefreshScheduler

    init(
        startEvaluation: @escaping EvaluationStarter,
        scheduleRegularRefresh: @escaping RegularRefreshScheduler
    ) {
        self.startEvaluation = startEvaluation
        self.scheduleRegularRefresh = scheduleRegularRefresh
    }

    /// Inicia o trabalho de forma síncrona para que o caller possa instalar imediatamente
    /// `BGTask.expirationHandler = { handle.expire() }`, antes de qualquer `await` de admissão.
    func start(
        trigger: OrchestratorTrigger,
        completion: @escaping SystemCompletion
    ) -> BGAppRefreshExecutionHandle {
        let registration = BackgroundWorkOwnerRegistration(kind: .bgAppRefresh)
        let lateExpirationRecorder = BGAppRefreshLateExpirationRecorder()
        let finalizer = BGAppRefreshExecutionFinalizer(
            scheduleRegularRefresh: scheduleRegularRefresh,
            completion: completion
        )

        // Esta task é o único observer criado pelo controller. O ticket é a task/promessa canônica do
        // orquestrador: aguardar aqui nunca cancela nem duplica a avaliação compartilhada.
        Task {
            let ticket = await startEvaluation(trigger, registration)
            lateExpirationRecorder.bind(ticket)

            // Se a expiração ocorreu antes de `startEvaluation` terminar e só pôde ser aplicada quando
            // o ownership já estava fechado, o handle ainda precisa ligar o owner ao ticket canônico.
            // Em expirações normais o próprio orquestrador registra o snapshot antes do terminal.
            if registration.appliedExpirationResult == .ignored {
                lateExpirationRecorder.observe(.applied(.ignored))
            }

            // A expiração pode vencer antes de o actor do orquestrador associar o registration. Se outro
            // owner já sustentava o trabalho coalescido, este BGTask não precisa reter um waiter até o
            // terminal alheio; sua própria conclusão é false e a avaliação segue intacta.
            if registration.appliedExpirationResult == .workContinues {
                _ = registration.release()
                finalizer.finish(success: false)
                return
            }

            // `completion()` representa o terminal da avaliação canônica, não apenas sua admissão. Se a
            // expiração deste owner cancelou o último orçamento, aguardá-lo garante que journal/cleanup
            // terminem antes de reportar false ao sistema.
            let evaluationCompletion = await ticket.completion()

            // `release()` lineariza terminal normal contra expiration. Se expiration venceu, a razão já
            // foi registrada; se release venceu, uma expiration tardia é ignorada pelo registration.
            _ = registration.release()
            let ownerExpired = registration.expirationReason != nil
            let success = !ownerExpired
                && BGTaskCompletionPolicy.success(for: evaluationCompletion)
            if ownerExpired {
                // A escrita é pequena, sanitizada e idempotente; aguardar somente quando existe a
                // corrida tardia evita completar o BGTask sem a evidência prometida no journal.
                await lateExpirationRecorder.waitForRecord()
            }
            finalizer.finish(success: success)
        }

        return BGAppRefreshExecutionHandle(
            registration: registration,
            lateExpirationRecorder: lateExpirationRecorder,
            finalizer: finalizer
        )
    }
}

/// Handle independente do framework que pode ser capturado diretamente pelo expiration handler nativo.
final class BGAppRefreshExecutionHandle: Sendable {
    private let registration: BackgroundWorkOwnerRegistration
    private let lateExpirationRecorder: BGAppRefreshLateExpirationRecorder
    private let finalizer: BGAppRefreshExecutionFinalizer

    fileprivate init(
        registration: BackgroundWorkOwnerRegistration,
        lateExpirationRecorder: BGAppRefreshLateExpirationRecorder,
        finalizer: BGAppRefreshExecutionFinalizer
    ) {
        self.registration = registration
        self.lateExpirationRecorder = lateExpirationRecorder
        self.finalizer = finalizer
    }

    /// Expira somente este owner. Quando outro owner continua sustentando a avaliação, o callback do
    /// sistema pode terminar false imediatamente; quando este era o último, a task do controller aguarda
    /// o terminal cancelado e o journal antes de completar.
    @discardableResult
    func expire() -> BackgroundWorkOwnerRegistrationExpirationResult {
        let result = registration.expire(reason: .bgTaskExpired)
        lateExpirationRecorder.observe(result)
        if result == .applied(.workContinues) {
            finalizer.finish(success: false)
        }
        return result
    }

    /// Aguarda somente a conclusão deste owner de BGTask. Cancelar o caller não cancela a avaliação
    /// canônica, o finalizador nem outros waiters.
    func completion() async {
        await finalizer.waitForCompletion()
    }
}

/// Registra somente a expiração que venceu depois do fechamento lógico do ownership. Nesse caso o
/// snapshot canônico já foi consumido, mas o ticket ainda referencia o record e pode anexar o diagnóstico
/// monotônico antes da conclusão do BGTask. O lock também cobre expiração anterior ao retorno do ticket.
private final class BGAppRefreshLateExpirationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ticket: EvaluationTicket?
    private var shouldRecord = false
    private var recordTask: Task<Void, Never>?

    func bind(_ ticket: EvaluationTicket) {
        lock.withLock {
            self.ticket = ticket
            startRecordIfNeededLocked()
        }
    }

    func observe(_ result: BackgroundWorkOwnerRegistrationExpirationResult) {
        guard result == .applied(.ignored) else { return }
        lock.withLock {
            shouldRecord = true
            startRecordIfNeededLocked()
        }
    }

    func waitForRecord() async {
        let task = lock.withLock { recordTask }
        await task?.value
    }

    private func startRecordIfNeededLocked() {
        guard shouldRecord,
              recordTask == nil,
              let ticket else { return }
        recordTask = Task {
            await ticket.recordOwnerExpiration(
                owner: .bgAppRefresh,
                cancelledCanonicalWork: false
            )
        }
    }
}

/// Une reagendamento e `setTaskCompleted` em um único caminho first-wins. O lock protege apenas a disputa;
/// closures potencialmente reentrantes são executadas fora dele.
private final class BGAppRefreshExecutionFinalizer: @unchecked Sendable {
    private let lock = NSLock()
    private let scheduleRegularRefresh: BGAppRefreshExecutionController.RegularRefreshScheduler
    private let completionGate: BGTaskCompletionGate
    private let signal = BGAppRefreshExecutionCompletionSignal()
    private var didFinish = false

    init(
        scheduleRegularRefresh: @escaping BGAppRefreshExecutionController.RegularRefreshScheduler,
        completion: @escaping BGAppRefreshExecutionController.SystemCompletion
    ) {
        self.scheduleRegularRefresh = scheduleRegularRefresh
        completionGate = BGTaskCompletionGate(completion: completion)
    }

    func finish(success: Bool) {
        let didWin = lock.withLock {
            guard !didFinish else { return false }
            didFinish = true
            return true
        }
        guard didWin else { return }

        // O próximo request é submetido em todo terminal, inclusive expiração/falha. O scheduler mantém
        // os deadlines persistidos de accuracy retry e pausa; este controller não inventa intervalo.
        scheduleRegularRefresh()
        _ = completionGate.complete(success: success)
        signal.resolve()
    }

    func waitForCompletion() async {
        await signal.wait()
    }
}

/// Vários callers observam a mesma task canônica, sem uma lista de continuations por owner.
private final class BGAppRefreshExecutionCompletionSignal: Sendable {
    private let completionTask: Task<Void, Never>
    private let oneShot: BGAppRefreshExecutionOneShot

    init() {
        let oneShot = BGAppRefreshExecutionOneShot()
        self.oneShot = oneShot
        completionTask = Task { await oneShot.wait() }
    }

    func wait() async {
        await completionTask.value
    }

    func resolve() {
        oneShot.resolve()
    }
}

/// Source síncrono protegido por lock. Existe um único waiter canônico (a task do signal); qualquer
/// quantidade de callers aguarda essa mesma task. A continuation sempre é retomada fora do lock.
private final class BGAppRefreshExecutionOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let resolved = lock.withLock {
                guard !isResolved else { return true }
                precondition(
                    self.continuation == nil,
                    "BGAppRefreshExecutionOneShot has more than one canonical waiter."
                )
                self.continuation = continuation
                return false
            }
            if resolved {
                continuation.resume()
            }
        }
    }

    func resolve() {
        let continuation = lock.withLock {
            () -> CheckedContinuation<Void, Never>? in
            guard !isResolved else { return nil }
            isResolved = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}
