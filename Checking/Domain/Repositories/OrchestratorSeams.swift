import Foundation

// Seams protocolares do orquestrador (port_spec_background §2). As IMPLEMENTAÇÕES concretas de auth/
// acidente/prefs/notificações/senha vêm nos slices delas; aqui só os contratos que o orquestrador consome.

// `AuthStatus` (domínio) vive em Domain/Models/AuthModels.swift.

/// Preferências do app (port de AppPreferencesDataSource — impl concreta no slice de persistência).
protocol AppPreferencesReading: Sendable {
    func chave() async -> String
    func language() async -> String
    func userSettingsJson() async -> String
    func seenAccidentIds() async -> Set<Int>
    func setSeenAccidentIds(_ ids: Set<Int>) async
    func getFlag(_ name: String) async -> Bool
    func setFlag(_ name: String, _ value: Bool) async
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
    func postActivityNotification(action: CheckAction, local: String?, lang: String)
    func postReauthNotification(lang: String)
    func postScheduledPauseTransition(started: Bool, lang: String)
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

/// Contrato do motor automático (permite fakear o use-case nos testes do orquestrador).
protocol RunningAutomaticActivities: Sendable {
    func callAsFunction(chave: String, userProjects: UserProjects?, currentState: HistoryState?,
                        mixedZoneIntervalMinutes: Int, accuracyThresholdMeters: Int) async -> AutoActivitiesResult
}
extension RunAutomaticActivitiesUseCase: RunningAutomaticActivities {}

func resolveEffectiveLanguageCode(_ stored: String) -> String {
    if !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let resolved = resolveLanguageCode(stored, fallback: "")
        if !resolved.isEmpty { return resolved }
    }
    return detectDeviceLanguageCode()
}
