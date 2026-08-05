import Foundation

// Seams protocolares do orquestrador (port_spec_background §2). As IMPLEMENTAÇÕES concretas de auth/
// acidente/prefs/notificações/senha vêm nos slices delas; aqui só os contratos que o orquestrador consome.

// `AuthStatus` (domínio) vive em Domain/Models/AuthModels.swift.

/// Preferências do app (port de AppPreferencesDataSource — impl concreta no slice de persistência).
protocol AppPreferencesReading: Sendable {
    func chave() async -> String
    func language() async -> String
    func userSettingsJson() async -> String
    /// Timestamp ISO8601 não sensível do consentimento explícito para automação em background.
    /// String vazia representa ausência/revogação.
    func backgroundLocationConsentAt() async -> String
    func seenAccidentIds() async -> Set<Int>
    func setSeenAccidentIds(_ ids: Set<Int>) async
    func setSeenAccidentIdsIfCurrent(
        _ ids: Set<Int>,
        sessionGeneration: AuthSessionGeneration
    ) async -> Bool
    func getFlag(_ name: String) async -> Bool
    func setFlag(_ name: String, _ value: Bool) async
    /// Episódio durável de retry por baixa precisão. String vazia representa ausência.
    func accuracyRetryEpisodeJson() async -> String
    func setAccuracyRetryEpisodeJson(_ json: String) async
    /// Adiamento durável da Pausa Programada. String vazia representa ausência.
    func scheduledPauseDeferralJson() async -> String
    func setScheduledPauseDeferralJson(_ json: String) async
}

/// Auth — só o `login` do relogin silencioso (o slice de auth traz a interface completa).
protocol AuthRepositoring: Sendable {
    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus>
}

/// Senha cifrada — `getPassword` retorna "" se ausente/inválida (nunca nil). Slice de segurança traz a impl.
protocol SecurePasswordReading: Sendable {
    func getPassword(_ chave: String) -> String
}

/// Estado de acidente — só `getState` (o slice de acidente traz a interface completa).
protocol AccidentStateReading: Sendable {
    func getState(_ chave: String) async -> AppResult<AccidentState>
}

/// Notificações que o orquestrador dispara (UNUserNotificationCenter — impl concreta é integração/glue).
/// (Sem `updateServiceNotification`: o iOS não tem a notificação persistente de FGS — spec §9.)
protocol AutoActivityNotifying: Sendable {
    func postAccidentNotification(lang: String)
    func postAccidentNotificationIfCurrent(
        lang: String,
        sessionGeneration: AuthSessionGeneration
    ) -> Bool
    func postActivityNotification(action: CheckAction, local: String?, lang: String)
    func postReauthNotification(lang: String)
    func postScheduledPauseTransition(started: Bool, lang: String)
    func postLowAccuracyNotification(expectedAction: CheckAction?, lang: String) async
    func clearLowAccuracyNotification() async
}

extension AppPreferencesReading {
    /// Compatibilidade para stores de teste. O store de produção e o fake de corrida sobrescrevem este
    /// método para fazer check+write no mesmo trecho síncrono protegido pela geração.
    func setSeenAccidentIdsIfCurrent(
        _ ids: Set<Int>,
        sessionGeneration: AuthSessionGeneration
    ) async -> Bool {
        guard sessionGeneration.isCurrentNow else { return false }
        await setSeenAccidentIds(ids)
        return sessionGeneration.isCurrentNow
    }
}

extension AutoActivityNotifying {
    func postAccidentNotificationIfCurrent(
        lang: String,
        sessionGeneration: AuthSessionGeneration
    ) -> Bool {
        sessionGeneration.performIfCurrent {
            postAccidentNotification(lang: lang)
        }
    }
}

/// "Wake lock" iOS = `beginBackgroundTask` (prazo do sistema; §9). No-op nos testes; release preservado no `defer`.
protocol BackgroundTaskGuard: Sendable {
    func begin() async -> Int
    func end(_ token: Int)
}
struct NoopBackgroundTaskGuard: BackgroundTaskGuard {
    func begin() async -> Int { 0 }
    func end(_ token: Int) {}
}

/// Lease explícita para o pipeline candidato. Diferentemente de `BackgroundTaskGuard`, a expiração faz
/// parte do contrato e cada lease possui seu próprio finalizador exactly-once.
protocol BackgroundExecutionLeasing: Sendable {
    func begin(
        name: String,
        onExpiration: @escaping @Sendable () -> Void
    ) async -> BackgroundExecutionLease
}

