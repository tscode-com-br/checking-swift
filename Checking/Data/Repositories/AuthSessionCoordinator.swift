import Foundation

/// Estado mínimo separado do actor para que uma ação síncrona da UI consiga fechar a geração antes de
/// publicar qualquer trabalho assíncrono. O lock é a única forma de acesso ao contador.
private final class AuthSessionBarrierWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolved: Bool?

    var isResolved: Bool {
        lock.withLock { resolved != nil }
    }

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        let immediate = lock.withLock { () -> Bool? in
            if let resolved { return resolved }
            self.continuation = continuation
            return nil
        }
        if let immediate { continuation.resume(returning: immediate) }
    }

    func resolve(_ value: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard resolved == nil else { return nil }
            resolved = value
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}

private final class AuthSessionTransitionBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var waiters: [ObjectIdentifier: AuthSessionBarrierWaiter] = [:]

    /// `false` significa apenas que este waiter foi cancelado; não fecha o trabalho compartilhado nem o
    /// barrier dos demais owners.
    func wait() async -> Bool {
        if Task.isCancelled { return false }
        let waiter = AuthSessionBarrierWaiter()
        let id = ObjectIdentifier(waiter)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.install(continuation)
                let alreadyCompleted = lock.withLock { () -> Bool in
                    guard !completed else { return true }
                    if !waiter.isResolved { waiters[id] = waiter }
                    return false
                }
                if alreadyCompleted { waiter.resolve(true) }
            }
        } onCancel: {
            waiter.resolve(false)
            self.removeWaiter(id)
        }
    }

    func complete() {
        let pending = lock.withLock { () -> [AuthSessionBarrierWaiter] in
            guard !completed else { return [] }
            completed = true
            defer { waiters.removeAll(keepingCapacity: false) }
            return Array(waiters.values)
        }
        for waiter in pending { waiter.resolve(true) }
    }

    private func removeWaiter(_ id: ObjectIdentifier) {
        lock.withLock { waiters[id] = nil }
    }
}

private final class AuthSessionIdentityState: @unchecked Sendable {
    struct Snapshot: Sendable {
        let generation: UInt64
        let validity: AuthSessionGenerationValidity
        let barrier: AuthSessionTransitionBarrier?
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var generationValidity = AuthSessionGenerationValidity()
    private var invalidationSequence: UInt64 = 0
    private var openInvalidation: (
        id: UInt64,
        barrier: AuthSessionTransitionBarrier
    )?

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                generation: generation,
                validity: generationValidity,
                barrier: openInvalidation?.barrier
            )
        }
    }

    func isCurrent(_ observedGeneration: UInt64) -> Bool {
        lock.withLock {
            generation == observedGeneration
                && openInvalidation == nil
                && generationValidity.isCurrentNow
        }
    }

    func invalidate() -> AuthSessionInvalidation {
        lock.withLock {
            generationValidity.invalidate()
            generation &+= 1
            generationValidity = AuthSessionGenerationValidity(isCurrent: false)
            invalidationSequence &+= 1
            let barrier = openInvalidation?.barrier
                ?? AuthSessionTransitionBarrier()
            openInvalidation = (invalidationSequence, barrier)
            return AuthSessionInvalidation(value: invalidationSequence)
        }
    }

    func invalidateAfterSuccessfulDeletion(
        admittedGeneration: UInt64
    ) -> AuthSessionInvalidation? {
        lock.withLock {
            guard generation == admittedGeneration,
                  openInvalidation == nil else { return nil }
            generationValidity.invalidate()
            generation &+= 1
            generationValidity = AuthSessionGenerationValidity(isCurrent: false)
            invalidationSequence &+= 1
            let barrier = AuthSessionTransitionBarrier()
            openInvalidation = (invalidationSequence, barrier)
            return AuthSessionInvalidation(value: invalidationSequence)
        }
    }

    func isOpen(_ invalidation: AuthSessionInvalidation) -> Bool {
        lock.withLock { openInvalidation?.id == invalidation.value }
    }

    func takeCompletionBarrier(
        _ invalidation: AuthSessionInvalidation
    ) -> AuthSessionTransitionBarrier? {
        lock.withLock {
            guard openInvalidation?.id == invalidation.value else { return nil }
            let barrier = openInvalidation?.barrier
            openInvalidation = nil
            // Ative somente depois de o estado protegido já não publicar barrier aberto. Uma leitura
            // síncrona pode observar um breve false-negative, nunca um token válido prematuramente.
            generationValidity.activate()
            return barrier
        }
    }
}

