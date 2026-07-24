import AVFoundation
import CoreLocation
import UIKit
import UserNotifications

/// Impl viva de `PermissionsInspecting` — lê o estado real do sistema. Integração, NÃO testada por unidade
/// (mesmo padrão de `CLLocationManagerLocationProvider`/`NWPathMonitor`). Port de `PermissionsInspector.kt`,
/// com as diferenças de plataforma da spec §3 (sem autostart de OEM; `batteryRestricted`→`lowPowerMode`).
struct PermissionsInspectorLive: PermissionsInspecting {
    func inspect() async -> PermissionsStatus {
        let notifications = await notificationStatus()
        // A própria Core Location alerta que esta consulta pode bloquear a UI; executa fora da MainActor.
        let locationServicesEnabled = await Task.detached(priority: .userInitiated) {
            CLLocationManager.locationServicesEnabled()
        }.value
        // UIApplication/CLLocationManager exigem MainActor; agrupa todas as leituras síncronas num hop só.
        return await MainActor.run {
            let clm = CLLocationManager()
            return PermissionsStatus(
                // `authorizationStatus` é a fonte pública do Core Location. O fluxo do Checking evita
                // criar um Always provisório pedindo sempre em duas etapas; portanto não devemos
                // rebaixar um `authorizedAlways` oficial usando um marcador local que pode não existir
                // em instalações atualizadas de builds anteriores.
                locationAuthorization: Self.mapAuthorization(clm.authorizationStatus),
                preciseAccuracy: clm.accuracyAuthorization == .fullAccuracy,
                cameraMicGranted: AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                    && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                notificationAuthorization: notifications.authorization,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                backgroundRefresh: Self.mapBackgroundRefresh(UIApplication.shared.backgroundRefreshStatus),
                notificationDelivery: notifications.delivery,
                locationServicesEnabled: locationServicesEnabled,
                remoteNotificationsRegistered: UIApplication.shared.isRegisteredForRemoteNotifications)
        }
    }

    private func notificationStatus() async -> (
        authorization: NotificationAuthorization,
        delivery: NotificationDeliveryStatus
    ) {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return (
            Self.mapNotificationAuthorization(settings.authorizationStatus),
            NotificationDeliveryStatus(
                alerts: Self.mapNotificationSetting(settings.alertSetting),
                lockScreen: Self.mapNotificationSetting(settings.lockScreenSetting),
                notificationCenter: Self.mapNotificationSetting(settings.notificationCenterSetting),
                badges: Self.mapNotificationSetting(settings.badgeSetting),
                sounds: Self.mapNotificationSetting(settings.soundSetting),
                scheduledDelivery: Self.mapNotificationSetting(settings.scheduledDeliverySetting))
        )
    }

    static func mapNotificationAuthorization(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    static func mapAuthorization(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .authorizedAlways: return .always
        case .authorizedWhenInUse: return .whenInUse
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    static func mapBackgroundRefresh(_ status: UIBackgroundRefreshStatus) -> BackgroundRefreshAvailability {
        switch status {
        case .available: return .available
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    static func mapNotificationSetting(_ setting: UNNotificationSetting) -> NotificationSettingState {
        switch setting {
        case .enabled: return .enabled
        case .disabled: return .disabled
        case .notSupported: return .notSupported
        @unknown default: return .notSupported
        }
    }
}

/// Abre a página de Ajustes do app (`openSettingsURLString`) — o único destino que o iOS oferece.
struct UIKitSettingsOpener: SettingsOpening {
    func openAppSettings() {
        Task { @MainActor in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }
}

/// Sequenciador retido pela tela para pedir as permissões no contexto correto. O mesmo manager precisa
/// permanecer vivo durante os prompts de Core Location; por isso esta peça é uma classe `@MainActor`.
@MainActor
final class PermissionRequestCoordinator: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    var onAuthorizationChange: (() -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) == true
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    func requestWhenInUseLocation() {
        locationManager.requestWhenInUseAuthorization()
    }

    func requestAlwaysLocation() {
        // Nunca pedir Always a partir de `notDetermined`: o iOS concederia um Always
        // provisório e reportaria `authorizedAlways`, embora Ajustes mostrasse "Durante o Uso".
        // O fluxo correto é deliberadamente em duas etapas.
        guard locationManager.authorizationStatus == .authorizedWhenInUse else {
            onAuthorizationChange?()
            return
        }
        // A solicitação vem do botão de um alert SwiftUI. Esperar seu dismiss evita que o
        // prompt do sistema seja descartado por tentar apresentar duas folhas simultaneamente.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, self.locationManager.authorizationStatus == .authorizedWhenInUse else { return }
            self.locationManager.requestAlwaysAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.onAuthorizationChange?()
        }
    }
}
