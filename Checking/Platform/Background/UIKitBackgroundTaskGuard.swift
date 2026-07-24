import UIKit

/// Solicita ao iOS alguns instantes para concluir uma avaliação já iniciada quando o app transita para
/// segundo plano. Não mantém o app vivo indefinidamente; apenas protege o fechamento do evento corrente.
final class UIKitBackgroundTaskGuard: BackgroundTaskGuard, @unchecked Sendable {
    func begin() async -> Int {
        await MainActor.run {
            UIApplication.shared.beginBackgroundTask(
                withName: "Checking automatic evaluation",
                expirationHandler: nil).rawValue
        }
    }

    func end(_ token: Int) {
        guard token != UIBackgroundTaskIdentifier.invalid.rawValue else { return }
        Task { @MainActor in
            UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
        }
    }
}