/// Serializa mutações reais da sessão através dos pontos de suspensão e compartilha um único refresh por
/// identidade lógica. O actor protege o estado; o task-chain protege a ordem total durante `await`.
actor AuthSessionCoordinator: AuthSessionCoordinating {
    private struct RefreshSlot: Sendable {
        let id: UInt64
        let chave: String
        let generation: UInt64
        let task: Task<SilentReloginResult, Never>
    }

    private let authRepository: any AuthRepository
    private let securePasswordStore: any SecurePasswordReading
    private let cookieStore: any SessionCookieStore
    /// Observabilidade opcional de coalescência. Os caminhos distribuíveis deixam este callback `nil`;
    /// ele permite que o teste prove que um waiter já capturou o task compartilhado antes de liberar o
    /// request que o sustenta.
    private let didJoinExistingSilentRelogin: (@Sendable () -> Void)?
    private nonisolated let identityState = AuthSessionIdentityState()

    /// Somente o último nó permanece retido. Cada novo nó espera o anterior, portanto atores reentrantes
    /// não conseguem intercalar duas mutações reais através de um `await`.
    private var mutationTail: Task<Void, Never>?
    private var mutationSequence: UInt64 = 0
    private var refreshSlot: RefreshSlot?

    init(
        authRepository: any AuthRepository,
        securePasswordStore: any SecurePasswordReading,
        cookieStore: any SessionCookieStore,
        didJoinExistingSilentRelogin: (@Sendable () -> Void)? = nil
    ) {
        self.authRepository = authRepository
        self.securePasswordStore = securePasswordStore
        self.cookieStore = cookieStore
        self.didJoinExistingSilentRelogin = didJoinExistingSilentRelogin
    }

    func useCurrentSession() async -> AuthSessionGeneration {
        while true {
            let observedSequence = mutationSequence
            let observedTail = mutationTail
            await observedTail?.value
            let identity = identityState.snapshot()
            if let barrier = identity.barrier {
                let completed = await barrier.wait()
                if !completed || Task.isCancelled {
                    return AuthSessionGeneration(
                        value: identity.generation,
                        validity: AuthSessionGenerationValidity(isCurrent: false)
                    )
                }
                continue
            }
            guard observedSequence == mutationSequence,
                  identityState.isCurrent(identity.generation) else { continue }
            return AuthSessionGeneration(
                value: identity.generation,
                validity: identity.validity
            )
        }
    }

    func isCurrent(_ generation: AuthSessionGeneration) async -> Bool {
        generation.isCurrentNow
            && identityState.isCurrent(generation.value)
    }

    nonisolated func invalidateCurrentIdentity() -> AuthSessionInvalidation {
        let invalidation = identityState.invalidate()
        cookieStore.invalidateInFlightResponses()
        return invalidation
    }

    func awaitIdle() async {
        while true {
            let observedSequence = mutationSequence
            let observedTail = mutationTail
            await observedTail?.value
            if observedSequence == mutationSequence { return }
        }
    }

    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus> {
        guard let generation = admitCurrentIdentityGeneration() else {
            return .failure(.unauthorized)
        }
        let repository = authRepository
        let task = enqueueMutation { [weak self] in
            guard let self,
                  self.isIdentityGenerationCurrent(generation) else {
                return AppResult<AuthStatus>.failure(.unauthorized)
            }
            let result = await repository.login(chave, password)
            guard self.isIdentityGenerationCurrent(generation) else {
                return AppResult<AuthStatus>.failure(.unauthorized)
            }
            return result
        }
        return await task.value
    }

    func registerPassword(
        _ chave: String,
        _ project: String?,
        _ password: String
    ) async -> AppResult<AuthStatus> {
        guard let generation = admitCurrentIdentityGeneration() else {
            return .failure(.unauthorized)
        }
        let repository = authRepository
        let task = enqueueMutation { [weak self] in
            guard let self,
                  self.isIdentityGenerationCurrent(generation) else {
                return AppResult<AuthStatus>.failure(.unauthorized)
            }
            let result = await repository.registerPassword(chave, project, password)
            guard self.isIdentityGenerationCurrent(generation) else {
                return AppResult<AuthStatus>.failure(.unauthorized)
            }
            return result
        }
        return await task.value
    }

    func changePassword(
        _ chave: String,
        _ oldPassword: String,
        _ newPassword: String
    ) async -> AppResult<AuthStatus> {
        guard let generation = admitCurrentIdentityGeneration() else {
            return .failure(.unauthorized)
        }
        let repository = authRepository
        let task = enqueueMutation { [weak self] in
            guard let self,
                  self.isIdentityGenerationCurrent(generation) else {
                return AppResult<AuthStatus>.failure(.unauthorized)
            }
            let result = await repository.changePassword(
                chave,
                oldPassword,
                newPassword
            )
            guard self.isIdentityGenerationCurrent(generation) else {
                return AppResult<AuthStatus>.failure(.unauthorized)
            }
            return result
        }
        return await task.value
    }

    func selfRegister(
        _ chave: String,
        _ nome: String,
        _ projetos: [String],
        _ email: String?,
        _ password: String,
        _ confirmPassword: String
    ) async -> AppResult<AuthStatus> {
        guard let generation = admitCurrentIdentityGeneration() else {
            return .failure(.unauthorized)
        }
        let repository = authRepository
        let task = enqueueMutation { [weak self] in
            guard let self,
                  self.isIdentityGenerationCurrent(generation) else {
                return AppResult<AuthStatus>.failure(.unauthorized)
            }
            let result = await repository.selfRegister(
                chave,
                nome,
                projetos,
                email,
                password,
                confirmPassword
            )
            guard self.isIdentityGenerationCurrent(generation) else {
                return AppResult<AuthStatus>.failure(.unauthorized)
            }
            return result
        }
        return await task.value
    }

    func silentRelogin(_ chave: String) async -> SilentReloginResult {
        guard let generation = admitCurrentIdentityGeneration() else {
            return .staleContext
        }
        if let refreshSlot,
           refreshSlot.chave == chave,
           refreshSlot.generation == generation {
            // Copiar o task antes de sinalizar permite que um teste sincronize o join sem depender do
            // agendamento de `Task {}`. A semântica de produção é idêntica: o callback é `nil`.
            let task = refreshSlot.task
            didJoinExistingSilentRelogin?()
            return await task.value
        }

        let repository = authRepository
        let passwordStore = securePasswordStore
        let id = nextMutationSequence()
        let task: Task<SilentReloginResult, Never> = enqueueMutation(sequence: id) { [weak self] in
            guard let self,
                  self.isIdentityGenerationCurrent(generation) else {
                return .staleContext
            }

            // A leitura ocorre somente quando esta mutação chegou à cabeça do tail. Assim uma senha
            // substituída enquanto o refresh estava enfileirado é observada, sem ficar retida no actor.
            let password = passwordStore.getPassword(chave)
            guard !password.isEmpty else { return .missingPassword }
            guard self.isIdentityGenerationCurrent(generation) else {
                return .staleContext
            }

            let result = await repository.login(chave, password)
            guard self.isIdentityGenerationCurrent(generation) else {
                return .staleContext
            }
            switch result {
            case .success(let status):
                return .refreshed(status)
            case .failure(let error):
                return .failed(error)
            }
        }
        refreshSlot = RefreshSlot(
            id: id,
            chave: chave,
            generation: generation,
            task: task
        )

        let result = await task.value
        if refreshSlot?.id == id {
            refreshSlot = nil
        }
        return result
    }

    func replaceIdentity() async {
        let invalidation = invalidateCurrentIdentity()
        await completeInvalidatedLogout(invalidation)
    }

    func explicitLogout() async {
        let invalidation = invalidateCurrentIdentity()
        await completeInvalidatedLogout(invalidation)
    }

    func completeInvalidatedLogout(
        _ invalidation: AuthSessionInvalidation
    ) async {
        guard identityState.isOpen(invalidation) else { return }
        let task = enqueueRemoteLogout()
        await task.value
        identityState.takeCompletionBarrier(invalidation)?.complete()
    }

    func completeInvalidatedTransition(
        _ invalidation: AuthSessionInvalidation
    ) async {
        guard let barrier = identityState.takeCompletionBarrier(invalidation) else {
            return
        }
        // Não há POST a aguardar neste caminho; o clear local fecha a janela antes de liberar waiters.
        cookieStore.clear()
        barrier.complete()
    }

    func deleteAccount() async -> DeleteAccountSessionResult {
        let repository = authRepository
        guard let generationAtAdmission = admitCurrentIdentityGeneration() else {
            return .staleContext
        }
        let task = enqueueMutation { [weak self] in
            guard let self,
                  self.isIdentityGenerationCurrent(generationAtAdmission) else {
                return DeleteAccountSessionResult.staleContext
            }
            let result = await repository.deleteAccount()
            switch result {
            case .success:
                guard let invalidation = self.commitSuccessfulDeletion(
                    generationAtAdmission: generationAtAdmission
                ) else { return .staleContext }
                return .deleted(invalidation)
            case .failure(let error):
                guard self.isIdentityGenerationCurrent(generationAtAdmission) else {
                    return .staleContext
                }
                return .failed(error)
            }
        }
        return await task.value
    }

    private func enqueueRemoteLogout() -> Task<Void, Never> {
        let repository = authRepository
        let cookies = cookieStore
        return enqueueMutation {
            _ = await repository.logout()
            // `logout` vivo também limpa; esta chamada mantém o seam seguro com qualquer implementação.
            cookies.clear()
        }
    }

    private nonisolated func isIdentityGenerationCurrent(_ generation: UInt64) -> Bool {
        identityState.isCurrent(generation)
    }

    /// Mutações não aguardam uma troca de identidade em andamento. Trabalho UI que já estava enfileirado
    /// precisa terminar stale sob o barrier, nunca acordar depois e autenticar silenciosamente na geração
    /// nova. Somente `useCurrentSession` representa um waiter legítimo pela identidade seguinte.
    private func admitCurrentIdentityGeneration() -> UInt64? {
        guard !Task.isCancelled else { return nil }
        let identity = identityState.snapshot()
        guard identity.barrier == nil,
              identityState.isCurrent(identity.generation) else { return nil }
        return identity.generation
    }

    private nonisolated func commitSuccessfulDeletion(
        generationAtAdmission: UInt64
    ) -> AuthSessionInvalidation? {
        // O commit faz parte do mesmo nó do tail: um login posterior não pode começar entre a resposta
        // aceita do DELETE e a limpeza local. Se outra troca já avançou a geração, o owner mais novo será
        // responsável pelo clear e este retorno antigo não toca na nova identidade.
        guard let invalidation = identityState.invalidateAfterSuccessfulDeletion(
            admittedGeneration: generationAtAdmission
        ) else { return nil }
        // `AuthRepositoryLive` já limpa em sucesso. Repetir clear aqui torna o contrato do coordenador
        // verdadeiro também para fakes/adapters e continua idempotente no backend vivo.
        cookieStore.clear()
        return invalidation
    }

    private func nextMutationSequence() -> UInt64 {
        mutationSequence &+= 1
        return mutationSequence
    }

    private func enqueueMutation<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) -> Task<Value, Never> {
        enqueueMutation(sequence: nextMutationSequence(), operation)
    }

    private func enqueueMutation<Value: Sendable>(
        sequence: UInt64,
        _ operation: @escaping @Sendable () async -> Value
    ) -> Task<Value, Never> {
        let previous = mutationTail
        let operationTask = Task {
            await previous?.value
            return await operation()
        }
        mutationTail = Task {
            _ = await operationTask.value
        }
        // `sequence` foi reservado/publicado antes de qualquer suspensão. A precondition documenta a
        // invariável do helper sem depender dela em Release.
        assert(sequence == mutationSequence)
        return operationTask
    }
}
