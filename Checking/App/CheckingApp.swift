import SwiftUI

/// Ponto de entrada do app (single-window, SwiftUI lifecycle). Espelha `CheckingApp`/`MainActivity`.
/// A raiz de composição vive no `AppDelegate` (dono único), lida aqui via `appDelegate.environment`.
@main
struct CheckingApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.appEnvironment, appDelegate.environment)
        }
        .onChange(of: scenePhase) { _, phase in
#if DEBUG
            if BackgroundValidationHarness.isEnabled {
                let phaseLabel: String
                switch phase {
                case .active: phaseLabel = "active"
                case .inactive: phaseLabel = "inactive"
                case .background: phaseLabel = "background"
                @unknown default: phaseLabel = "future"
                }
                Task {
                    await BackgroundValidationRecorder.shared.record(
                        "scene_phase_\(phaseLabel)",
                        details: ["scenePhase": phaseLabel]
                    )
                }
            }
#endif
            guard phase == .active else { return }
            // Restauração no foreground (Camada D — a garantia mais forte do iOS): drena a fila offline.
            let coordinator = appDelegate.environment.offlineSyncCoordinator
            Task { await coordinator.triggerDrain() }
        }
    }
}
