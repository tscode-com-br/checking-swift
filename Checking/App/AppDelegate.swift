import UIKit
import BackgroundTasks
import UserNotifications

/// Ponte UIKit para APNs + registro de BackgroundTasks (os identificadores devem ser registrados
/// ANTES do fim do launch). Ver port_spec_background_orchestrator §9 (Camadas E/F) e
/// port_spec_permissions_diagnostics §7.
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// Devem casar com `BGTaskSchedulerPermittedIdentifiers` no Info.plist.
    static let refreshTaskID = "br.com.tscode.checking.refresh"
    static let processingTaskID = BGTaskSyncScheduler.taskIdentifier   // "…​.processing"
    /// `TIMER_INTERVAL_MS=15min` do FGS Android (port_spec_background_orchestrator §11) — preferência de
    /// `earliestBeginDate`; o iOS NÃO garante essa cadência (best-effort, §9 "Sem tick garantido").
    static let refreshIntervalSeconds: TimeInterval = 15 * 60

    /// Raiz de composição do app (dona única). O `RootView` a lê via `appDelegate.environment`.
    let environment = AppEnvironment.live()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        registerBackgroundTasks()
        Self.scheduleAppRefresh()   // 1ª submissão — sem isso o handler registrado acima nunca é chamado pelo iOS
        Task { await environment.offlineSyncCoordinator.start() }   // observa reconexão (NWPathMonitor) → drena
        AppLog.lifecycle.info("App started.") // espelha CheckingApp.onCreate → logSystem("App started.")
        return true
    }

    // `register(forTaskWithIdentifier:)` só instala o handler — não agenda nada sozinho. Precisa de um
    // `submit` (aqui + no fim de cada execução, conversion_plan.md §9.6 "reagendar no início ou final").
    // `static`: não usa estado de instância — evita capturar `self` (não-Sendable) dentro do `Task` fire-and-forget.
    private static func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshIntervalSeconds)
        try? BGTaskScheduler.shared.submit(request)   // falha se não registrado/permitido — best-effort (§9)
    }

    private func registerBackgroundTasks() {
        // Reconciliação curta oportunista — equivalente ao timer 15min do FGS Android (§9, "Sem tick garantido").
        let orchestrator = environment.orchestrator
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            nonisolated(unsafe) let bgTask = task     // BGTask não é Sendable; usado serialmente aqui
            let work = Task {
                await orchestrator.runOnce(.timer)
                Self.scheduleAppRefresh()   // reagenda no fim da execução — sem isso só dispara 1×
                bgTask.setTaskCompleted(success: true)
            }
            bgTask.expirationHandler = { work.cancel() }
        }
        // Replay da fila offline (port de SyncPendingChecksWorker) — dispara o drain do coordenador.
        let coordinator = environment.offlineSyncCoordinator
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTaskID, using: nil) { task in
            nonisolated(unsafe) let bgTask = task     // BGTask não é Sendable; usado serialmente aqui
            let work = Task {
                await coordinator.triggerDrain()
                bgTask.setTaskCompleted(success: true)
            }
            bgTask.expirationHandler = { work.cancel() }
        }
    }

    // MARK: APNs (port_spec_background_orchestrator §F / port_spec_accident_video §10)

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // TODO: enviar o device token ao backend por usuário/instalação/ambiente.
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppLog.background.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Apresentação em foreground deliberada (port_spec_permissions_diagnostics §6).
        [.banner, .list, .sound]
    }
}