/// Handle efêmero de uma única concessão de tempo em background.
///
/// O estado é protegido por `NSLock` porque `end()` pode competir com o callback síncrono de expiração do
/// UIKit. Nenhuma closure é executada com o lock adquirido. Se a expiração ocorrer enquanto a plataforma
/// ainda está retornando o token, o finalizador instalado em seguida é executado imediatamente e uma única
/// vez.
final class BackgroundExecutionLease: @unchecked Sendable {
    typealias Handler = @Sendable () -> Void

    private let lock = NSLock()
    private var expirationHandler: Handler?
    private var endHandler: Handler?
    private var endHandlerWasInstalled = false
    private var ended = false

    init(onExpiration: @escaping Handler) {
        expirationHandler = onExpiration
    }

    /// Finaliza a lease de forma idempotente. O handler da plataforma é retirado sob lock e chamado fora
    /// dele, evitando deadlock caso o adapter reentre no lifecycle do aplicativo.
    func end() {
        let handler = lock.withLock { () -> Handler? in
            guard !ended else { return nil }
            ended = true
            expirationHandler = nil
            defer { endHandler = nil }
            return endHandler
        }
        handler?()
    }

    /// Usado somente pela implementação da plataforma antes de devolver a lease ao caller.
    func installEndHandler(_ handler: @escaping Handler) {
        let shouldEndImmediately = lock.withLock {
            guard !endHandlerWasInstalled else { return false }
            endHandlerWasInstalled = true
            guard !ended else { return true }
            endHandler = handler
            return false
        }
        if shouldEndImmediately { handler() }
    }

    /// Entrada do callback síncrono da plataforma. A primeira operação entre `expire()` e `end()` vence;
    /// expiração vencedora notifica o owner e encerra o recurso físico exatamente uma vez.
    func expire() {
        let handlers = lock.withLock { () -> (expiration: Handler?, end: Handler?) in
            guard !ended else { return (nil, nil) }
            ended = true
            let expiration = expirationHandler
            let end = endHandler
            expirationHandler = nil
            endHandler = nil
            return (expiration, end)
        }
        handlers.expiration?()
        handlers.end?()
    }
}

/// Implementação determinística para previews e testes que não possuem orçamento físico do UIKit.
struct NoopBackgroundExecutionLeasing: BackgroundExecutionLeasing {
    func begin(
        name: String,
        onExpiration: @escaping @Sendable () -> Void
    ) async -> BackgroundExecutionLease {
        BackgroundExecutionLease(onExpiration: onExpiration)
    }
}

/// Transições de pausa no iOS. Não acorda o processo para executar código, mas agenda notificações locais
/// no relógio do sistema; o motor reconcilia o estado no próximo evento de localização/BGTask/foreground.
protocol PauseAlarmScheduling: Sendable {
    func scheduleResume(at: Date?, notify: Bool, lang: String) async
    func scheduleStart(at: Date?, notify: Bool, lang: String) async
    /// Evita repetir, no próximo despertar do processo, uma transição que já teve notificação agendada.
    func consumeScheduledTransition(started: Bool, dueAtOrBefore now: Date) async -> Bool
}
struct NoopPauseAlarmScheduling: PauseAlarmScheduling {
    func scheduleResume(at: Date?, notify: Bool, lang: String) async {}
    func scheduleStart(at: Date?, notify: Bool, lang: String) async {}
    func consumeScheduledTransition(started: Bool, dueAtOrBefore now: Date) async -> Bool { false }
}

