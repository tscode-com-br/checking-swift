import Foundation

/// A superfície mínima que o handler de `BGProcessing` precisa do ticket canônico de replay.
///
/// O ticket de produção vem de `OfflineSyncCoordinator.drainTicket()`. O protocolo existe apenas para
/// permitir testar expiração e completion sem instanciar um `BGTask` real; ele não representa uma nova
/// fila, não persiste estado e não altera o schema dos eventos offline.
protocol OfflineDrainExecutionTicket: Sendable {
    /// Identidade efêmera do drain canônico, útil somente para correlação em memória/testes.
    var id: UUID { get }

    /// Aguarda o terminal do trabalho canônico. Cancelar este waiter não pode cancelar o drain.
    func completion() async -> DrainResult

    /// Cancela o trabalho canônico somente quando a ownership já concluiu que não resta orçamento válido.
    func cancelCanonicalWork()
}

extension OfflineDrainTicket: OfflineDrainExecutionTicket {}

/// Decisão técnica para o terminal de `BGProcessing`.
struct BGProcessingCompletionDisposition: Sendable, Equatable {
    let success: Bool
    let shouldReschedule: Bool
}

/// Traduz o terminal do replay para o booleano de `BGTask` e para um eventual novo request.
///
/// Tanto `.completed` quanto `.retry` são terminais controlados enquanto não houve cancelamento: em
/// `.retry`, os eventos que ainda precisam de replay permanecem na fila durável e o finalizador solicita
/// o próximo `BGProcessing`. Não reagendamos `.completed`: a fila foi drenada e um wake vazio recorrente
/// mudaria o comportamento de produção. Uma razão de cancelamento sempre prevalece e reporta `false`,
/// com novo request para a fila durável ter outra oportunidade.
enum BGProcessingCompletionPolicy {
    static func disposition(
        for drainResult: DrainResult,
        cancellationReason: EvaluationCancellationReason?
    ) -> BGProcessingCompletionDisposition {
        guard cancellationReason == nil else {
            return BGProcessingCompletionDisposition(success: false, shouldReschedule: true)
        }

        switch drainResult {
        case .completed:
            return BGProcessingCompletionDisposition(success: true, shouldReschedule: false)
        case .retry:
            return BGProcessingCompletionDisposition(success: true, shouldReschedule: true)
        }
    }
}

/// Executa um owner de `BGProcessing` sem depender de `BackgroundTasks`.
///
/// O adapter de framework instala `handle.expire()` no `expirationHandler` síncrono. Este controller
/// aguarda sempre o `OfflineDrainTicket` canônico — nunca uma task de waiter — antes de completar quando
/// ele foi o último orçamento. Se outro owner ainda sustenta o mesmo drain, somente este BGTask termina
/// `false`; o ticket e a fila durável continuam intactos.
struct BGProcessingExecutionController: Sendable {
    typealias DrainStarter = @Sendable () async -> any OfflineDrainExecutionTicket
    typealias ProcessingScheduler = @Sendable () -> Void
    typealias SystemCompletion = @Sendable (_ success: Bool) -> Void

    private let startDrain: DrainStarter
    private let scheduleProcessing: ProcessingScheduler

    init(
        startDrain: @escaping DrainStarter,
        scheduleProcessing: @escaping ProcessingScheduler
    ) {
        self.startDrain = startDrain
        self.scheduleProcessing = scheduleProcessing
    }

    /// Inicia o owner síncronamente para que o caller possa instalar imediatamente o expiration handler.
    ///
    /// `ownership` deve pertencer exclusivamente a este drain canônico. O argumento é injetável para
    /// testar a regra de que a expiração de um owner não pode cancelar um trabalho ainda sustentado por
    /// outro; o uso normal cria uma ownership nova e bounded para este ticket.
    func start(
        ownership: BackgroundWorkOwnership = BackgroundWorkOwnership(),
        completion: @escaping SystemCompletion
    ) -> BGProcessingExecutionHandle {
        let registration = BackgroundWorkOwnerRegistration(kind: .bgProcessing)
        let finalizer = BGProcessingExecutionFinalizer(
            scheduleProcessing: scheduleProcessing,
            completion: completion
        )
        let handle = BGProcessingExecutionHandle(
            registration: registration,
            ownership: ownership,
            finalizer: finalizer
        )

        // A associação ocorre antes de devolver o handle. Assim, uma expiração imediata jamais perde o
        // owner: ela é linearizada no `BackgroundWorkOwnership` sem precisar dar await no callback UIKit.
        guard registration.attach(to: ownership) == .attached else {
            _ = ownership.finish()
            finalizer.finish(success: false, shouldReschedule: true)
            return handle
        }

        Task {
            // Se o expiration handler venceu antes de esta task receber tempo de CPU, não comece um drain
            // novo. Caso o ticket já estivesse em voo, o caminho abaixo instala o handler de cancelamento
            // no contexto e aguarda seu terminal durável.
            guard registration.expirationReason == nil,
                  !ownership.cancellationContext.isCancelled
            else {
                finishBeforeTicket(
                    registration: registration,
                    ownership: ownership,
                    finalizer: finalizer
                )
                return
            }

            let ticket = await startDrain()

            // A expiração pode ter acontecido durante a admissão do ticket. Se outro owner ainda tem
            // orçamento, este BGTask não cria nem retém waiter adicional para o trabalho alheio.
            if registration.appliedExpirationResult == .workContinues {
                _ = registration.release()
                finalizer.finish(success: false, shouldReschedule: false)
                return
            }

            // `EvaluationCancellationContext` entrega exatamente uma vez, inclusive se a expiração ou a
            // invalidação global ocorreu antes de instalar o handler. Só o último owner chega aqui com o
            // contexto cancelado, portanto o ticket canônico é cancelado uma única vez.
            _ = ownership.cancellationContext.installCancellationHandler { _ in
                ticket.cancelCanonicalWork()
            }

            if registration.appliedExpirationResult == .workContinues {
                _ = registration.release()
                finalizer.finish(success: false, shouldReschedule: false)
                return
            }

            let drainResult = await ticket.completion()

            // `release()` lineariza terminal normal contra expiration. Se a expiração ganhou antes desta
            // linha, sua razão já está no contexto e a policy devolve false; se o terminal ganhou, uma
            // expiração tardia é ignorada pelo registration.
            _ = registration.release()
            let cancellationReason = ownership.cancellationContext.reason
            _ = ownership.finish()
            let disposition = BGProcessingCompletionPolicy.disposition(
                for: drainResult,
                cancellationReason: cancellationReason
            )
            finalizer.finish(
                success: disposition.success,
                shouldReschedule: disposition.shouldReschedule
            )
        }

        return handle
    }

