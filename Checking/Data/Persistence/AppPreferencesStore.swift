import Foundation

/// Store tipado de preferências — port de data/local/AppPreferencesDataSource.kt. Refina o seam de leitura
/// do orquestrador (`AppPreferencesReading`) + escrita. Chaves/defaults idênticos ao Android. §5.
protocol AppPreferencesStore: AppPreferencesReading {
    func setChave(_ chave: String) async
    func setLanguage(_ code: String) async
    func setUserSettingsJson(_ json: String) async
    func transportLocalJson() async -> String
    func setTransportLocalJson(_ json: String) async
    func pendingChecksJson() async -> String
    func setPendingChecksJson(_ json: String) async
    func backgroundLocationConsentAt() async -> String
    func setBackgroundLocationConsentAt(_ iso8601: String) async
    func clearAll() async
}

/// Implementação `UserDefaults`. Leitura ausente → default; escrita verbatim; último-write-vence.
final class UserDefaultsPreferencesStore: AppPreferencesStore, @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func string(_ key: String) -> String { defaults.string(forKey: key) ?? "" }

    func chave() async -> String { string("pref_chave") }
    func setChave(_ chave: String) async { defaults.set(chave, forKey: "pref_chave") }
    func language() async -> String { string("pref_language") }
    func setLanguage(_ code: String) async { defaults.set(code, forKey: "pref_language") }
    func userSettingsJson() async -> String { string("pref_user_settings_json") }
    func setUserSettingsJson(_ json: String) async { defaults.set(json, forKey: "pref_user_settings_json") }
    func transportLocalJson() async -> String { string("pref_transport_local_json") }
    func setTransportLocalJson(_ json: String) async { defaults.set(json, forKey: "pref_transport_local_json") }
    func pendingChecksJson() async -> String { string("pref_pending_checks_json") }
    func setPendingChecksJson(_ json: String) async { defaults.set(json, forKey: "pref_pending_checks_json") }
    func backgroundLocationConsentAt() async -> String { string("pref_bg_location_consent_at") }
    func setBackgroundLocationConsentAt(_ iso8601: String) async { defaults.set(iso8601, forKey: "pref_bg_location_consent_at") }

    func seenAccidentIds() async -> Set<Int> {
        Set(string("pref_seen_accident_ids").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }
    func setSeenAccidentIds(_ ids: Set<Int>) async {
        defaults.set(ids.map(String.init).joined(separator: ","), forKey: "pref_seen_accident_ids")
    }
    func getFlag(_ name: String) async -> Bool { defaults.bool(forKey: "pref_flag_\(name)") }
    func setFlag(_ name: String, _ value: Bool) async { defaults.set(value, forKey: "pref_flag_\(name)") }

    /// LGPD art. 18 — limpa TODAS as preferências do app (`pref_*`).
    func clearAll() async {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("pref_") {
            defaults.removeObject(forKey: key)
        }
    }
}