/// Único scheduler de `BGAppRefresh` do app. Os prazos persistidos participam do mesmo request regular:
/// o próximo despertar é `min(retry de precisão, transição bruta, grace da pausa, agora + 15min)`.
protocol AppRefreshScheduling: Sendable {
    @discardableResult
    func scheduleRegularRefresh() -> String?
    @discardableResult
    func scheduleAccuracyRetry(at deadline: Date) -> String?
    @discardableResult
    func clearAccuracyRetryDeadlineAndScheduleRegular() -> String?
    @discardableResult
    func schedulePauseActivation(at deadline: Date) -> String?
    @discardableResult
    func clearPauseActivationDeadlineAndScheduleRegular() -> String?
    @discardableResult
    func schedulePauseTransition(at deadline: Date) -> String?
    @discardableResult
    func clearPauseTransitionDeadlineAndScheduleRegular() -> String?
    func triggerForPendingRefresh() -> OrchestratorTrigger
}
struct NoopAppRefreshScheduler: AppRefreshScheduling {
    func scheduleRegularRefresh() -> String? { nil }
    func scheduleAccuracyRetry(at deadline: Date) -> String? { nil }
    func clearAccuracyRetryDeadlineAndScheduleRegular() -> String? { nil }
    func schedulePauseActivation(at deadline: Date) -> String? { nil }
    func clearPauseActivationDeadlineAndScheduleRegular() -> String? { nil }
    func schedulePauseTransition(at deadline: Date) -> String? { nil }
    func clearPauseTransitionDeadlineAndScheduleRegular() -> String? { nil }
    func triggerForPendingRefresh() -> OrchestratorTrigger { .timer }
}

/// Seleção neutra de camada para o pipeline operacional. A composição traduz o perfil de build para este
/// enum; Platform não precisa depender do tipo público definido na camada App.
enum BackgroundAutomaticEvaluationPipeline: Sendable, Equatable {
    case legacy
    case candidate
}

/// Fonte operacional fechada de options/state. Não identifica usuário, local ou request.
enum BackgroundInputSource: Sendable, Equatable {
    case remote
    case cache
    case offlineDefault
}

/// Resultado em memória que preserva valor, fonte e eventual falha upstream simultaneamente. Essa
/// simultaneidade é necessária quando `.network` usa cache expirado ou defaults offline.
enum BackgroundInputResolution<Value: Sendable>: Sendable {
    case resolved(
        Value,
        source: BackgroundInputSource,
        upstreamFailure: ApiError?
    )
    case failed(ApiError)

    var value: Value? {
        switch self {
        case .resolved(let value, _, _): value
        case .failed: nil
        }
    }

    var source: BackgroundInputSource? {
        switch self {
        case .resolved(_, let source, _): source
        case .failed: nil
        }
    }

    var failure: ApiError? {
        switch self {
        case .resolved(_, _, let failure): failure
        case .failed(let error): error
        }
    }
}

extension BackgroundInputResolution: Equatable where Value: Equatable {}

/// Contrato do motor automático (permite fakear o use-case nos testes do orquestrador).
protocol RunningAutomaticActivities: Sendable {
    func execute(chave: String, userProjects: UserProjects?, currentState: HistoryState?,
                 mixedZoneIntervalMinutes: Int, accuracyThresholdMeters: Int,
                 locationAttempt: LocationAttemptInput) async -> AutomaticActivitiesExecution

    func execute(chave: String, userProjects: UserProjects?, currentState: HistoryState?,
                 mixedZoneIntervalMinutes: Int, accuracyThresholdMeters: Int,
                 locationAttempt: LocationAttemptInput,
                 effectGuard: AutomaticActivitiesEffectGuard) async -> AutomaticActivitiesExecution
}

/// Seam em fases usado pelo pipeline candidato. O preflight é síncrono e acontece antes de ligar
/// localização; `prepare` resolve/revalida/matcheia uma tentativa; `complete` é a única continuação que
/// executa accuracy handling, matriz e submit a partir do match já resolvido.
///
/// O protocolo separado mantém fakes legados válidos até o orquestrador selecionar explicitamente o
/// pipeline candidato; produção usa `RunAutomaticActivitiesUseCase`, que implementa ambas as fachadas.
protocol PhasedRunningAutomaticActivities: RunningAutomaticActivities {
    func preflight(
        chave: String,
        userProjects: UserProjects?,
        mixedZoneIntervalMinutes: Int
    ) -> AutomaticActivitiesPreflight

    func prepare(
        _ configuration: AutomaticActivitiesConfiguration,
        accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput
    ) async -> AutomaticActivitiesPreparation

