import Foundation

/// Resumo histórico do pedido entregue ao monitor. `requested` não é confirmação técnica; o caminho
/// candidato expõe as contagens reais via `monitoringSnapshot()`. A propriedade `monitored` permanece só
/// como compatibilidade com o painel legado e equivale a `requested`.
struct GeofenceRegistrationSummary: Sendable, Equatable {
    var requested: Int
    var omitted: Int

    var monitored: Int { requested }

    init(requested: Int, omitted: Int) {
        self.requested = requested
        self.omitted = omitted
    }

    init(monitored: Int, omitted: Int) {
        self.init(requested: monitored, omitted: omitted)
    }
}

/// Ciclo de vida consumido pela camada de apresentação. Mantém o `CheckViewModel` testável e garante que
/// registrar/remover regiões deixe de depender da antiga tela técnica de validação física.
protocol GeofenceRegionManaging: Sendable {
    func register(chave: String, hints: GeofencePriorityHints, forceRefresh: Bool) async
    func unregisterAll() async
}

/// Port de platform/background/GeofenceManager.kt (§23.2, T3B.9). Busca os círculos do projeto, prioriza
/// sob o cap de 20 do iOS (`GeofenceRegionPrioritizer` — lógica nova, sem contraparte Android) e entrega ao
/// monitor. Geofences são só GATILHOS de acordar; o match preciso é sempre no servidor (Approach A).
///
/// `actor`: `lastSummary` é estado mutável lido pelo diagnóstico de outra isolação. Erros são engolidos
/// (fiel ao Kotlin — o BGAppRefreshTask/foreground são o caminho primário; geofence é oportunista).
actor GeofenceRegionManager: GeofenceRegionManaging {
    private enum MonitorCommand: Sendable {
        case sync([GeofenceRegion], omittedCount: Int)
        case removeAll
    }

    private struct QueuedMonitorCommand: Sendable {
        let intentGeneration: UInt64
        let command: MonitorCommand
        let completion: GeofenceMonitorCommandCompletion
    }

    private let checkRepository: any CheckRepository
    private let monitor: any GeofenceRegionMonitoring
    private let activityLogger: any ActivityLogging
    private var intentGeneration: UInt64 = 0
    private var isMonitorCommandRunning = false
    private var pendingMonitorCommand: QueuedMonitorCommand?
    private(set) var lastSummary: GeofenceRegistrationSummary?

    init(checkRepository: any CheckRepository, monitor: any GeofenceRegionMonitoring, activityLogger: any ActivityLogging) {
        self.checkRepository = checkRepository
        self.monitor = monitor
        self.activityLogger = activityLogger
    }

    /// Busca os círculos e (re)registra o conjunto priorizado. Idempotente. `hints` prioriza a seleção
    /// quando há posição/local atual conhecidos; sem eles, cai na ordem por id (ainda determinística).
    func register(
        chave: String,
        hints: GeofencePriorityHints = GeofencePriorityHints(),
        forceRefresh: Bool = false
    ) async {
        let generation = beginIntent()
        if forceRefresh { checkRepository.invalidateGeofenceCache() }
        let circles: [GeofenceCircle]
        switch await checkRepository.getGeofences(chave) {
        case .success(let c): circles = c
        case .failure: return                       // engole — fiel ao Kotlin (early return no Failure)
        }
        guard generation == intentGeneration else { return }

        // Uma resposta vazia após troca de projeto/conta precisa remover regiões antigas. Preservá-las
        // manteria despertares associados a locais que já não pertencem ao usuário.
        guard !circles.isEmpty else {
            let applied = await enqueueMonitorCommand(
                .sync([], omittedCount: 0),
                intentGeneration: generation
            )
            guard applied, generation == intentGeneration else { return }
            lastSummary = GeofenceRegistrationSummary(requested: 0, omitted: 0)
            activityLogger.logSystem("Geofences registered (0).", .info)
            return
        }

        let selection = GeofenceRegionPrioritizer.select(circles, hints: hints)
        let regions = selection.selected.map {
            GeofenceRegion(id: String($0.id), centerLat: $0.centerLat, centerLng: $0.centerLng, radiusMeters: $0.radiusMeters)
        }
        let applied = await enqueueMonitorCommand(
            .sync(regions, omittedCount: selection.omittedCount),
            intentGeneration: generation
        )
        guard applied, generation == intentGeneration else { return }
        lastSummary = GeofenceRegistrationSummary(requested: regions.count, omitted: selection.omittedCount)

        // Mensagem byte-exact com o Kotlin, MAS a semântica de tempo difere: aqui "registered" = REQUESTED ao
        // Core Location, não confirmação técnica. O candidato publica confirmed/failed/pending apenas no seu
        // snapshot; o legado mantém a mensagem histórica para compatibilidade de diagnóstico.
        activityLogger.logSystem("Geofences registered (\(regions.count)).", .info)
        if selection.omittedCount > 0 {
            // iOS-only: o cap de 20 forçou truncagem — NUNCA silenciosa (plano §9.2). O painel de
            // integridade também lê isso via `lastSummary`.
            activityLogger.logSystem(
                "Geofence cap: monitoring \(regions.count) of \(circles.count) region(s); \(selection.omittedCount) omitted (iOS 20-region limit).",
                .warning)
        }
    }

    /// Port de `GeofenceManager.unregisterAll` — remove tudo (stop do automático/logout).
    func unregisterAll() async {
        let generation = beginIntent()
        let applied = await enqueueMonitorCommand(.removeAll, intentGeneration: generation)
        guard applied, generation == intentGeneration else { return }
        lastSummary = nil
    }

    /// Leitura sob demanda das contagens técnicas. O monitor legado devolve `nil` porque callbacks antigos
    /// continuam ambíguos por contrato; o candidato devolve o snapshot privado por geração em memória.
    func monitoringSnapshot() async -> GeofenceMonitoringSnapshot? {
        await monitor.monitoringSnapshot()
    }

    /// Cada chamada pública é uma nova intenção. Assim, uma resposta de rede que chega tarde nunca pode
    /// desfazer um `unregisterAll` ou um registro mais recente.
    private func beginIntent() -> UInt64 {
        intentGeneration &+= 1
        return intentGeneration
    }

    /// Serializa comandos ao monitor sem criar uma cadeia ilimitada de tasks: existe no máximo um comando
    /// em execução e um pending, sempre substituído pela intenção mais nova. Callers substituídos são
    /// resolvidos explicitamente para não deixar continuations órfãs.
    private func enqueueMonitorCommand(
        _ command: MonitorCommand,
        intentGeneration generation: UInt64
    ) async -> Bool {
        let completion = GeofenceMonitorCommandCompletion()
        let queued = QueuedMonitorCommand(
            intentGeneration: generation,
            command: command,
            completion: completion
        )

        if isMonitorCommandRunning {
            let superseded = pendingMonitorCommand
            pendingMonitorCommand = queued
            if let superseded {
                await superseded.completion.resolve(applied: false)
            }
            return await completion.wait()
        }

        isMonitorCommandRunning = true
        var current: QueuedMonitorCommand? = queued

        while let commandToRun = current {
            // Uma intenção pode ficar obsoleta enquanto aguardava o comando anterior. Nesse caso ela é
            // concluída sem tocar no monitor; somente a intenção corrente pode ser aplicada.
            let shouldApply = commandToRun.intentGeneration == self.intentGeneration
            if shouldApply {
                switch commandToRun.command {
                case .sync(let regions, let omittedCount):
                    await monitor.sync(regions, omittedCount: omittedCount)
                case .removeAll:
                    await monitor.removeAll()
                }
            }
            await commandToRun.completion.resolve(applied: shouldApply)

            current = pendingMonitorCommand
            pendingMonitorCommand = nil
        }

        isMonitorCommandRunning = false
        return await completion.wait()
    }
}

/// One-shot usado apenas pelo executor bounded acima. É um actor separado para que um caller suspenso
/// possa aguardar a conclusão do comando canônico sem compartilhar uma lista ilimitada de continuations.
private actor GeofenceMonitorCommandCompletion {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(applied: Bool) {
        guard result == nil else { return }
        result = applied
        continuation?.resume(returning: applied)
        continuation = nil
    }
}
