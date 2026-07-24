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

/// Estado individual de uma forma de apresentação de notificações. Preserva `notSupported` em vez de
/// reduzi-lo a `false`, para que o diagnóstico reflita exatamente o snapshot devolvido pelo iOS.
enum NotificationSettingState: Sendable, Equatable {
    case enabled
    case disabled
    case notSupported
}

/// Subestado real das notificações no iOS. A autorização geral pode estar concedida enquanto banners,
/// tela bloqueada, Central de Notificações ou som estão desativados individualmente nos Ajustes.
struct NotificationDeliveryStatus: Sendable, Equatable {
    let alerts: NotificationSettingState
    let lockScreen: NotificationSettingState
    let notificationCenter: NotificationSettingState
    let badges: NotificationSettingState
    let sounds: NotificationSettingState
    let scheduledDelivery: NotificationSettingState

    /// Ao menos um destino visual está habilitado. Não tenta inferir o estilo global do iOS
    /// (Contagem/Pilha/Lista), que não é exposto aos aplicativos.
    var hasVisibleDestination: Bool {
        alerts == .enabled || lockScreen == .enabled || notificationCenter == .enabled
    }
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
    /// `nil` apenas em fakes/previews antigos; produção sempre recebe o snapshot do Notification Center.
    let notificationDelivery: NotificationDeliveryStatus?
    /// Serviço mestre de Localização do aparelho, separado da autorização concedida ao app.
    let locationServicesEnabled: Bool
    /// Registro do processo no APNs. Não é necessário para notificações locais de check-in/check-out.
    let remoteNotificationsRegistered: Bool

    init(
        locationAuthorization: LocationAuthorization,
        preciseAccuracy: Bool,
        cameraMicGranted: Bool,
        notificationAuthorization: NotificationAuthorization,
        lowPowerMode: Bool,
        backgroundRefresh: BackgroundRefreshAvailability,
        notificationDelivery: NotificationDeliveryStatus? = nil,
        locationServicesEnabled: Bool = true,
        remoteNotificationsRegistered: Bool = false
    ) {
        self.locationAuthorization = locationAuthorization
        self.preciseAccuracy = preciseAccuracy
        self.cameraMicGranted = cameraMicGranted
        self.notificationAuthorization = notificationAuthorization
        self.lowPowerMode = lowPowerMode
        self.backgroundRefresh = backgroundRefresh
        self.notificationDelivery = notificationDelivery
        self.locationServicesEnabled = locationServicesEnabled
        self.remoteNotificationsRegistered = remoteNotificationsRegistered
    }

    /// Concedidas = `authorized` (o campo que a escada/D5 consomem).
    var notificationsGranted: Bool { notificationAuthorization == .authorized }

    /// `precise`/`imprecise` só quando autorizado; negado/não-determinado → `denied` (fiel ao Android, que
    /// trata ausência de permissão como DENIED).
    var location: LocationStatus {
        guard locationServicesEnabled else { return .denied }
        switch locationAuthorization {
        case .whenInUse, .always: return preciseAccuracy ? .precise : .imprecise
        case .denied, .notDetermined: return .denied
        }
    }

    /// Localização precisa concedida = autorizado (When In Use ou Always) **e** precisão total.
    var preciseLocationGranted: Bool {
        locationServicesEnabled
            && (locationAuthorization == .whenInUse
            || locationAuthorization == .always) && preciseAccuracy
    }

    /// "Sempre" concedido — o "backgroundGranted" do Android.
    var alwaysLocationGranted: Bool {
        locationServicesEnabled && locationAuthorization == .always
    }

    /// Estado da escada derivado deste snapshot (fonte única de verdade).
    var ladder: PermissionLadderStatus {
        PermissionLadderStatus(
            notificationsGranted: notificationsGranted,
            preciseLocationGranted: preciseLocationGranted,
            alwaysLocationGranted: alwaysLocationGranted)
    }
}
