import AVFoundation
import CoreLocation
import UIKit
import UserNotifications

/// Impl viva de `PermissionsInspecting` — lê o estado real do sistema. Integração, NÃO testada por unidade
/// (mesmo padrão de `CLLocationManagerLocationProvider`/`NWPathMonitor`). Port de `PermissionsInspector.kt`,
/// com as diferenças de plataforma da spec §3 (sem autostart de OEM; `batteryRestricted`→`lowPowerMode`).
struct PermissionsInspectorLive: PermissionsInspecting {

    func inspect() async -> PermissionsStatus {
        let notifAuth = await notificationAuthorization()
        // UIApplication/CLLocationManager exigem MainActor; agrupa todas as leituras síncronas num hop só.
        return await MainActor.run {
            let clm = CLLocationManager()
            return PermissionsStatus(
                locationAuthorization: Self.mapAuthorization(clm.authorizationStatus),
                preciseAccuracy: clm.accuracyAuthorization == .fullAccuracy,
                cameraMicGranted: AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                    && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                notificationAuthorization: notifAuth,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                backgroundRefresh: Self.mapBackgroundRefresh(UIApplication.shared.backgroundRefreshStatus))
        }
    }

    private func notificationAuthorization() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.mapNotificationAuthorization(settings.authorizationStatus)
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
