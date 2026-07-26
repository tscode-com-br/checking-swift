import Foundation
import CoreLocation

/// Núcleo do motor de background — port de BackgroundCheckOrchestrator.kt. `actor` com single-flight por
/// FLAG (não-reentrante, não-bloqueante: a 2ª chamada concorrente RETORNA, não enfileira — §3). Lógica 1:1;
/// só os gatilhos e a plataforma (notificações, alarme, wake-lock) são seams. Ver port_spec_background_orchestrator.
actor BackgroundCheckOrchestrator {
    // Constantes (§11)
    static let skipThresholdMeters = 50.0
    static let stateCacheTTL: TimeInterval = 45
    static let locationOptionsTTL: TimeInterval = 15 * 60
    static let reauthNotificationCooldown: TimeInterval = 60 * 60
    static let accuracyRetryInterval: TimeInterval = 180
    static let scheduledPauseActivationDelay: TimeInterval = 10
    static let scheduledPauseConfirmationBackoff: TimeInterval = 180
    static let flagPauseActive = "scheduled_pause_active"

    private enum SkipDecision { case run, skip, noFix }

    private struct AccuracyRetryEpisode: Codable, Equatable {
        let id: String
        let chave: String
        let activeProject: String
        var nextRetryEpochMs: Int64
        var notificationPosted: Bool
        var expectedActionRaw: String?

        var nextRetryAt: Date {
            Date(timeIntervalSince1970: Double(nextRetryEpochMs) / 1_000)
        }

        var expectedAction: CheckAction? {
            switch expectedActionRaw {
            case "checkin": return .checkIn
            case "checkout": return .checkOut
            default: return nil
            }
        }
    }

    private enum ScheduledPauseDeferralPhase: String, Codable, Equatable {
        case awaitingCheckout
        case activationScheduled
        case active
        case terminal
    }

    /// Estado durável de uma única ocorrência da pausa. A configuração do usuário nunca é reescrita:
    /// este registro apenas diz se aquela ocorrência aguarda checkout ou os 10 segundos de carência.
    private struct ScheduledPauseDeferral: Codable, Equatable {
        let id: String
        let chave: String
        let activeProject: String
        let settings: ScheduledPauseSettings
        let windowStartEpochMs: Int64
        let windowEndEpochMs: Int64
        var phase: ScheduledPauseDeferralPhase
        var activationEpochMs: Int64?

        var windowStart: Date {
            Date(timeIntervalSince1970: Double(windowStartEpochMs) / 1_000)
        }
        var windowEnd: Date {
            Date(timeIntervalSince1970: Double(windowEndEpochMs) / 1_000)
        }
        var activationAt: Date? {
            activationEpochMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
        }
    }

    private enum FreshRemoteState {
        case success(HistoryState)
        case failure(ApiError)
    }

    private enum ScheduledPauseGateResult {
        case proceed(currentState: HistoryState?, usedFreshState: Bool)
        case stop(EvaluationOutcome)
    }

    // Dependências
    private let appPrefs: any AppPreferencesReading
    private let checkRepository: any CheckRepository
    private let runAutomaticActivities: any RunningAutomaticActivities
    private let locationProvider: any LocationProvider
    private let clock: any Clock
    private let authRepository: any AuthRepositoring
    private let securePasswordStore: any SecurePasswordReading
    private let accidentRepository: any AccidentStateReading
    private let activityLogger: any ActivityLogging
    private let notifications: any AutoActivityNotifying
    private let backgroundTaskGuard: any BackgroundTaskGuard
    private let pauseAlarms: any PauseAlarmScheduling
    private let accuracyRetrySleeper: any Sleeping
    private let pauseActivationSleeper: any Sleeping
    private let pauseTransitionSleeper: any Sleeping
    private let appRefreshScheduler: any AppRefreshScheduling

    // Estado (isolado pelo actor — sem @Volatile)
    private var isRunning = false
    private var isSessionExpired = false
    private var lastLat: Double?
    private var lastLon: Double?
    private var lastCaptureAccuracyMeters: Double?
    private var cachedState: HistoryState?
    private var cacheChave = ""
    private var cachedStateAt = Date(timeIntervalSince1970: 0)
    private var cachedOptions: LocationOptions?
    private var cachedOptionsAt = Date(timeIntervalSince1970: 0)
    private var lastReauthNotificationAt = Date(timeIntervalSince1970: 0)
    private var accuracyRetryEpisode: AccuracyRetryEpisode?
    private var accuracyRetryTask: Task<Void, Never>?
    private var pendingAccuracyRetry = false
    private var didRestoreAccuracyRetryEpisode = false
    private var accuracyRetryGeneration: UInt64 = 0
    private var scheduledPauseDeferral: ScheduledPauseDeferral?
    private var pauseActivationTask: Task<Void, Never>?
    private var pauseTransitionTask: Task<Void, Never>?
    private var pauseTransitionEpochMs: Int64?
    private var pendingPauseActivation = false
    private var pendingPauseTransition = false
    private var pendingPauseReconciliation = false
    private var didRestoreScheduledPauseDeferral = false
    private var scheduledPauseGeneration: UInt64 = 0
    private var automationContextInvalidationInProgress = false
    private var automationContextInvalidationWaiters: [CheckedContinuation<Void, Never>] = []

    var isRunningForTest: Bool { isRunning }
    var hasAccuracyRetryEpisodeForTest: Bool { accuracyRetryEpisode != nil }
    var nextAccuracyRetryAtForTest: Date? { accuracyRetryEpisode?.nextRetryAt }
    var hasPendingAccuracyRetryForTest: Bool { pendingAccuracyRetry }
    var hasScheduledPauseDeferralForTest: Bool { scheduledPauseDeferral != nil }
    var scheduledPauseActivationAtForTest: Date? { scheduledPauseDeferral?.activationAt }

    init(appPrefs: any AppPreferencesReading, checkRepository: any CheckRepository,
         runAutomaticActivities: any RunningAutomaticActivities, locationProvider: any LocationProvider,
         clock: any Clock, authRepository: any AuthRepositoring, securePasswordStore: any SecurePasswordReading,
         accidentRepository: any AccidentStateReading, activityLogger: any ActivityLogging,
         notifications: any AutoActivityNotifying, backgroundTaskGuard: any BackgroundTaskGuard = NoopBackgroundTaskGuard(),
         pauseAlarms: any PauseAlarmScheduling = NoopPauseAlarmScheduling(),
         accuracyRetrySleeper: any Sleeping = TaskSleeper(),
         pauseActivationSleeper: any Sleeping = TaskSleeper(),
         pauseTransitionSleeper: any Sleeping = TaskSleeper(),
         appRefreshScheduler: any AppRefreshScheduling = NoopAppRefreshScheduler()) {
        self.appPrefs = appPrefs; self.checkRepository = checkRepository; self.runAutomaticActivities = runAutomaticActivities
        self.locationProvider = locationProvider; self.clock = clock; self.authRepository = authRepository
        self.securePasswordStore = securePasswordStore; self.accidentRepository = accidentRepository
        self.activityLogger = activityLogger; self.notifications = notifications
        self.backgroundTaskGuard = backgroundTaskGuard; self.pauseAlarms = pauseAlarms
        self.accuracyRetrySleeper = accuracyRetrySleeper
        self.pauseActivationSleeper = pauseActivationSleeper
        self.pauseTransitionSleeper = pauseTransitionSleeper
        self.appRefreshScheduler = appRefreshScheduler
    }

    // MARK: - Entrada (single-flight)

    func runOnce(_ trigger: OrchestratorTrigger) async {
        await waitForAutomationContextInvalidationIfNeeded()
        // Capturado antes da primeira suspensão: um cancelamento que intercale com a restauração não pode
        // ser adotado como baseline novo por esta invocação antiga.
        let evaluationGeneration = accuracyRetryGeneration
        let pauseEvaluationGeneration = scheduledPauseGeneration
        if isRunning {
            // Gatilhos normais preservam o single-flight Kotlin. O retry devido é a única exceção: não pode
            // desaparecer atrás de uma avaliação já em voo, então guardamos no máximo um para drenar depois.
            if trigger == .accuracyRetry { pendingAccuracyRetry = true }
            if trigger == .pauseActivation { pendingPauseActivation = true }
            if trigger == .pauseTransition { pendingPauseTransition = true }
            return
        }
        isRunning = true
        // A restauração também pertence ao single-flight; isso impede duas invocações de observarem
        // `didRestore...` no meio de uma leitura persistida e perderem um episódio de cold start.
        await restoreAccuracyRetryEpisodeIfNeeded(armProcessTask: trigger != .accuracyRetry)
        await restoreScheduledPauseDeferralIfNeeded()
        guard evaluationGeneration == accuracyRetryGeneration,
              pauseEvaluationGeneration == scheduledPauseGeneration else {
            isRunning = false
            await drainPendingWorkIfNeeded()
            return
        }
        if trigger == .accuracyRetry, accuracyRetryEpisode == nil {
            appRefreshScheduler.clearAccuracyRetryDeadlineAndScheduleRegular()
            isRunning = false
            await drainPendingWorkIfNeeded()
            return
        }
        if trigger == .pauseActivation {
            let phase = scheduledPauseDeferral?.phase
            let hasPendingActivation =
                scheduledPauseDeferral?.activationAt != nil
                    && (phase == .activationScheduled || phase == .awaitingCheckout)
            if !hasPendingActivation {
                appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
                isRunning = false
                await drainPendingWorkIfNeeded()
                return
            }
        }
        let token = await backgroundTaskGuard.begin()
        isSessionExpired = false
        await runOnceLocked(
            trigger,
            generation: evaluationGeneration,
            pauseGeneration: pauseEvaluationGeneration)
        if isSessionExpired,
           evaluationGeneration == accuracyRetryGeneration,
           pauseEvaluationGeneration == scheduledPauseGeneration {
            // relogin silencioso + retry once, sempre conservando a geração original
            let chave = await appPrefs.chave()
            if !chave.isEmpty {
                let lang = resolveEffectiveLanguageCode(await appPrefs.language())
                if await attemptSilentRelogin(chave, lang) {
                    isSessionExpired = false
                    await runOnceLocked(
                        trigger,
                        generation: evaluationGeneration,
                        pauseGeneration: pauseEvaluationGeneration)
                }
            }
        }
        // Se o refresh compartilhado acordou para o retry, mas uma dependência anterior à captura
        // (por exemplo, opções de localização) falhou, não deixa o prazo consumido sem novo backstop.
        if trigger == .accuracyRetry, let episode = accuracyRetryEpisode,
           episode.nextRetryAt <= clock.now(), accuracyRetryTask == nil {
            await advanceAccuracyRetry(episode)
        }
        backgroundTaskGuard.end(token)
        if trigger == .foreground,
           evaluationGeneration == accuracyRetryGeneration,
           pauseEvaluationGeneration == scheduledPauseGeneration {
            // Consome a solicitação somente depois de uma avaliação da mesma geração. Se alguma
            // invalidação atravessou um await, ela permanece pendente e é drenada com um snapshot novo.
            pendingPauseReconciliation = false
        }
        isRunning = false
        await drainPendingWorkIfNeeded()
    }

    /// Acidente em background, independente do auto (§8/§10). Mesmo single-flight que `runOnce`.
    func runAccidentCheck() async {
        await waitForAutomationContextInvalidationIfNeeded()
        if isRunning { return }
        isRunning = true
        await runAccidentCheckLocked()
        isRunning = false
        await drainPendingWorkIfNeeded()
    }

    private func runAccidentCheckLocked() async {
        let chave = await appPrefs.chave()
        guard !chave.isEmpty else { return }
        let lang = resolveEffectiveLanguageCode(await appPrefs.language())
        let userSettings = await loadUserSettings(chave)
        guard userSettings.notifyAccident else { return }   // antes de QUALQUER query
        isSessionExpired = false
        await maybeNotifyAccident(chave, notifyAccident: true, lang: lang)
        if isSessionExpired, await attemptSilentRelogin(chave, lang) {
            isSessionExpired = false
            await maybeNotifyAccident(chave, notifyAccident: true, lang: lang)
        }
    }

    // MARK: - Fluxo de 7 passos

    private func runOnceLocked(
        _ trigger: OrchestratorTrigger,
        generation: UInt64,
        pauseGeneration: UInt64
    ) async {
        guard generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration else { return }
        // 1 — Auth
        let chave = await appPrefs.chave()
        if chave.isEmpty {
            await cancelAccuracyRetryEpisode()
            await cancelScheduledPauseRuntime(clearActiveFlag: true, lang: "pt")
            return
        }
        let lang = resolveEffectiveLanguageCode(await appPrefs.language())
        activityLogger.logTrigger(trigger.name)

        // 2 — Settings, acidente ANTES do gate, toggle, pausa
        let userSettings = await loadUserSettings(chave)
        guard generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration else { return }
        if let episode = accuracyRetryEpisode,
           episode.chave != chave || episode.activeProject != userSettings.activeProject
                || userSettings.activeProject.isEmpty {
            await cancelAccuracyRetryEpisode()
        }
        // Um pedido BG já cancelado pode, em corrida, alcançar seu handler. Sem o episódio correspondente
        // ele é inócuo e não abre outro episódio por conta própria.
        if trigger == .accuracyRetry, accuracyRetryEpisode == nil { return }
        await maybeNotifyAccident(chave, notifyAccident: userSettings.notifyAccident, lang: lang)

        if !userSettings.automaticActivitiesEnabled {
            await cancelAccuracyRetryEpisode()
            await cancelScheduledPauseRuntime(clearActiveFlag: true, lang: lang)
            appRefreshScheduler.clearPauseTransitionDeadlineAndScheduleRegular()
            EvaluationLog.shared.record(EvaluationEntry(at: clock.now(), trigger: trigger, accuracyMeters: nil,
                                                        resolvedLocal: nil, decidedAction: nil, outcome: .toggleOff))
            activityLogger.logSystem("Automatic activities are OFF.", .warning)
            return
        }

        let pauseSettings = ScheduledPauseSettings(
            scheduledPauseEnabled: userSettings.scheduledPauseEnabled, scheduledPauseFrom: userSettings.scheduledPauseFrom,
            scheduledPauseTo: userSettings.scheduledPauseTo, suspendSaturdays: userSettings.suspendSaturdays,
            suspendSundays: userSettings.suspendSundays)
        let calendar = Calendar.current            // fuso do APARELHO para a pausa (§7)
        let now = clock.now()
        let pauseGate = await reconcileScheduledPauseGate(
            trigger: trigger,
            chave: chave,
            userSettings: userSettings,
            pauseSettings: pauseSettings,
            calendar: calendar,
            now: now,
            generation: pauseGeneration,
            lang: lang)
        guard generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration else { return }
        let stateFromPauseGate: HistoryState?
        let usedFreshState: Bool
        switch pauseGate {
        case .stop(let outcome):
            EvaluationLog.shared.record(EvaluationEntry(
                at: clock.now(),
                trigger: trigger,
                accuracyMeters: nil,
                resolvedLocal: nil,
                decidedAction: nil,
                outcome: outcome))
            return
        case .proceed(let currentState, let fresh):
            stateFromPauseGate = currentState
            usedFreshState = fresh
        }

        // 3 — Opções (TTL 15min + fallback offline)
        guard let options = await getLocationOptions() else { return }

        // 4 — Skip-if-unchanged (só TIMER)
        // NB (fiel ao Kotlin): `lastCaptureAccuracyMeters` só é resetado aqui, no bloco TIMER. Uma run
        // .geofence/.significantLocation/.foreground registra o valor da última run TIMER (ou nil) — mesmo
        // comportamento do Android para todos os gatilhos orientados por evento.
        if trigger == .timer, accuracyRetryEpisode == nil {
            lastCaptureAccuracyMeters = nil
            if await shouldSkip(options.accuracyThresholdMeters) == .skip {
                EvaluationLog.shared.record(EvaluationEntry(at: clock.now(), trigger: trigger, accuracyMeters: lastCaptureAccuracyMeters,
                                                            resolvedLocal: nil, decidedAction: nil, outcome: .skip))
                activityLogger.logSystem("Auto-check skipped (no movement).", .info)
                return
            }
        }

        // 5–6 — Estado, projetos, motor, cache
        let currentState = usedFreshState ? stateFromPauseGate : await getRemoteState(chave)
        let userProjects = UserProjects(projects: userSettings.projects, activeProject: userSettings.activeProject)
        // Não deixa uma invalidação ocorrida durante auth/settings/state transformar esta run antiga em
        // uma avaliação nova. Uma invalidação durante o próprio use-case é filtrada na reconciliação abaixo.
        guard generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration else { return }
        let result = await runAutomaticActivities(chave: chave, userProjects: userProjects, currentState: currentState,
                                                  mixedZoneIntervalMinutes: options.mixedZoneIntervalMinutes,
                                                  accuracyThresholdMeters: options.accuracyThresholdMeters)
        guard generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration else { return }
        if case .submitted(_, _, let newState) = result {
            cachedState = newState; cacheChave = chave; cachedStateAt = clock.now()
        }
        await reconcileAccuracyRetryEpisode(
            after: result,
            trigger: trigger,
            chave: chave,
            activeProject: userSettings.activeProject,
            lang: lang,
            generation: generation)
        if case .submitted(let action, _, let newState) = result {
            await reconcileAcceptedCheckForScheduledPause(
                chave: chave,
                project: userSettings.activeProject,
                action: action,
                newState: newState,
                expectedPauseGeneration: pauseGeneration,
                lang: lang)
        }
        if case .noAction = result {
            activityLogger.logSystem("No action needed (already checked in/out).", .info)
        }
        EvaluationLog.shared.record(EvaluationEntry(
            at: clock.now(), trigger: trigger, accuracyMeters: lastCaptureAccuracyMeters,
            resolvedLocal: submittedLocal(result), decidedAction: submittedActionName(result), outcome: outcome(of: result)))

        // 7 — Notificação de atividade
        if case .submitted(let action, let local, _) = result, trigger != .foreground, userSettings.notifyActivities {
            notifications.postActivityNotification(action: action, local: local, lang: lang)
        }
    }

    // MARK: - Helpers

    private func loadUserSettings(_ chave: String) async -> UserSettings {
        let rawJson = await appPrefs.userSettingsJson()
        let map = try? JSONCoding.decoder.decode([String: UserSettings].self, from: Data(rawJson.utf8))   // erro → nil
        return resolvePersistedUserSettings(map, chave)
    }

    // MARK: - Exceção da Pausa Programada

    private func reconcileScheduledPauseGate(
        trigger: OrchestratorTrigger,
        chave: String,
        userSettings: UserSettings,
        pauseSettings: ScheduledPauseSettings,
        calendar: Calendar,
        now: Date,
        generation: UInt64,
        lang: String
    ) async -> ScheduledPauseGateResult {
        guard generation == scheduledPauseGeneration else {
            return .stop(.noAction)
        }

        let persistedFlag = await appPrefs.getFlag(Self.flagPauseActive)
        guard generation == scheduledPauseGeneration else {
            return .stop(.noAction)
        }

        guard let window = currentScheduledPauseWindow(now, calendar, pauseSettings) else {
            let endedRuntime = scheduledPauseDeferral
            let hasPauseStateToCleanUp = endedRuntime != nil || persistedFlag
            let shouldNotifyEnd = persistedFlag
                && endedRuntime?.phase == .active
                && endedRuntime?.chave == chave
                && endedRuntime?.activeProject == userSettings.activeProject
            var preserveConsumedResumeNotification = false
            if shouldNotifyEnd {
                let alreadyScheduled = await pauseAlarms.consumeScheduledTransition(
                    started: false,
                    dueAtOrBefore: now)
                guard generation == scheduledPauseGeneration else {
                    return .stop(.noAction)
                }
                preserveConsumedResumeNotification =
                    alreadyScheduled && userSettings.notifyScheduledPause
                if userSettings.notifyScheduledPause && !alreadyScheduled {
                    notifications.postScheduledPauseTransition(started: false, lang: lang)
                }
                activityLogger.logActive("Scheduled pause ended.")
            }
            if hasPauseStateToCleanUp {
                await cancelScheduledPauseRuntime(
                    clearActiveFlag: true,
                    lang: lang,
                    preserveResumeNotification: preserveConsumedResumeNotification)
            }
            guard generation == scheduledPauseGeneration else {
                return .stop(.noAction)
            }
            if let nextStart = nextPauseStartInstant(now, calendar, pauseSettings) {
                armScheduledPauseTransition(at: nextStart)
            } else {
                pauseTransitionTask?.cancel()
                pauseTransitionTask = nil
                pauseTransitionEpochMs = nil
                appRefreshScheduler.clearPauseTransitionDeadlineAndScheduleRegular()
            }
            // Não agenda notificação local de início: ela poderia afirmar uma pausa que será adiada.
            await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
            if hasPauseStateToCleanUp && !preserveConsumedResumeNotification {
                await pauseAlarms.scheduleResume(at: nil, notify: false, lang: lang)
            }
            return .proceed(currentState: nil, usedFreshState: false)
        }

        armScheduledPauseTransition(at: window.end)
        if let runtime = scheduledPauseDeferral,
           !scheduledPauseRuntime(
               runtime,
               matchesChave: chave,
               activeProject: userSettings.activeProject,
               settings: pauseSettings,
               window: window) {
            await cancelScheduledPauseRuntime(clearActiveFlag: true, lang: lang)
        } else if scheduledPauseDeferral == nil, persistedFlag {
            // O bool legado/global não é identidade suficiente para outra conta/projeto/ocorrência.
            await appPrefs.setFlag(Self.flagPauseActive, false)
            await pauseAlarms.scheduleResume(at: nil, notify: false, lang: lang)
        }
        guard generation == scheduledPauseGeneration else {
            return .stop(.noAction)
        }

        switch scheduledPauseDeferral?.phase {
        case .active:
            await maintainActiveScheduledPause(
                window: window,
                userSettings: userSettings,
                generation: generation,
                lang: lang)
            return .stop(.paused)

        case .terminal:
            await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
            await pauseAlarms.scheduleResume(at: nil, notify: false, lang: lang)
            appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
            await cancelAccuracyRetryEpisode()
            return .stop(.noAction)

        case .activationScheduled:
            guard let runtime = scheduledPauseDeferral,
                  let dueAt = runtime.activationAt else {
                await transitionScheduledPauseToAwaiting(
                    chave: chave,
                    activeProject: userSettings.activeProject,
                    settings: pauseSettings,
                    window: window,
                    generation: generation,
                    lang: lang)
                return .proceed(currentState: nil, usedFreshState: false)
            }
            if dueAt >= window.end {
                await transitionScheduledPauseToTerminal(
                    runtime,
                    generation: generation,
                    lang: lang)
                await cancelAccuracyRetryEpisode()
                return .stop(.noAction)
            }
            if dueAt > now {
                await cancelAccuracyRetryEpisode()
                await armScheduledPauseActivation(
                    runtime,
                    userSettings: userSettings,
                    generation: generation,
                    lang: lang)
                return .stop(.noAction)
            }

            switch await getFreshRemoteState(chave) {
            case .success(let state):
                guard generation == scheduledPauseGeneration else {
                    return .stop(.noAction)
                }
                switch resolveLastRecordedAction(state) {
                case .checkIn:
                    await transitionScheduledPauseToAwaiting(
                        chave: chave,
                        activeProject: userSettings.activeProject,
                        settings: pauseSettings,
                        window: window,
                        generation: generation,
                        lang: lang)
                    return .proceed(currentState: state, usedFreshState: true)

                case .checkOut:
                    // O estado fresco pode conter um checkout mais novo que aquele que originou o
                    // deadline (inclusive vindo de outro cliente). Reancora sempre pelos dados da API
                    // para preservar os dez segundos completos antes de ativar a pausa.
                    return await scheduleOrActivateAfterConfirmedCheckout(
                        state: state,
                        chave: chave,
                        activeProject: userSettings.activeProject,
                        settings: pauseSettings,
                        window: window,
                        userSettings: userSettings,
                        generation: generation,
                        now: now,
                        lang: lang)

                case nil:
                    await activateScheduledPause(
                        runtime,
                        userSettings: userSettings,
                        generation: generation,
                        now: now,
                        lang: lang)
                    return .stop(.paused)
                }

            case .failure(let error):
                // Sem confirmação não converte grace em ACTIVE. Voltar a AWAITING conserva a
                // possibilidade de um estado confirmado/foreground resolver antes do próximo wake.
                await transitionScheduledPauseToAwaiting(
                    chave: chave,
                    activeProject: userSettings.activeProject,
                    settings: pauseSettings,
                    window: window,
                    generation: generation,
                    lang: lang)
                guard generation == scheduledPauseGeneration,
                      let awaitingRuntime = scheduledPauseDeferral else {
                    return .stop(.networkError)
                }
                if shouldRetryScheduledPauseConfirmation(error) {
                    await scheduleScheduledPauseConfirmationRetry(
                        awaitingRuntime,
                        retryAt: now.addingTimeInterval(Self.scheduledPauseActivationDelay),
                        userSettings: userSettings,
                        generation: generation,
                        lang: lang)
                }
                return .stop(.networkError)
            }

        case .awaitingCheckout, nil:
            switch await getFreshRemoteState(chave) {
            case .failure(let error):
                let previousRetryAt =
                    scheduledPauseDeferral?.phase == .awaitingCheckout
                        ? scheduledPauseDeferral?.activationAt
                        : nil
                await transitionScheduledPauseToAwaiting(
                    chave: chave,
                    activeProject: userSettings.activeProject,
                    settings: pauseSettings,
                    window: window,
                    generation: generation,
                    lang: lang)
                guard generation == scheduledPauseGeneration,
                      let runtime = scheduledPauseDeferral else {
                    return .stop(.networkError)
                }
                if shouldRetryScheduledPauseConfirmation(error) {
                    let retryAt: Date
                    if let previousRetryAt, previousRetryAt > now {
                        retryAt = previousRetryAt
                    } else {
                        retryAt = now.addingTimeInterval(
                            previousRetryAt == nil
                                ? Self.scheduledPauseActivationDelay
                                : Self.scheduledPauseConfirmationBackoff)
                    }
                    // A confirmação remota é conservadora: uma falha nunca equivale a "sem check-in".
                    // O primeiro retry transitório é rápido; falhas consecutivas recuam para três minutos
                    // para não consultar a API seis vezes por minuto durante uma indisponibilidade longa.
                    await scheduleScheduledPauseConfirmationRetry(
                        runtime,
                        retryAt: retryAt,
                        userSettings: userSettings,
                        generation: generation,
                        lang: lang)
                }
                // Falha não equivale a "sem histórico". Sem estado confirmado, o motor poderia interpretar
                // nil como primeiro uso e criar um CHECKIN; aguarda a confirmação conservadoramente.
                return .stop(.networkError)

            case .success(let state):
                guard generation == scheduledPauseGeneration else {
                    return .stop(.noAction)
                }
                switch resolveLastRecordedAction(state) {
                case .checkIn:
                    await transitionScheduledPauseToAwaiting(
                        chave: chave,
                        activeProject: userSettings.activeProject,
                        settings: pauseSettings,
                        window: window,
                        generation: generation,
                        lang: lang)
                    return .proceed(currentState: state, usedFreshState: true)

                case .checkOut:
                    if scheduledPauseDeferral?.phase == .awaitingCheckout
                        || checkoutOccurredInsideWindow(state, window) {
                        return await scheduleOrActivateAfterConfirmedCheckout(
                            state: state,
                            chave: chave,
                            activeProject: userSettings.activeProject,
                            settings: pauseSettings,
                            window: window,
                            userSettings: userSettings,
                            generation: generation,
                            now: now,
                            lang: lang)
                    }
                    let runtime = makeScheduledPauseRuntime(
                        chave: chave,
                        activeProject: userSettings.activeProject,
                        settings: pauseSettings,
                        window: window,
                        phase: .active)
                    await activateScheduledPause(
                        runtime,
                        userSettings: userSettings,
                        generation: generation,
                        now: now,
                        lang: lang)
                    return .stop(.paused)

                case nil:
                    // GET bem-sucedido sem atividade é diferente de falha: não há check-in aberto.
                    let runtime = makeScheduledPauseRuntime(
                        chave: chave,
                        activeProject: userSettings.activeProject,
                        settings: pauseSettings,
                        window: window,
                        phase: .active)
                    await activateScheduledPause(
                        runtime,
                        userSettings: userSettings,
                        generation: generation,
                        now: now,
                        lang: lang)
                    return .stop(.paused)
                }
            }
        }
    }

    private func scheduleOrActivateAfterConfirmedCheckout(
        state: HistoryState,
        chave: String,
        activeProject: String,
        settings: ScheduledPauseSettings,
        window: ScheduledPauseWindow,
        userSettings: UserSettings,
        generation: UInt64,
        now: Date,
        lang: String
    ) async -> ScheduledPauseGateResult {
        let dueAt = state.lastCheckoutAt
            .map { $0.addingTimeInterval(Self.scheduledPauseActivationDelay) }
            ?? now.addingTimeInterval(Self.scheduledPauseActivationDelay)
        var runtime = scheduledPauseDeferral
            ?? makeScheduledPauseRuntime(
                chave: chave,
                activeProject: activeProject,
                settings: settings,
                window: window,
                phase: .awaitingCheckout)
        if dueAt >= window.end {
            await transitionScheduledPauseToTerminal(runtime, generation: generation, lang: lang)
            await cancelAccuracyRetryEpisode()
            return .stop(.noAction)
        }
        if dueAt <= now {
            runtime.phase = .active
            runtime.activationEpochMs = nil
            await activateScheduledPause(
                runtime,
                userSettings: userSettings,
                generation: generation,
                now: now,
                lang: lang)
            return .stop(.paused)
        }
        runtime.phase = .activationScheduled
        runtime.activationEpochMs = epochMs(dueAt)
        await persistScheduledPauseRuntime(runtime)
        guard generation == scheduledPauseGeneration else {
            return .stop(.noAction)
        }
        await cancelAccuracyRetryEpisode()
        await armScheduledPauseActivation(
            runtime,
            userSettings: userSettings,
            generation: generation,
            lang: lang)
        return .stop(.noAction)
    }

    private func checkoutOccurredInsideWindow(
        _ state: HistoryState,
        _ window: ScheduledPauseWindow
    ) -> Bool {
        guard let at = state.lastCheckoutAt else { return false }
        return at >= window.start && at < window.end
    }

    private func makeScheduledPauseRuntime(
        chave: String,
        activeProject: String,
        settings: ScheduledPauseSettings,
        window: ScheduledPauseWindow,
        phase: ScheduledPauseDeferralPhase
    ) -> ScheduledPauseDeferral {
        ScheduledPauseDeferral(
            id: UUID().uuidString,
            chave: chave,
            activeProject: activeProject,
            settings: settings,
            windowStartEpochMs: epochMs(window.start),
            windowEndEpochMs: epochMs(window.end),
            phase: phase,
            activationEpochMs: nil)
    }

    private func scheduledPauseRuntime(
        _ runtime: ScheduledPauseDeferral,
        matchesChave chave: String,
        activeProject: String,
        settings: ScheduledPauseSettings,
        window: ScheduledPauseWindow
    ) -> Bool {
        runtime.chave == chave
            && runtime.activeProject == activeProject
            && runtime.settings == settings
            && runtime.windowStartEpochMs == epochMs(window.start)
            && runtime.windowEndEpochMs == epochMs(window.end)
    }

    private func transitionScheduledPauseToAwaiting(
        chave: String,
        activeProject: String,
        settings: ScheduledPauseSettings,
        window: ScheduledPauseWindow,
        generation: UInt64,
        lang: String
    ) async {
        guard generation == scheduledPauseGeneration else { return }
        var runtime = scheduledPauseDeferral
            ?? makeScheduledPauseRuntime(
                chave: chave,
                activeProject: activeProject,
                settings: settings,
                window: window,
                phase: .awaitingCheckout)
        runtime.phase = .awaitingCheckout
        runtime.activationEpochMs = nil
        pauseActivationTask?.cancel()
        pauseActivationTask = nil
        scheduledPauseDeferral = runtime
        await persistScheduledPauseRuntime(runtime)
        guard generation == scheduledPauseGeneration,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .awaitingCheckout else { return }
        appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
        armScheduledPauseTransition(at: window.end)
        await appPrefs.setFlag(Self.flagPauseActive, false)
        await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
        await pauseAlarms.scheduleResume(at: nil, notify: false, lang: lang)
    }

    private func transitionScheduledPauseToTerminal(
        _ existing: ScheduledPauseDeferral,
        generation: UInt64,
        lang: String
    ) async {
        guard generation == scheduledPauseGeneration else { return }
        var runtime = existing
        runtime.phase = .terminal
        runtime.activationEpochMs = nil
        pauseActivationTask?.cancel()
        pauseActivationTask = nil
        scheduledPauseDeferral = runtime
        await persistScheduledPauseRuntime(runtime)
        guard generation == scheduledPauseGeneration else { return }
        appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
        armScheduledPauseTransition(at: runtime.windowEnd)
        await appPrefs.setFlag(Self.flagPauseActive, false)
        await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
        await pauseAlarms.scheduleResume(at: nil, notify: false, lang: lang)
    }

    private func activateScheduledPause(
        _ existing: ScheduledPauseDeferral,
        userSettings: UserSettings,
        generation: UInt64,
        now: Date,
        lang: String
    ) async {
        guard generation == scheduledPauseGeneration,
              now < existing.windowEnd else { return }
        var runtime = existing
        runtime.phase = .active
        runtime.activationEpochMs = nil
        scheduledPauseDeferral = runtime
        await persistScheduledPauseRuntime(runtime)
        guard generation == scheduledPauseGeneration else { return }
        pauseActivationTask?.cancel()
        pauseActivationTask = nil
        appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
        armScheduledPauseTransition(at: runtime.windowEnd)
        let alreadyScheduled = await pauseAlarms.consumeScheduledTransition(
            started: true,
            dueAtOrBefore: now)
        guard generation == scheduledPauseGeneration,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        let wasPaused = await appPrefs.getFlag(Self.flagPauseActive)
        guard generation == scheduledPauseGeneration,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        await appPrefs.setFlag(Self.flagPauseActive, true)
        guard generation == scheduledPauseGeneration,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        if !wasPaused {
            if userSettings.notifyScheduledPause && !alreadyScheduled {
                notifications.postScheduledPauseTransition(started: true, lang: lang)
            }
            activityLogger.logInactive("Scheduled pause started.")
        }
        await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
        guard generation == scheduledPauseGeneration,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        await pauseAlarms.scheduleResume(
            at: runtime.windowEnd,
            notify: userSettings.notifyScheduledPause,
            lang: lang)
        guard generation == scheduledPauseGeneration,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        await cancelAccuracyRetryEpisode()
    }

    private func maintainActiveScheduledPause(
        window: ScheduledPauseWindow,
        userSettings: UserSettings,
        generation: UInt64,
        lang: String
    ) async {
        guard generation == scheduledPauseGeneration,
              let runtime = scheduledPauseDeferral,
              runtime.phase == .active else { return }
        await appPrefs.setFlag(Self.flagPauseActive, true)
        guard generation == scheduledPauseGeneration,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
        armScheduledPauseTransition(at: window.end)
        await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
        guard generation == scheduledPauseGeneration,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        await pauseAlarms.scheduleResume(
            at: window.end,
            notify: userSettings.notifyScheduledPause,
            lang: lang)
        guard generation == scheduledPauseGeneration,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        await cancelAccuracyRetryEpisode()
    }

    private func scheduleScheduledPauseConfirmationRetry(
        _ existing: ScheduledPauseDeferral,
        retryAt: Date,
        userSettings: UserSettings,
        generation: UInt64,
        lang: String
    ) async {
        guard generation == scheduledPauseGeneration,
              existing.phase == .awaitingCheckout else { return }
        guard retryAt < existing.windowEnd else {
            appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
            return
        }
        var runtime = existing
        runtime.activationEpochMs = epochMs(retryAt)
        await persistScheduledPauseRuntime(runtime)
        guard generation == scheduledPauseGeneration else { return }
        await armScheduledPauseActivation(
            runtime,
            userSettings: userSettings,
            generation: generation,
            lang: lang)
    }

    private func shouldRetryScheduledPauseConfirmation(_ error: ApiError) -> Bool {
        switch error {
        case .network:
            return true
        case .http(let status, _):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .unauthorized, .conflict, .unknown:
            return false
        }
    }

    private func armScheduledPauseActivation(
        _ runtime: ScheduledPauseDeferral,
        userSettings: UserSettings,
        generation: UInt64,
        lang: String
    ) async {
        let supportsActivationWake =
            runtime.phase == .activationScheduled || runtime.phase == .awaitingCheckout
        guard generation == scheduledPauseGeneration,
              supportsActivationWake,
              let dueAt = runtime.activationAt,
              dueAt < runtime.windowEnd else { return }
        pauseActivationTask?.cancel()
        appRefreshScheduler.schedulePauseActivation(at: dueAt)
        armScheduledPauseTransition(at: runtime.windowEnd)
        // Não há notificação antecipada durante grace/retry de confirmação: um CHECKIN em outro cliente
        // pode ocorrer antes do vencimento. A mensagem só é postada após o GET fresco confirmar a ativação.
        await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
        guard generation == scheduledPauseGeneration,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.activationEpochMs == runtime.activationEpochMs else { return }
        let remaining = max(0, dueAt.timeIntervalSince(clock.now()))
        let milliseconds = Int((remaining * 1_000).rounded(.up))
        let sleeper = pauseActivationSleeper
        let runtimeID = runtime.id
        let dueEpochMs = runtime.activationEpochMs!
        pauseActivationTask = Task { [weak self] in
            await sleeper.sleep(milliseconds: milliseconds)
            guard !Task.isCancelled else { return }
            await self?.scheduledPauseActivationTaskFired(
                runtimeID: runtimeID,
                dueEpochMs: dueEpochMs)
        }
    }

    private func scheduledPauseActivationTaskFired(runtimeID: String, dueEpochMs: Int64) async {
        guard let runtime = scheduledPauseDeferral,
              runtime.id == runtimeID,
              (runtime.phase == .activationScheduled || runtime.phase == .awaitingCheckout),
              runtime.activationEpochMs == dueEpochMs else { return }
        pauseActivationTask = nil
        if isRunning {
            pendingPauseActivation = true
            return
        }
        await runOnce(.pauseActivation)
    }

    private func armScheduledPauseTransition(at deadline: Date) {
        pauseTransitionTask?.cancel()
        let deadlineEpochMs = epochMs(deadline)
        pauseTransitionEpochMs = deadlineEpochMs
        appRefreshScheduler.schedulePauseTransition(at: deadline)
        let remaining = max(0, deadline.timeIntervalSince(clock.now()))
        let milliseconds = Int((remaining * 1_000).rounded(.up))
        let sleeper = pauseTransitionSleeper
        pauseTransitionTask = Task { [weak self] in
            await sleeper.sleep(milliseconds: milliseconds)
            guard !Task.isCancelled else { return }
            await self?.scheduledPauseTransitionTaskFired(dueEpochMs: deadlineEpochMs)
        }
    }

    private func scheduledPauseTransitionTaskFired(dueEpochMs: Int64) async {
        guard pauseTransitionEpochMs == dueEpochMs else { return }
        pauseTransitionTask = nil
        pauseTransitionEpochMs = nil
        if isRunning {
            pendingPauseTransition = true
            return
        }
        await runOnce(.pauseTransition)
    }

    private func persistScheduledPauseRuntime(_ runtime: ScheduledPauseDeferral) async {
        scheduledPauseDeferral = runtime
        guard let data = try? JSONCoding.encoder.encode(runtime),
              let json = String(data: data, encoding: .utf8) else { return }
        await appPrefs.setScheduledPauseDeferralJson(json)
    }

    private func restoreScheduledPauseDeferralIfNeeded() async {
        guard !didRestoreScheduledPauseDeferral else { return }
        didRestoreScheduledPauseDeferral = true
        let generation = scheduledPauseGeneration
        let raw = await appPrefs.scheduledPauseDeferralJson()
        guard generation == scheduledPauseGeneration else { return }
        guard !raw.isEmpty else { return }
        guard let restored = try? JSONCoding.decoder.decode(
            ScheduledPauseDeferral.self,
            from: Data(raw.utf8)
        ) else {
            await appPrefs.setScheduledPauseDeferralJson("")
            appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
            return
        }
        scheduledPauseDeferral = restored
    }

    private func cancelScheduledPauseRuntime(
        clearActiveFlag: Bool,
        lang: String,
        preserveResumeNotification: Bool = false
    ) async {
        pauseActivationTask?.cancel()
        pauseActivationTask = nil
        pauseTransitionTask?.cancel()
        pauseTransitionTask = nil
        pauseTransitionEpochMs = nil
        pendingPauseActivation = false
        scheduledPauseDeferral = nil
        await appPrefs.setScheduledPauseDeferralJson("")
        appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
        appRefreshScheduler.clearPauseTransitionDeadlineAndScheduleRegular()
        await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
        if !preserveResumeNotification {
            await pauseAlarms.scheduleResume(at: nil, notify: false, lang: lang)
        }
        if clearActiveFlag {
            await appPrefs.setFlag(Self.flagPauseActive, false)
        }
    }

    /// Evento confirmado fora do motor (submit manual ou replay concluído). O estado devolvido pelo
    /// servidor, e não apenas a ação solicitada, decide se o checkout realmente ficou por último.
    func acceptedCheck(
        chave: String,
        project: String,
        action: CheckAction,
        newState: HistoryState
    ) async {
        await waitForAutomationContextInvalidationIfNeeded()
        await restoreScheduledPauseDeferralIfNeeded()
        guard await appPrefs.chave() == chave else { return }
        let lang = resolveEffectiveLanguageCode(await appPrefs.language())
        let userSettings = await loadUserSettings(chave)
        guard userSettings.automaticActivitiesEnabled,
              userSettings.activeProject == project,
              userSettings.projects.contains(project),
              newState.projeto == nil || newState.projeto == project,
              await appPrefs.chave() == chave else { return }
        accuracyRetryGeneration &+= 1
        scheduledPauseGeneration &+= 1
        let generation = scheduledPauseGeneration
        await cancelAccuracyRetryEpisode(forceCleanup: true)
        guard generation == scheduledPauseGeneration else { return }
        let settings = ScheduledPauseSettings(
            scheduledPauseEnabled: userSettings.scheduledPauseEnabled,
            scheduledPauseFrom: userSettings.scheduledPauseFrom,
            scheduledPauseTo: userSettings.scheduledPauseTo,
            suspendSaturdays: userSettings.suspendSaturdays,
            suspendSundays: userSettings.suspendSundays)
        let now = clock.now()
        let calendar = Calendar.current
        guard let window = currentScheduledPauseWindow(now, calendar, settings) else { return }
        armScheduledPauseTransition(at: window.end)

        if let runtime = scheduledPauseDeferral,
           !scheduledPauseRuntime(
               runtime,
               matchesChave: chave,
               activeProject: project,
               settings: settings,
               window: window) {
            await cancelScheduledPauseRuntime(clearActiveFlag: true, lang: lang)
        }
        guard generation == scheduledPauseGeneration else { return }
        if scheduledPauseDeferral?.phase == .active
            || scheduledPauseDeferral?.phase == .terminal {
            return
        }

        switch resolveLastRecordedAction(newState) {
        case .checkIn:
            await transitionScheduledPauseToAwaiting(
                chave: chave,
                activeProject: project,
                settings: settings,
                window: window,
                generation: generation,
                lang: lang)

        case .checkOut:
            _ = await scheduleOrActivateAfterConfirmedCheckout(
                state: newState,
                chave: chave,
                activeProject: project,
                settings: settings,
                window: window,
                userSettings: userSettings,
                generation: generation,
                now: now,
                lang: lang)

        case nil:
            break
        }
    }

    func confirmedState(chave: String, newState: HistoryState) async {
        await waitForAutomationContextInvalidationIfNeeded()
        await restoreScheduledPauseDeferralIfNeeded()
        guard await appPrefs.chave() == chave else { return }
        let lang = resolveEffectiveLanguageCode(await appPrefs.language())
        let userSettings = await loadUserSettings(chave)
        guard userSettings.automaticActivitiesEnabled,
              !userSettings.activeProject.isEmpty,
              userSettings.projects.contains(userSettings.activeProject),
              newState.projeto == nil || newState.projeto == userSettings.activeProject,
              await appPrefs.chave() == chave else { return }
        scheduledPauseGeneration &+= 1
        let generation = scheduledPauseGeneration
        let settings = ScheduledPauseSettings(
            scheduledPauseEnabled: userSettings.scheduledPauseEnabled,
            scheduledPauseFrom: userSettings.scheduledPauseFrom,
            scheduledPauseTo: userSettings.scheduledPauseTo,
            suspendSaturdays: userSettings.suspendSaturdays,
            suspendSundays: userSettings.suspendSundays)
        let now = clock.now()
        guard let window = currentScheduledPauseWindow(now, Calendar.current, settings) else { return }
        armScheduledPauseTransition(at: window.end)
        if let runtime = scheduledPauseDeferral,
           !scheduledPauseRuntime(
               runtime,
               matchesChave: chave,
               activeProject: userSettings.activeProject,
               settings: settings,
               window: window) {
            await cancelScheduledPauseRuntime(clearActiveFlag: true, lang: lang)
        }
        guard generation == scheduledPauseGeneration,
              scheduledPauseDeferral?.phase != .active,
              scheduledPauseDeferral?.phase != .terminal else { return }

        switch resolveLastRecordedAction(newState) {
        case .checkIn:
            await transitionScheduledPauseToAwaiting(
                chave: chave,
                activeProject: userSettings.activeProject,
                settings: settings,
                window: window,
                generation: generation,
                lang: lang)
        case .checkOut:
            _ = await scheduleOrActivateAfterConfirmedCheckout(
                state: newState,
                chave: chave,
                activeProject: userSettings.activeProject,
                settings: settings,
                window: window,
                userSettings: userSettings,
                generation: generation,
                now: now,
                lang: lang)
        case nil:
            if let runtime = scheduledPauseDeferral,
               runtime.phase == .activationScheduled,
               let dueAt = runtime.activationAt,
               dueAt > now {
                await armScheduledPauseActivation(
                    runtime,
                    userSettings: userSettings,
                    generation: generation,
                    lang: lang)
                return
            }
            let runtime = scheduledPauseDeferral
                ?? makeScheduledPauseRuntime(
                    chave: chave,
                    activeProject: userSettings.activeProject,
                    settings: settings,
                    window: window,
                    phase: .active)
            await activateScheduledPause(
                runtime,
                userSettings: userSettings,
                generation: generation,
                now: now,
                lang: lang)
        }
    }

    private func reconcileAcceptedCheckForScheduledPause(
        chave: String,
        project: String,
        action: CheckAction,
        newState: HistoryState,
        expectedPauseGeneration: UInt64,
        lang: String
    ) async {
        guard expectedPauseGeneration == scheduledPauseGeneration,
              let runtime = scheduledPauseDeferral,
              runtime.chave == chave,
              runtime.activeProject == project,
              newState.projeto == nil || newState.projeto == project,
              runtime.phase != .active,
              runtime.phase != .terminal else { return }
        let now = clock.now()
        guard now >= runtime.windowStart, now < runtime.windowEnd else { return }
        let userSettings = await loadUserSettings(chave)
        guard expectedPauseGeneration == scheduledPauseGeneration else { return }
        let window = ScheduledPauseWindow(start: runtime.windowStart, end: runtime.windowEnd)
        switch resolveLastRecordedAction(newState) {
        case .checkIn:
            await transitionScheduledPauseToAwaiting(
                chave: chave,
                activeProject: project,
                settings: runtime.settings,
                window: window,
                generation: expectedPauseGeneration,
                lang: lang)
        case .checkOut:
            _ = await scheduleOrActivateAfterConfirmedCheckout(
                state: newState,
                chave: chave,
                activeProject: project,
                settings: runtime.settings,
                window: window,
                userSettings: userSettings,
                generation: expectedPauseGeneration,
                now: now,
                lang: lang)
        case nil:
            break
        }
    }

    /// Mudança de conta/projeto/toggle: nenhum deadline ou flag do contexto antigo pode sobreviver.
    func invalidateAutomationContext() async {
        if automationContextInvalidationInProgress {
            await waitForAutomationContextInvalidationIfNeeded()
            return
        }
        automationContextInvalidationInProgress = true
        accuracyRetryGeneration &+= 1
        scheduledPauseGeneration &+= 1

        // Tudo que pode criar trabalho novo é removido antes do primeiro await. Entradas concorrentes
        // aguardam o barrier acima, portanto o teardown externo não alcança um episódio do contexto novo.
        accuracyRetryTask?.cancel()
        accuracyRetryTask = nil
        pendingAccuracyRetry = false
        accuracyRetryEpisode = nil
        pauseActivationTask?.cancel()
        pauseActivationTask = nil
        pauseTransitionTask?.cancel()
        pauseTransitionTask = nil
        pauseTransitionEpochMs = nil
        pendingPauseActivation = false
        pendingPauseTransition = false
        pendingPauseReconciliation = false
        scheduledPauseDeferral = nil

        let lang = resolveEffectiveLanguageCode(await appPrefs.language())
        await appPrefs.setAccuracyRetryEpisodeJson("")
        appRefreshScheduler.clearAccuracyRetryDeadlineAndScheduleRegular()
        await notifications.clearLowAccuracyNotification()
        await appPrefs.setScheduledPauseDeferralJson("")
        appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
        appRefreshScheduler.clearPauseTransitionDeadlineAndScheduleRegular()
        await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
        await pauseAlarms.scheduleResume(at: nil, notify: false, lang: lang)
        await appPrefs.setFlag(Self.flagPauseActive, false)

        automationContextInvalidationInProgress = false
        let waiters = automationContextInvalidationWaiters
        automationContextInvalidationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// A edição preserva uma pausa já ACTIVE até avaliar a configuração nova, invalida qualquer decisão
    /// pendente anterior e garante a reconciliação imediata. O pedido fica pendente se outra run estiver
    /// em voo; assim a mudança não depende de um futuro evento de localização/foreground.
    func scheduledPauseSettingsDidChange() async {
        await waitForAutomationContextInvalidationIfNeeded()
        scheduledPauseGeneration &+= 1
        await restoreScheduledPauseDeferralIfNeeded()
        if scheduledPauseDeferral?.phase != .active {
            let lang = resolveEffectiveLanguageCode(await appPrefs.language())
            await cancelScheduledPauseRuntime(clearActiveFlag: false, lang: lang)
        }
        pendingPauseReconciliation = true
        await runOnce(.foreground)
    }

    // MARK: - Episódio de baixa precisão

    /// Invalida avaliações de precisão que atravessaram um `await`. É intencionalmente público no actor
    /// para que OFF, mudança de projeto e submit manual aceito possam encerrar o episódio sem corrida.
    func invalidateAccuracyRetry() async {
        await waitForAutomationContextInvalidationIfNeeded()
        accuracyRetryGeneration &+= 1
        await cancelAccuracyRetryEpisode(forceCleanup: true)
    }

    private func waitForAutomationContextInvalidationIfNeeded() async {
        guard automationContextInvalidationInProgress else { return }
        await withCheckedContinuation { continuation in
            automationContextInvalidationWaiters.append(continuation)
        }
    }

    private func restoreAccuracyRetryEpisodeIfNeeded(armProcessTask: Bool) async {
        guard !didRestoreAccuracyRetryEpisode else { return }
        didRestoreAccuracyRetryEpisode = true
        let generation = accuracyRetryGeneration
        let raw = await appPrefs.accuracyRetryEpisodeJson()
        guard generation == accuracyRetryGeneration else { return }
        guard !raw.isEmpty else { return }
        guard let restored = try? JSONCoding.decoder.decode(
            AccuracyRetryEpisode.self,
            from: Data(raw.utf8)
        ) else {
            await appPrefs.setAccuracyRetryEpisodeJson("")
            appRefreshScheduler.clearAccuracyRetryDeadlineAndScheduleRegular()
            await notifications.clearLowAccuracyNotification()
            return
        }
        accuracyRetryEpisode = restored
        if !restored.notificationPosted {
            let language = resolveEffectiveLanguageCode(await appPrefs.language())
            guard generation == accuracyRetryGeneration,
                  accuracyRetryEpisode?.id == restored.id else {
                await discardStaleAccuracyRetryEpisode(id: restored.id)
                return
            }
            await notifications.postLowAccuracyNotification(
                expectedAction: restored.expectedAction,
                lang: language)
            guard generation == accuracyRetryGeneration,
                  accuracyRetryEpisode?.id == restored.id else {
                await discardStaleAccuracyRetryEpisode(id: restored.id)
                return
            }
            var updated = restored
            updated.notificationPosted = true
            accuracyRetryEpisode = updated
            await persistAccuracyRetryEpisode(updated)
            guard generation == accuracyRetryGeneration,
                  accuracyRetryEpisode?.id == restored.id else {
                await discardStaleAccuracyRetryEpisode(id: restored.id)
                return
            }
        }
        if armProcessTask, generation == accuracyRetryGeneration,
           let episode = accuracyRetryEpisode {
            armAccuracyRetry(episode)
        }
    }

    private func reconcileAccuracyRetryEpisode(
        after result: AutoActivitiesResult,
        trigger: OrchestratorTrigger,
        chave: String,
        activeProject: String,
        lang: String,
        generation: UInt64
    ) async {
        guard generation == accuracyRetryGeneration else { return }
        switch result {
        case .accuracyTooLow(let expectedAction):
            guard await accuracyRetryContextIsEligible(chave: chave, activeProject: activeProject) else {
                await invalidateAccuracyRetry()
                return
            }
            guard generation == accuracyRetryGeneration else { return }
            if let episode = accuracyRetryEpisode,
               episode.chave == chave, episode.activeProject == activeProject {
                // Leituras adicionais não deslocam o prazo original. Só a tentativa que efetivamente venceu
                // o prazo arma o próximo ciclo de 180s.
                if trigger == .accuracyRetry {
                    await advanceAccuracyRetry(episode, generation: generation)
                }
                return
            }
            await startAccuracyRetryEpisode(
                chave: chave,
                activeProject: activeProject,
                expectedAction: expectedAction,
                lang: lang,
                generation: generation)

        case .locationTimeout:
            // Timeout isolado não abre episódio. Se ocorreu na tentativa de um episódio existente, mantém a
            // causa original e arma o próximo ciclo; falta de permissão, abaixo, encerra.
            if let episode = accuracyRetryEpisode,
               episode.chave == chave, episode.activeProject == activeProject,
               trigger == .accuracyRetry {
                await advanceAccuracyRetry(episode, generation: generation)
            }

        case .submitted, .noAction, .networkError, .notConfigured, .noPermission:
            await cancelAccuracyRetryEpisode()
        }
    }

    private func startAccuracyRetryEpisode(
        chave: String,
        activeProject: String,
        expectedAction: CheckAction?,
        lang: String,
        generation: UInt64
    ) async {
        guard generation == accuracyRetryGeneration,
              !chave.isEmpty, !activeProject.isEmpty else { return }
        let dueAt = clock.now().addingTimeInterval(Self.accuracyRetryInterval)
        let episode = AccuracyRetryEpisode(
            id: UUID().uuidString,
            chave: chave,
            activeProject: activeProject,
            nextRetryEpochMs: epochMs(dueAt),
            notificationPosted: false,
            expectedActionRaw: rawExpectedAction(expectedAction))
        accuracyRetryEpisode = episode
        await persistAccuracyRetryEpisode(episode)
        guard generation == accuracyRetryGeneration,
              accuracyRetryEpisode?.id == episode.id else {
            await discardStaleAccuracyRetryEpisode(id: episode.id)
            return
        }
        // O deadline fica durável antes do post: se o processo morrer nessa janela, o refresh compartilhado
        // ainda acorda no prazo e a restauração repõe a notificação pelo identificador estável.
        appRefreshScheduler.scheduleAccuracyRetry(at: episode.nextRetryAt)
        await notifications.postLowAccuracyNotification(expectedAction: expectedAction, lang: lang)
        guard generation == accuracyRetryGeneration,
              accuracyRetryEpisode?.id == episode.id else {
            await discardStaleAccuracyRetryEpisode(id: episode.id)
            return
        }
        var notifiedEpisode = episode
        notifiedEpisode.notificationPosted = true
        accuracyRetryEpisode = notifiedEpisode
        await persistAccuracyRetryEpisode(notifiedEpisode)
        guard generation == accuracyRetryGeneration,
              accuracyRetryEpisode?.id == episode.id else {
            await discardStaleAccuracyRetryEpisode(id: episode.id)
            return
        }
        armAccuracyRetry(notifiedEpisode, scheduleBackgroundRefresh: false)
    }

    private func advanceAccuracyRetry(
        _ current: AccuracyRetryEpisode,
        generation: UInt64? = nil
    ) async {
        let expectedGeneration = generation ?? accuracyRetryGeneration
        guard expectedGeneration == accuracyRetryGeneration,
              accuracyRetryEpisode?.id == current.id else { return }
        var next = current
        next.nextRetryEpochMs = epochMs(clock.now().addingTimeInterval(Self.accuracyRetryInterval))
        accuracyRetryEpisode = next
        await persistAccuracyRetryEpisode(next)
        guard expectedGeneration == accuracyRetryGeneration,
              accuracyRetryEpisode?.id == current.id else {
            await discardStaleAccuracyRetryEpisode(id: current.id)
            return
        }
        armAccuracyRetry(next)
    }

    private func armAccuracyRetry(
        _ episode: AccuracyRetryEpisode,
        scheduleBackgroundRefresh: Bool = true
    ) {
        accuracyRetryTask?.cancel()
        if scheduleBackgroundRefresh {
            appRefreshScheduler.scheduleAccuracyRetry(at: episode.nextRetryAt)
        }
        let remaining = max(0, episode.nextRetryAt.timeIntervalSince(clock.now()))
        let delayMilliseconds = Int((remaining * 1_000).rounded(.up))
        let sleeper = accuracyRetrySleeper
        let episodeID = episode.id
        let dueEpochMs = episode.nextRetryEpochMs
        accuracyRetryTask = Task { [weak self] in
            await sleeper.sleep(milliseconds: delayMilliseconds)
            guard !Task.isCancelled else { return }
            await self?.accuracyRetryTaskFired(episodeID: episodeID, dueEpochMs: dueEpochMs)
        }
    }

    private func accuracyRetryTaskFired(episodeID: String, dueEpochMs: Int64) async {
        guard let episode = accuracyRetryEpisode,
              episode.id == episodeID,
              episode.nextRetryEpochMs == dueEpochMs else { return }
        accuracyRetryTask = nil
        if isRunning {
            pendingAccuracyRetry = true
            return
        }
        await runOnce(.accuracyRetry)
    }

    private func drainPendingAccuracyRetryIfNeeded() async {
        guard pendingAccuracyRetry else { return }
        pendingAccuracyRetry = false
        guard let episode = accuracyRetryEpisode else { return }
        if episode.nextRetryAt <= clock.now() {
            await runOnce(.accuracyRetry)
        } else if accuracyRetryTask == nil {
            // Outra avaliação pode ter renovado o ciclo antes de drenarmos o callback antigo.
            armAccuracyRetry(episode)
        }
    }

    private func drainPendingWorkIfNeeded() async {
        if pendingPauseTransition {
            pendingPauseTransition = false
            await runOnce(.pauseTransition)
            return
        }
        if pendingPauseActivation {
            pendingPauseActivation = false
            let phase = scheduledPauseDeferral?.phase
            if scheduledPauseDeferral?.activationAt != nil,
               (phase == .activationScheduled || phase == .awaitingCheckout) {
                await runOnce(.pauseActivation)
                return
            }
        }
        if pendingPauseReconciliation {
            await runOnce(.foreground)
            return
        }
        await drainPendingAccuracyRetryIfNeeded()
    }

    private func persistAccuracyRetryEpisode(_ episode: AccuracyRetryEpisode) async {
        guard let data = try? JSONCoding.encoder.encode(episode),
              let json = String(data: data, encoding: .utf8) else { return }
        await appPrefs.setAccuracyRetryEpisodeJson(json)
    }

    private func cancelAccuracyRetryEpisode(forceCleanup: Bool = false) async {
        guard forceCleanup || accuracyRetryEpisode != nil else { return }
        accuracyRetryTask?.cancel()
        accuracyRetryTask = nil
        pendingAccuracyRetry = false
        accuracyRetryEpisode = nil
        await appPrefs.setAccuracyRetryEpisodeJson("")
        appRefreshScheduler.clearAccuracyRetryDeadlineAndScheduleRegular()
        await notifications.clearLowAccuracyNotification()
    }

    private func discardStaleAccuracyRetryEpisode(id: String) async {
        // Uma geração nova já pode ter feito a limpeza. Se houver um episódio realmente diferente,
        // preserva-o; o single-flight impede essa situação no fluxo normal, mas a guarda evita dano futuro.
        if let current = accuracyRetryEpisode, current.id != id { return }
        accuracyRetryTask?.cancel()
        accuracyRetryTask = nil
        pendingAccuracyRetry = false
        accuracyRetryEpisode = nil
        await appPrefs.setAccuracyRetryEpisodeJson("")
        appRefreshScheduler.clearAccuracyRetryDeadlineAndScheduleRegular()
        await notifications.clearLowAccuracyNotification()
    }

    private func accuracyRetryContextIsEligible(chave: String, activeProject: String) async -> Bool {
        guard !chave.isEmpty, !activeProject.isEmpty,
              await appPrefs.chave() == chave else { return false }
        let settings = await loadUserSettings(chave)
        guard settings.automaticActivitiesEnabled,
              settings.activeProject == activeProject,
              settings.projects.contains(activeProject) else { return false }
        let pauseSettings = ScheduledPauseSettings(
            scheduledPauseEnabled: settings.scheduledPauseEnabled,
            scheduledPauseFrom: settings.scheduledPauseFrom,
            scheduledPauseTo: settings.scheduledPauseTo,
            suspendSaturdays: settings.suspendSaturdays,
            suspendSundays: settings.suspendSundays)
        let now = clock.now()
        let calendar = Calendar.current
        guard let window = currentScheduledPauseWindow(now, calendar, pauseSettings) else {
            return true
        }
        guard let runtime = scheduledPauseDeferral,
              scheduledPauseRuntime(
                  runtime,
                  matchesChave: chave,
                  activeProject: activeProject,
                  settings: pauseSettings,
                  window: window) else {
            return false
        }
        return runtime.phase == .awaitingCheckout
    }

    private func rawExpectedAction(_ action: CheckAction?) -> String? {
        switch action {
        case .checkIn: return "checkin"
        case .checkOut: return "checkout"
        case nil: return nil
        }
    }

    private func maybeNotifyAccident(_ chave: String, notifyAccident: Bool, lang: String) async {
        guard notifyAccident else { return }
        switch await accidentRepository.getState(chave) {
        case .success(let state):
            let activeIds = Set(state.activeAccidents.map(\.accidentId))
            let seen = await appPrefs.seenAccidentIds()
            if !activeIds.subtracting(seen).isEmpty { notifications.postAccidentNotification(lang: lang) }  // há id novo
            if activeIds != seen { await appPrefs.setSeenAccidentIds(activeIds) }                            // persiste se mudou
        case .failure(let error):
            if case .unauthorized = error { isSessionExpired = true }   // network NÃO seta
        }
    }

    private func getLocationOptions() async -> LocationOptions? {
        let now = clock.now()
        let cached = cachedOptions
        if let cached, now.timeIntervalSince(cachedOptionsAt) < Self.locationOptionsTTL { return cached }
        switch await checkRepository.getLocations() {
        case .success(let options): cachedOptions = options; cachedOptionsAt = now; return options
        case .failure(let error):
            if case .unauthorized = error { isSessionExpired = true }
            return offlineFallbackLocationOptions(cached, error)
        }
    }

    private func getRemoteState(_ chave: String) async -> HistoryState? {
        let now = clock.now()
        if chave == cacheChave, let cached = cachedState, now.timeIntervalSince(cachedStateAt) < Self.stateCacheTTL {
            return cached
        }
        switch await checkRepository.getState(chave) {
        case .success(let state): cachedState = state; cacheChave = chave; cachedStateAt = now; return state
        case .failure(let error):
            if case .unauthorized = error { isSessionExpired = true }
            return nil
        }
    }

    /// Gate da pausa nunca usa cache e preserva a diferença entre "GET bem-sucedido sem atividade"
    /// (um `HistoryState` cujo último ato é nil) e falha de transporte/autorização.
    private func getFreshRemoteState(_ chave: String) async -> FreshRemoteState {
        let now = clock.now()
        switch await checkRepository.getState(chave) {
        case .success(let state):
            cachedState = state
            cacheChave = chave
            cachedStateAt = now
            return .success(state)
        case .failure(let error):
            if case .unauthorized = error { isSessionExpired = true }
            return .failure(error)
        }
    }

    private func shouldSkip(_ accuracyThresholdMeters: Int) async -> SkipDecision {
        guard case .success(let lat, let lon, let accuracy) = await locationProvider.capture(accuracyThresholdMeters) else {
            return .noFix
        }
        lastCaptureAccuracyMeters = accuracy
        // Um fix acima do limite não prova ausência de movimento. Não contamina o baseline e nunca produz
        // SKIP; o match principal precisa enxergar a baixa precisão e abrir/manter o episódio de retry.
        guard accuracy.isFinite, accuracy >= 0, accuracy <= Double(accuracyThresholdMeters) else {
            return .run
        }
        let prevLat = lastLat; let prevLon = lastLon
        lastLat = lat; lastLon = lon
        guard let prevLat, let prevLon else { return .run }   // 1ª vez → RUN
        let distance = CLLocation(latitude: prevLat, longitude: prevLon).distance(from: CLLocation(latitude: lat, longitude: lon))
        let threshold = max(Self.skipThresholdMeters, 2.0 * accuracy)
        return distance < threshold ? .skip : .run
    }

    private func attemptSilentRelogin(_ chave: String, _ lang: String) async -> Bool {
        let password = securePasswordStore.getPassword(chave)
        if password.isEmpty {
            postReauthNotificationCoalesced(lang)
            activityLogger.logError("Re-authentication required.")
            return false
        }
        switch await authRepository.login(chave, password) {
        case .success:
            activityLogger.logAuth("Session refreshed.", .info)
            return true
        case .failure:
            postReauthNotificationCoalesced(lang)
            activityLogger.logError("Re-authentication required.")
            return false
        }
    }

    private func postReauthNotificationCoalesced(_ lang: String) {
        let now = clock.now()
        if now.timeIntervalSince(lastReauthNotificationAt) > Self.reauthNotificationCooldown {
            notifications.postReauthNotification(lang: lang)
            lastReauthNotificationAt = now
        }
    }

    private func submittedLocal(_ result: AutoActivitiesResult) -> String? {
        if case .submitted(_, let local, _) = result { return local }
        return nil
    }
    private func submittedActionName(_ result: AutoActivitiesResult) -> String? {
        if case .submitted(let action, _, _) = result { return action == .checkIn ? "CHECKIN" : "CHECKOUT" }
        return nil
    }
    private func outcome(of result: AutoActivitiesResult) -> EvaluationOutcome {
        switch result {
        case .submitted: return .submitted
        case .accuracyTooLow, .locationTimeout, .noPermission, .noAction, .notConfigured: return .noAction
        case .networkError: return .networkError
        }
    }
}
