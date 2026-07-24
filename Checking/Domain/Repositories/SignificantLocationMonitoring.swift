import Foundation

/// Seam do fallback de movimento amplo do iOS (plano §9.3). A implementação viva usa
/// `startMonitoringSignificantLocationChanges`; o evento apenas acorda o orquestrador, que continua sendo
/// a fonte única para gates, captura precisa, matching e matriz de atividades.
protocol SignificantLocationMonitoring: Sendable {
    func start() async
    func stop() async
    func isActive() async -> Bool
}

struct NoopSignificantLocationMonitor: SignificantLocationMonitoring {
    func start() async {}
    func stop() async {}
    func isActive() async -> Bool { false }
}

/// Política pura para restauração precoce após morte do processo. O serviço só volta a ser armado quando
/// há conta válida, consentimento explícito e automático habilitado com projeto ativo.
enum SignificantLocationStartupPolicy {
    static func shouldStart(chave: String, userSettingsJSON: String, consentAt: String) -> Bool {
        let normalizedChave = sanitizeSettingsChave(chave)
        guard normalizedChave.count == 4, !consentAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard let data = userSettingsJSON.data(using: .utf8),
              let map = try? JSONCoding.decoder.decode([String: UserSettings].self, from: data) else {
            return false
        }
        let settings = resolvePersistedUserSettings(map, normalizedChave)
        return settings.automaticActivitiesEnabled && !settings.activeProject.isEmpty
    }
}
