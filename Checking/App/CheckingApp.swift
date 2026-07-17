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
            guard phase == .active else { return }
            // Restauração no foreground (Camada D — a garantia mais forte do iOS): drena a fila offline.
            let coordinator = appDelegate.environment.offlineSyncCoordinator
            Task { await coordinator.triggerDrain() }
        }
    }
}
