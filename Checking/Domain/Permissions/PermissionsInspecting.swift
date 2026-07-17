import Foundation

/// Seam de leitura do estado vivo de permissões — port de `PermissionsInspector.inspect`. Impl viva é
/// `PermissionsInspectorLive` (integração CoreLocation/UNUserNotificationCenter/AVFoundation/UIApplication,
/// não testada por unidade); a lógica que a consome (escada, `HealthReport`) é testada com um snapshot fake.
protocol PermissionsInspecting: Sendable {
    func inspect() async -> PermissionsStatus
}

/// Abre a página de Ajustes do app — port dos `launch*Settings` do Android, colapsados num só destino: o
/// iOS **não** deep-linka por permissão (`UIApplication.openSettingsURLString` só abre a página do app). §2.
protocol SettingsOpening: Sendable {
    func openAppSettings()
}
