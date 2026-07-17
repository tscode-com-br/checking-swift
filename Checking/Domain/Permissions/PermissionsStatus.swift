import Foundation

/// Precisa / imprecisa / negada — port de `LocationStatus` (PermissionsInspector.kt). No iOS mapeia
/// `accuracyAuthorization` (fullAccuracy/reducedAccuracy) combinado com a autorização. §3.
enum LocationStatus: Sendable, Equatable { case precise, imprecise, denied }

/// Autorização de localização do iOS — sem equivalente 1:1 no Android (que tem fine/coarse), mas necessária
/// para distinguir "Durante o Uso" de "Sempre" (o gate D5 e a degradação de background dependem disso).
enum LocationAuthorization: Sendable, Equatable {
    case notDetermined   // ainda não perguntado (distinto de negado — a UI pede; o painel mostra "pendente")
    case denied          // negado ou restrito
    case whenInUse       // "Durante o Uso"
    case always          // "Sempre"
}

/// Disponibilidade da Atualização em 2º Plano (`UIApplication.backgroundRefreshStatus`) — sem equivalente
/// Android; entra no painel de integridade (§4) e na degradação honesta de background.
enum BackgroundRefreshAvailability: Sendable, Equatable {
    case available
    case denied          // usuário desligou p/ o app
    case restricted      // restrição do sistema (controle parental etc.)
}

/// Autorização de notificações — enum (não `Bool`) pela MESMA razão da localização: distinguir "ainda não
/// perguntado" (resolvível por prompt in-app) de "negado" (no iOS só resolvível em Ajustes — `requestAuth`
/// devolve `granted:false` sem UI depois de negado). Sem isso o `needsOpenSettings` não roteia o estado
/// negado, deixando o usuário travado sem remédio.
enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized      // authorized/provisional/ephemeral
}

/// Snapshot vivo de permissões/serviços que o painel mostra — port de `PermissionsStatus`. Diferenças iOS:
/// **removido** `autoStartEnabled` (sem OEM autostart → não mostrar linha fantasma); `batteryRestricted`
/// (não-isento) vira **`lowPowerMode`** (só leitura, não há isenção a solicitar). §3.
struct PermissionsStatus: Sendable, Equatable {
    let locationAuthorization: LocationAuthorization
    let preciseAccuracy: Bool                       // accuracyAuthorization == .fullAccuracy
    let cameraMicGranted: Bool                       // AVCaptureDevice câmera + microfone
    let notificationAuthorization: NotificationAuthorization
    let lowPowerMode: Bool                           // ProcessInfo.isLowPowerModeEnabled (substitui batteryRestricted)
    let backgroundRefresh: BackgroundRefreshAvailability

    /// Concedidas = `authorized` (o campo que a escada/D5 consomem).
    var notificationsGranted: Bool { notificationAuthorization == .authorized }

    /// `precise`/`imprecise` só quando autorizado; negado/não-determinado → `denied` (fiel ao Android, que
    /// trata ausência de permissão como DENIED).
    var location: LocationStatus {
        switch locationAuthorization {
        case .whenInUse, .always: return preciseAccuracy ? .precise : .imprecise
        case .denied, .notDetermined: return .denied
        }
    }

    /// Localização precisa concedida = autorizado (When In Use ou Always) **e** precisão total.
    var preciseLocationGranted: Bool {
        (locationAuthorization == .whenInUse || locationAuthorization == .always) && preciseAccuracy
    }

    /// "Sempre" concedido — o "backgroundGranted" do Android.
    var alwaysLocationGranted: Bool { locationAuthorization == .always }

    /// Estado da escada derivado deste snapshot (fonte única de verdade).
    var ladder: PermissionLadderStatus {
        PermissionLadderStatus(
            notificationsGranted: notificationsGranted,
            preciseLocationGranted: preciseLocationGranted,
            alwaysLocationGranted: alwaysLocationGranted)
    }
}
