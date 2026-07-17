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
    static let flagPauseActive = "scheduled_pause_active"

    private enum SkipDecision { case run, skip, noFix }

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

    var isRunningForTest: Bool { isRunning }

    init(appPrefs: any AppPreferencesReading, checkRepository: any CheckRepository,
         runAutomaticActivities: any RunningAutomaticActivities, locationProvider: any LocationProvider,
         clock: any Clock, authRepository: any AuthRepositoring, securePasswordStore: any SecurePasswordReading,
         accidentRepository: any AccidentStateReading, activityLogger: any ActivityLogging,
         notifications: any AutoActivityNotifying, backgroundTaskGuard: any BackgroundTaskGuard = NoopBackgroundTaskGuard(),
         pauseAlarms: any PauseAlarmScheduling = NoopPauseAlarmScheduling()) {
        self.appPrefs = appPrefs; self.checkRepository = checkRepository; self.runAutomaticActivities = runAutomaticActivities
        self.locationProvider = locationProvider; self.clock = clock; self.authRepository = authRepository
        self.securePasswordStore = securePasswordStore; self.accidentRepository = accidentRepository
        self.activityLogger = activityLogger; self.notifications = notifications
        self.backgroundTaskGuard = backgroundTaskGuard; self.pauseAlarms = pauseAlarms
    }

    // MARK: - Entrada (single-flight)

    func runOnce(_ trigger: OrchestratorTrigger) async {
        if isRunning { return }                        // prólogo síncrono (atômico até o 1º await): 2ª chamada CAI FORA
        isRunning = true
        let token = backgroundTaskGuard.begin()
        defer { backgroundTaskGuard.end(token); isRunning = false }
        isSessionExpired = false
        await runOnceLocked(trigger)
        if isSessionExpired {                          // relogin silencioso + retry once
            let chave = await appPrefs.chave()
            guard !chave.isEmpty else { return }
            let lang = resolveEffectiveLanguageCode(await appPrefs.language())
            if await attemptSilentRelogin(chave, lang) {
                isSessionExpired = false
                await runOnceLocked(trigger)
            }
        }
    }

    /// Acidente em background, independente do auto (§8/§10). Mesmo single-flight que `runOnce`.
    func runAccidentCheck() async {
        if isRunning { return }
        isRunning = true
        defer { isRunning = false }
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

    private func runOnceLocked(_ trigger: OrchestratorTrigger) async {
        // 1 — Auth
        let chave = await appPrefs.chave()
        guard !chave.isEmpty else { return }
        let lang = resolveEffectiveLanguageCode(await appPrefs.language())
        activityLogger.logTrigger(trigger.name)

        // 2 — Settings, acidente ANTES do gate, toggle, pausa
        let userSettings = await loadUserSettings(chave)
        await maybeNotifyAccident(chave, notifyAccident: userSettings.notifyAccident, lang: lang)

        if !userSettings.automaticActivitiesEnabled {
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
        let wasPaused = await appPrefs.getFlag(Self.flagPauseActive)   // flag PERSISTIDA
        if isScheduledPauseActiveNow(now, calendar, pauseSettings) {
            if !wasPaused {
                if userSettings.notifyScheduledPause { notifications.postScheduledPauseTransition(started: true, lang: lang) }
                await appPrefs.setFlag(Self.flagPauseActive, true)
                activityLogger.logInactive("Scheduled pause started.")
            }
            if let resume = nextResumeInstant(now, calendar, pauseSettings) { pauseAlarms.scheduleResume(at: resume) }
            EvaluationLog.shared.record(EvaluationEntry(at: clock.now(), trigger: trigger, accuracyMeters: nil,
                                                        resolvedLocal: nil, decidedAction: nil, outcome: .paused))
            return
        }
        if wasPaused {
            if userSettings.notifyScheduledPause { notifications.postScheduledPauseTransition(started: false, lang: lang) }
            await appPrefs.setFlag(Self.flagPauseActive, false)
            activityLogger.logActive("Scheduled pause ended.")
        }
        pauseAlarms.scheduleStart(at: nextPauseStartInstant(now, calendar, pauseSettings))

        // 3 — Opções (TTL 15min + fallback offline)
        guard let options = await getLocationOptions() else { return }

        // 4 — Skip-if-unchanged (só TIMER)
        // NB (fiel ao Kotlin): `lastCaptureAccuracyMeters` só é resetado aqui, no bloco TIMER. Uma run
        // .geofence/.foreground registra o valor da última run TIMER (ou nil) — mesmo comportamento do Android.
        if trigger == .timer {
            lastCaptureAccuracyMeters = nil
            if await shouldSkip(options.accuracyThresholdMeters) == .skip {
                EvaluationLog.shared.record(EvaluationEntry(at: clock.now(), trigger: trigger, accuracyMeters: lastCaptureAccuracyMeters,
                                                            resolvedLocal: nil, decidedAction: nil, outcome: .skip))
                activityLogger.logSystem("Auto-check skipped (no movement).", .info)
                return
            }
        }

        // 5–6 — Estado, projetos, motor, cache
        let currentState = await getRemoteState(chave)
        let userProjects = UserProjects(projects: userSettings.projects, activeProject: userSettings.activeProject)
        let result = await runAutomaticActivities(chave: chave, userProjects: userProjects, currentState: currentState,
                                                  mixedZoneIntervalMinutes: options.mixedZoneIntervalMinutes,
                                                  accuracyThresholdMeters: options.accuracyThresholdMeters)
        if case .submitted(_, _, let newState) = result {
            cachedState = newState; cacheChave = chave; cachedStateAt = clock.now()
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

    private func shouldSkip(_ accuracyThresholdMeters: Int) async -> SkipDecision {
        guard case .success(let lat, let lon, let accuracy) = await locationProvider.capture(accuracyThresholdMeters) else {
            return .noFix
        }
        lastCaptureAccuracyMeters = accuracy
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
        case .noAction, .notConfigured: return .noAction
        case .networkError: return .networkError
        }
    }
}
