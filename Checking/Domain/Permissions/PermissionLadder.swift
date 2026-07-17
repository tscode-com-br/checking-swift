import Foundation

/// Passos da escada de permissões no iOS — port de `LadderStep` (PermissionLadder.kt). O Android tem 5
/// passos; **2 colapsam** no iOS e não são portados: `BATTERY_OPTIMIZATION` (não há isenção de Doze — Low
/// Power é read-only) e `OEM_GUIDANCE` (não há autostart de OEM). Ver port_spec_permissions_diagnostics §1.
enum LadderStep: Sendable, Equatable {
    case notifications        // UNUserNotificationCenter.requestAuthorization
    case preciseLocation      // When In Use + precisão total (fullAccuracy)
    case alwaysLocation       // "Always" (recomendado, não bloqueia)
}

/// Estado da escada — port de `PermissionLadderStatus` (só os 3 campos que sobrevivem no iOS; sem
/// `batteryOptExempt`/`oemGuidanceShown` e sem o alias depreciado `allRequiredGranted`). §2.
struct PermissionLadderStatus: Sendable, Equatable {
    let notificationsGranted: Bool
    let preciseLocationGranted: Bool     // When In Use + fullAccuracy
    let alwaysLocationGranted: Bool      // Always

    init(notificationsGranted: Bool, preciseLocationGranted: Bool, alwaysLocationGranted: Bool) {
        self.notificationsGranted = notificationsGranted
        self.preciseLocationGranted = preciseLocationGranted
        self.alwaysLocationGranted = alwaysLocationGranted
    }

    /// **D5** — mínimo para INICIAR/manter o motor: notificações + localização precisa. "Always" é
    /// RECOMENDADO (melhora a confiabilidade em background) mas NÃO bloqueia o início. Fiel ao Kotlin.
    var minimumToStartGranted: Bool { notificationsGranted && preciseLocationGranted }

    /// Todas as recomendadas concedidas → confiabilidade de background plena (os 3 passos do iOS).
    /// (No Kotlin inclui `batteryOptExempt`, que some no iOS.)
    var allRecommendedGranted: Bool {
        notificationsGranted && preciseLocationGranted && alwaysLocationGranted
    }

    /// Primeiro passo não satisfeito, em ordem — port de `nextStep` (sem os passos de bateria/OEM).
    /// A escada ainda GUIA o usuário por "Always" mesmo já podendo iniciar só com o mínimo.
    var nextStep: LadderStep? {
        if !notificationsGranted { return .notifications }
        if !preciseLocationGranted { return .preciseLocation }
        if !alwaysLocationGranted { return .alwaysLocation }
        return nil
    }
}