    private func finishBeforeTicket(
        registration: BackgroundWorkOwnerRegistration,
        ownership: BackgroundWorkOwnership,
        finalizer: BGProcessingExecutionFinalizer
    ) {
        let expirationResult = registration.appliedExpirationResult
        _ = registration.release()

        // Quando outro owner continua, não fechamos a ownership que pertence ao trabalho compartilhado.
        // Nos demais cancelamentos não existe ticket iniciado por este controller; fechar solta qualquer
        // handler pendente sem fabricar marker persistente.
        if expirationResult != .workContinues {
            _ = ownership.finish()
        }
        finalizer.finish(
            success: false,
            shouldReschedule: expirationResult != .workContinues
        )
    }
}

/// Handle independente de `BGProcessingTask`, seguro para capturar diretamente no expiration handler.
/// As referências internas são lock-backed; não há estado de fila, ID de usuário ou dado de localização.
final class BGProcessingExecutionHandle: @unchecked Sendable {
    private let registration: BackgroundWorkOwnerRegistration
    private let ownership: BackgroundWorkOwnership
    private let finalizer: BGProcessingExecutionFinalizer

    fileprivate init(
        registration: BackgroundWorkOwnerRegistration,
        ownership: BackgroundWorkOwnership,
        finalizer: BGProcessingExecutionFinalizer
    ) {
        self.registration = registration
        self.ownership = ownership
        self.finalizer = finalizer
    }

    /// Marca a expiração sem await. O contexto cancela o ticket apenas quando este era o último owner.
    @discardableResult
    func expire() -> BackgroundWorkOwnerRegistrationExpirationResult {
        let result = registration.expire(reason: .bgTaskExpired)
        if result == .applied(.workContinues) {
            // Este orçamento acabou, mas o trabalho canônico ainda possui owner. Não aguardar evita
            // reter um BGTask expirado e não interfere no ticket/fila dos demais.
            finalizer.finish(success: false, shouldReschedule: false)
        }
        return result
    }

    /// Aguarda somente a conclusão deste owner de sistema. Cancelar o caller não cancela o ticket
    /// canônico, o finalizador nem outros waiters.
    func completion() async {
        await finalizer.waitForCompletion()
    }

    /// Exposto internamente para testes de ownership/invalidação; adapters de framework só usam
    /// `expire()` e `completion()`.
    var workOwnership: BackgroundWorkOwnership { ownership }
}

/// Une reagendamento e callback do sistema em um único caminho first-wins.
private final class BGProcessingExecutionFinalizer: @unchecked Sendable {
    private let lock = NSLock()
    private let scheduleProcessing: BGProcessingExecutionController.ProcessingScheduler
    private let completionGate: BGTaskCompletionGate
    private let signal = BGProcessingExecutionCompletionSignal()
    private var didFinish = false

    init(
        scheduleProcessing: @escaping BGProcessingExecutionController.ProcessingScheduler,
        completion: @escaping BGProcessingExecutionController.SystemCompletion
    ) {
        self.scheduleProcessing = scheduleProcessing
        completionGate = BGTaskCompletionGate(completion: completion)
    }

    func finish(success: Bool, shouldReschedule: Bool) {
        let didWin = lock.withLock {
            guard !didFinish else { return false }
            didFinish = true
            return true
        }
        guard didWin else { return }

        // A closure é deliberadamente externa para que o controller não mude política de scheduling nem
        // crie um request/marker próprio. Reagendamos só quando o ticket/expiração deixou a fila durável
        // pendente; um drain completo não pode criar wake vazio recorrente.
        if shouldReschedule {
            scheduleProcessing()
        }
        _ = completionGate.complete(success: success)
        signal.resolve()
    }

    func waitForCompletion() async {
        await signal.wait()
    }
}

/// Vários observers aguardam uma única task canônica, sem vetor de continuations por waiter.
private final class BGProcessingExecutionCompletionSignal: Sendable {
    private let completionTask: Task<Void, Never>
    private let oneShot: BGProcessingExecutionOneShot

    init() {
        let oneShot = BGProcessingExecutionOneShot()
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

/// Source síncrono com um único waiter canônico. A continuation é sempre retomada fora do lock.
private final class BGProcessingExecutionOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let resolved = lock.withLock {
                guard !isResolved else { return true }
                precondition(
                    self.continuation == nil,
                    "BGProcessingExecutionOneShot has more than one canonical waiter."
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
