import Foundation

/// Settings persistidas por chave — port de domain/clientstate/PersistedSettings.kt (`UserSettings`).
/// Campos obrigatórios: projects/activeProject/automaticActivitiesEnabled; o resto tem default.
struct UserSettings: Codable, Sendable, Equatable {
    var projects: [String]
    var activeProject: String
    var automaticActivitiesEnabled: Bool
    var scheduledPauseEnabled: Bool
    var scheduledPauseFrom: String
    var scheduledPauseTo: String
    var suspendSaturdays: Bool
    var suspendSundays: Bool
    var notifyActivities: Bool
    var notifyScheduledPause: Bool
    var notifyAccident: Bool

    init(projects: [String], activeProject: String, automaticActivitiesEnabled: Bool,
         scheduledPauseEnabled: Bool = true, scheduledPauseFrom: String = "20:00", scheduledPauseTo: String = "07:00",
         suspendSaturdays: Bool = true, suspendSundays: Bool = true,
         notifyActivities: Bool = true, notifyScheduledPause: Bool = true, notifyAccident: Bool = true) {
        self.projects = projects; self.activeProject = activeProject; self.automaticActivitiesEnabled = automaticActivitiesEnabled
        self.scheduledPauseEnabled = scheduledPauseEnabled; self.scheduledPauseFrom = scheduledPauseFrom
        self.scheduledPauseTo = scheduledPauseTo; self.suspendSaturdays = suspendSaturdays; self.suspendSundays = suspendSundays
        self.notifyActivities = notifyActivities; self.notifyScheduledPause = notifyScheduledPause; self.notifyAccident = notifyAccident
    }

    // Decode tolerante: opcionais ausentes caem nos MESMOS defaults do data class Kotlin.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decode([String].self, forKey: .projects)
        activeProject = try c.decode(String.self, forKey: .activeProject)
        automaticActivitiesEnabled = try c.decode(Bool.self, forKey: .automaticActivitiesEnabled)
        scheduledPauseEnabled = try c.decodeIfPresent(Bool.self, forKey: .scheduledPauseEnabled) ?? true
        scheduledPauseFrom = try c.decodeIfPresent(String.self, forKey: .scheduledPauseFrom) ?? "20:00"
        scheduledPauseTo = try c.decodeIfPresent(String.self, forKey: .scheduledPauseTo) ?? "07:00"
        suspendSaturdays = try c.decodeIfPresent(Bool.self, forKey: .suspendSaturdays) ?? true
        suspendSundays = try c.decodeIfPresent(Bool.self, forKey: .suspendSundays) ?? true
        notifyActivities = try c.decodeIfPresent(Bool.self, forKey: .notifyActivities) ?? true
        notifyScheduledPause = try c.decodeIfPresent(Bool.self, forKey: .notifyScheduledPause) ?? true
        notifyAccident = try c.decodeIfPresent(Bool.self, forKey: .notifyAccident) ?? true
    }
}

/// Defaults injetáveis — port de `UserSettingsDefaults`.
struct UserSettingsDefaults: Sendable {
    var allowedProjects: [String] = []
    var projects: [String] = []
    var project: String = ""
    var activeProject: String = ""
    var automaticActivitiesEnabled: Bool = false
}

/// Projetos-fallback dos defaults — port de `resolveFallbackProjects`. `defaults.projects` (ou, se vazio,
/// `defaults.project` singular) normalizado e FILTRADO contra `defaults.allowedProjects`; se o filtro
/// esvaziar, cai para `allowedProjects` normalizado (sem filtro); se esse também for vazio, para o raw normalizado.
func resolveFallbackProjects(_ defaults: UserSettingsDefaults) -> [String] {
    let allowed = defaults.allowedProjects.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty }
    let rawDefaults = !defaults.projects.isEmpty ? defaults.projects : (!defaults.project.isEmpty ? [defaults.project] : [])
    var seen = Set<String>()
    let normalized = rawDefaults.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        .filter { !$0.isEmpty && seen.insert($0).inserted }   // distinct, preserva ordem
    let filtered = normalized.filter { allowed.contains($0) }

    if !filtered.isEmpty { return filtered }
    if !allowed.isEmpty { return allowed }
    return normalized
}

/// Primeiro projeto-fallback — port de `resolveFallbackProject`.
func resolveFallbackProject(_ defaults: UserSettingsDefaults) -> String {
    resolveFallbackProjects(defaults).first ?? ""
}

/// Projeto ativo-fallback — port de `resolveFallbackActiveProject`. `defaults.activeProject` (ou, se vazio,
/// `defaults.project`) normalizado; válido se está em `fallbackProjects`, senão o primeiro de `fallbackProjects`.
func resolveFallbackActiveProject(_ defaults: UserSettingsDefaults, _ fallbackProjects: [String]) -> String {
    let normalized = fallbackProjects.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty }
    let rawSource = !defaults.activeProject.isEmpty ? defaults.activeProject : defaults.project
    let rawDefault = rawSource.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if !rawDefault.isEmpty && normalized.contains(rawDefault) { return rawDefault }
    return normalized.first ?? rawDefault
}

/// Resolve o `UserSettings` de uma chave a partir do mapa persistido, tolerante a ausência/erro — port 1:1 de
/// `resolvePersistedUserSettings`.
func resolvePersistedUserSettings(_ settingsByChave: [String: UserSettings]?, _ chave: String,
                                  defaults: UserSettingsDefaults = UserSettingsDefaults()) -> UserSettings {
    let normalizedChave = sanitizeSettingsChave(chave)
    let fallbackProjects = resolveFallbackProjects(defaults)
    let fallbackActive = resolveFallbackActiveProject(defaults, fallbackProjects)

    guard normalizedChave.count == 4, let record = settingsByChave?[normalizedChave] else {
        return UserSettings(projects: fallbackProjects, activeProject: fallbackActive,
                            automaticActivitiesEnabled: defaults.automaticActivitiesEnabled)
    }
    let chosen = !record.projects.isEmpty ? record.projects
        : (!record.activeProject.isEmpty ? [record.activeProject] : [])
    let resolvedProjects = normalizeProjectValues(chosen, defaults.allowedProjects, fallbackProjects)
    let resolvedActive = normalizeProjectValue(record.activeProject, resolvedProjects, resolveFallbackActiveProject(defaults, resolvedProjects))
    return UserSettings(
        projects: resolvedProjects, activeProject: resolvedActive,
        automaticActivitiesEnabled: record.automaticActivitiesEnabled,
        scheduledPauseEnabled: record.scheduledPauseEnabled, scheduledPauseFrom: record.scheduledPauseFrom,
        scheduledPauseTo: record.scheduledPauseTo, suspendSaturdays: record.suspendSaturdays,
        suspendSundays: record.suspendSundays, notifyActivities: record.notifyActivities,
        notifyScheduledPause: record.notifyScheduledPause, notifyAccident: record.notifyAccident)
}