    func prepare(
        _ configuration: AutomaticActivitiesConfiguration,
        accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> AutomaticActivitiesPreparation

    func complete(
        _ prepared: PreparedAutomaticActivitiesMatch,
        currentState: HistoryState?
    ) async -> AutomaticActivitiesExecution

    func complete(
        _ prepared: PreparedAutomaticActivitiesMatch,
        currentState: HistoryState?,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> AutomaticActivitiesExecution

    /// Executa a mesma matriz, mas impede repetir exatamente a última ação irreversível do ciclo. Uma
    /// ação oposta continua autorizada e não existe segunda matriz ou segundo caminho em paralelo.
    func complete(
        _ prepared: PreparedAutomaticActivitiesMatch,
        currentState: HistoryState?,
        suppressingDuplicateOf action: CheckAction?
    ) async -> AutomaticActivitiesExecution

    func complete(
        _ prepared: PreparedAutomaticActivitiesMatch,
        currentState: HistoryState?,
        suppressingDuplicateOf action: CheckAction?,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> AutomaticActivitiesExecution
}

extension PhasedRunningAutomaticActivities {
    func prepare(
        _ configuration: AutomaticActivitiesConfiguration,
        accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> AutomaticActivitiesPreparation {
        await prepare(
            configuration,
            accuracyThresholdMeters: accuracyThresholdMeters,
            locationAttempt: locationAttempt
        )
    }

    func complete(
        _ prepared: PreparedAutomaticActivitiesMatch,
        currentState: HistoryState?,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> AutomaticActivitiesExecution {
        await complete(prepared, currentState: currentState)
    }

    func complete(
        _ prepared: PreparedAutomaticActivitiesMatch,
        currentState: HistoryState?,
        suppressingDuplicateOf action: CheckAction?
    ) async -> AutomaticActivitiesExecution {
        await complete(prepared, currentState: currentState)
    }

    func complete(
        _ prepared: PreparedAutomaticActivitiesMatch,
        currentState: HistoryState?,
        suppressingDuplicateOf action: CheckAction?,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> AutomaticActivitiesExecution {
        await complete(
            prepared,
            currentState: currentState,
            suppressingDuplicateOf: action
        )
    }
}

extension RunningAutomaticActivities {
    func execute(chave: String, userProjects: UserProjects?, currentState: HistoryState?,
                 mixedZoneIntervalMinutes: Int, accuracyThresholdMeters: Int,
                 locationAttempt: LocationAttemptInput,
                 effectGuard: AutomaticActivitiesEffectGuard) async -> AutomaticActivitiesExecution {
        await execute(
            chave: chave,
            userProjects: userProjects,
            currentState: currentState,
            mixedZoneIntervalMinutes: mixedZoneIntervalMinutes,
            accuracyThresholdMeters: accuracyThresholdMeters,
            locationAttempt: locationAttempt
        )
    }

    func execute(chave: String, userProjects: UserProjects?, currentState: HistoryState?,
                 mixedZoneIntervalMinutes: Int,
                 accuracyThresholdMeters: Int) async -> AutomaticActivitiesExecution {
        await execute(
            chave: chave,
            userProjects: userProjects,
            currentState: currentState,
            mixedZoneIntervalMinutes: mixedZoneIntervalMinutes,
            accuracyThresholdMeters: accuracyThresholdMeters,
            locationAttempt: .acquire
        )
    }

    func callAsFunction(chave: String, userProjects: UserProjects?, currentState: HistoryState?,
                        mixedZoneIntervalMinutes: Int, accuracyThresholdMeters: Int,
                        locationAttempt: LocationAttemptInput) async -> AutoActivitiesResult {
        await execute(
            chave: chave,
            userProjects: userProjects,
            currentState: currentState,
            mixedZoneIntervalMinutes: mixedZoneIntervalMinutes,
            accuracyThresholdMeters: accuracyThresholdMeters,
            locationAttempt: locationAttempt
        ).result
    }

    /// Compatibilidade dos caminhos legados e dos gatilhos não faseados. O TIMER candidato usa
    /// `preflight`/`prepare`/`complete` diretamente e não passa por este overload.
    func callAsFunction(chave: String, userProjects: UserProjects?, currentState: HistoryState?,
                        mixedZoneIntervalMinutes: Int,
                        accuracyThresholdMeters: Int) async -> AutoActivitiesResult {
        await execute(
            chave: chave,
            userProjects: userProjects,
            currentState: currentState,
            mixedZoneIntervalMinutes: mixedZoneIntervalMinutes,
            accuracyThresholdMeters: accuracyThresholdMeters
        ).result
    }
}
extension RunAutomaticActivitiesUseCase: PhasedRunningAutomaticActivities {}

func resolveEffectiveLanguageCode(_ stored: String) -> String {
    if !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let resolved = resolveLanguageCode(stored, fallback: "")
        if !resolved.isEmpty { return resolved }
    }
    return detectDeviceLanguageCode()
}
