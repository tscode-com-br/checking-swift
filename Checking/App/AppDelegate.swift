import UIKit
import BackgroundTasks
import UserNotifications

/// Ponte UIKit para APNs + registro de BackgroundTasks (os identificadores devem ser registrados
/// ANTES do fim do launch). Ver port_spec_background_orchestrator §9 (Camadas E/F) e
/// port_spec_permissions_diagnostics §7.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {

    nonisolated static let accidentNotificationCategory = "CHECKING_ACCIDENT"
    nonisolated static let openAccidentAction = "OPEN_CHECKING_ACCIDENT"

#if DEBUG
    private let backgroundValidationHarness = BackgroundValidationHarness.shared
#endif

    /// Devem casar com `BGTaskSchedulerPermittedIdentifiers` no Info.plist.
    static let refreshTaskID = "br.com.tscode.checking.refresh"
    static let processingTaskID = BGTaskSyncScheduler.taskIdentifier   // "…​.processing"
    /// `TIMER_INTERVAL_MS=15min` do FGS Android (port_spec_background_orchestrator §11) — preferência de
    /// `earliestBeginDate`; o iOS NÃO garante essa cadência (best-effort, §9 "Sem tick garantido").
    static let refreshIntervalSeconds: TimeInterval = 15 * 60
    private var pendingAccidentNotificationOpen = false
    private var accidentNotificationRouteTask: Task<Void, Never>?

    /// Raiz de composição do app (dona única). O `RootView` a lê via `appDelegate.environment`.
    let environment = AppEnvironment.live()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
#if DEBUG
        _ = BackgroundValidationHarness.configure()
#endif
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()
        // Uma instalação atualizada pode já ter autorização e nunca voltar a passar pelo botão que
        // chama `requestAuthorization`. Revalida o registro APNs a cada inicialização sem exibir prompt.
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if status == .authorized || status == .provisional || status == .ephemeral {
                application.registerForRemoteNotifications()
            }
        }
        let backgroundTaskRegistrations = registerBackgroundTasks()
        let refreshSubmissionError = Self.scheduleAppRefresh()
        // 1ª submissão — sem isso o handler registrado acima nunca é chamado pelo iOS.
        Task { await environment.offlineSyncCoordinator.start() }   // observa reconexão (NWPathMonitor) → drena
        AppLog.lifecycle.info("App started.") // espelha CheckingApp.onCreate → logSystem("App started.")
#if DEBUG
        if BackgroundValidationHarness.isEnabled {
            let resetReport = ProcessInfo.processInfo.arguments.contains(BackgroundValidationHarness.enableArgument)
            let launchedForLocation = launchOptions?[.location] != nil
            Task { @MainActor in
                await backgroundValidationHarness.start(
                    resetReport: resetReport,
                    includeSyntheticRegion: BackgroundValidationHarness.includesSyntheticRegion,
                    useContinuousLocation: BackgroundValidationHarness.usesContinuousLocation
                )
                await BackgroundValidationRecorder.shared.record(
                    "application_launched",
                    details: ["locationLaunch": String(launchedForLocation)]
                )
                await BackgroundValidationRecorder.shared.record(
                    "bg_task_registration",
                    details: [
                        "refresh": String(backgroundTaskRegistrations.refresh),
                        "processing": String(backgroundTaskRegistrations.processing),
                        "refreshSubmissionError": refreshSubmissionError ?? "none"
                    ]
                )
                let requests = await BGTaskScheduler.shared.pendingTaskRequests()
                let identifiers = requests.map(\.identifier).sorted().joined(separator: ",")
                await BackgroundValidationRecorder.shared.record(
                    "bg_task_pending_requests",
                    details: ["identifiers": identifiers]
                )
            }
        }
#endif
        return true
    }

    private func registerNotificationCategories() {
        let open = UNNotificationAction(
            identifier: Self.openAccidentAction,
            title: "Abrir Checking",
            options: [.foreground])
        let category = UNNotificationCategory(
            identifier: Self.accidentNotificationCategory,
            actions: [open],
            intentIdentifiers: [],
            options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        deliverPendingAccidentNotificationWhenUIIsStable()
#if DEBUG
        if BackgroundValidationHarness.isEnabled {
            backgroundValidationHarness.recordLifecycle("application_did_become_active")
        }
#endif
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
#if DEBUG
        if BackgroundValidationHarness.isEnabled {
            backgroundValidationHarness.recordLifecycle("application_did_enter_background")
        }
#endif
    }

    // `register(forTaskWithIdentifier:)` só instala o handler — não agenda nada sozinho. Precisa de um
    // `submit` (aqui + no fim de cada execução, conversion_plan.md §9.6 "reagendar no início ou final").
    // `static`: não usa estado de instância — evita capturar `self` (não-Sendable) dentro do `Task` fire-and-forget.
    @discardableResult
    private static func scheduleAppRefresh() -> String? {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshIntervalSeconds)
        do {
            try BGTaskScheduler.shared.submit(request)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private func registerBackgroundTasks() -> (refresh: Bool, processing: Bool) {
        // Reconciliação curta oportunista — equivalente ao timer 15min do FGS Android (§9, "Sem tick garantido").
        let orchestrator = environment.orchestrator
        let refreshRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskID,
            // `AppDelegate` e este handler são isolados na MainActor. Se o sistema escolher sua fila
            // privada (`using: nil`), Swift 6 encerra o processo em `_dispatch_assert_queue_fail` antes
            // mesmo do primeiro `Task`. A fila explícita torna o contrato do callback compatível.
            using: .main
        ) { task in
            nonisolated(unsafe) let bgTask = task     // BGTask não é Sendable; usado serialmente aqui
            let work = Task {
#if DEBUG
                if UserDefaults.standard.bool(forKey: "debug.background_validation.enabled") {
                    await BackgroundValidationRecorder.shared.record("bg_app_refresh_started")
                }
#endif
                await orchestrator.runOnce(.timer)
                Self.scheduleAppRefresh()   // reagenda no fim da execução — sem isso só dispara 1×
#if DEBUG
                if UserDefaults.standard.bool(forKey: "debug.background_validation.enabled") {
                    await BackgroundValidationRecorder.shared.record("bg_app_refresh_completed")
                }
#endif
                bgTask.setTaskCompleted(success: true)
            }
            bgTask.expirationHandler = { work.cancel() }
        }
        // Replay da fila offline (port de SyncPendingChecksWorker) — dispara o drain do coordenador.
        let coordinator = environment.offlineSyncCoordinator
        let processingRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskID,
            using: .main
        ) { task in
            nonisolated(unsafe) let bgTask = task     // BGTask não é Sendable; usado serialmente aqui
            let work = Task {
#if DEBUG
                if UserDefaults.standard.bool(forKey: "debug.background_validation.enabled") {
                    await BackgroundValidationRecorder.shared.record("bg_processing_started")
                }
#endif
                await coordinator.triggerDrain()
#if DEBUG
                if UserDefaults.standard.bool(forKey: "debug.background_validation.enabled") {
                    await BackgroundValidationRecorder.shared.record("bg_processing_completed")
                }
#endif
                bgTask.setTaskCompleted(success: true)
            }
            bgTask.expirationHandler = { work.cancel() }
        }
        return (refreshRegistered, processingRegistered)
    }

    // MARK: APNs (port_spec_background_orchestrator §F / port_spec_accident_video §10)

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
#if DEBUG
        if BackgroundValidationHarness.isEnabled {
            Task {
                await BackgroundValidationRecorder.shared.record(
                    "apns_device_token_received",
                    details: ["byteCount": String(deviceToken.count)]
                )
            }
        }
#endif
        // TODO: enviar o device token ao backend por usuário/instalação/ambiente.
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppLog.background.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
#if DEBUG
        if BackgroundValidationHarness.isEnabled {
            let validationValue = userInfo["checking_validation"] as? String ?? "absent"
            Task {
                await BackgroundValidationRecorder.shared.record(
                    "remote_notification_received",
                    details: ["checkingValidation": validationValue]
                )
                completionHandler(.newData)
            }
            return
        }
#endif
        guard Self.isAccidentPayload(userInfo) else {
            completionHandler(.noData)
            return
        }
        Task {
            await environment.orchestrator.runAccidentCheck()
            completionHandler(.newData)
        }
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard let uploader = environment.accidentVideoUploader,
              uploader.handlesSession(identifier: identifier)
        else {
            completionHandler()
            return
        }
        uploader.attachBackgroundEventsCompletion(completionHandler)
    }

    nonisolated static func isAccidentPayload(_ userInfo: [AnyHashable: Any]) -> Bool {
        let directValues = [userInfo["checking_event"], userInfo["event"], userInfo["type"]]
            .compactMap { $0 as? String }
        if directValues.contains(where: { $0.localizedCaseInsensitiveContains("accident") }) { return true }
        guard let aps = userInfo["aps"] as? [String: Any] else { return false }
        return (aps["category"] as? String) == accidentNotificationCategory
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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        guard response.actionIdentifier == Self.openAccidentAction
                || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              content.categoryIdentifier == Self.accidentNotificationCategory
                || Self.isAccidentPayload(content.userInfo)
        else { return }
        // Não alterar a árvore SwiftUI dentro do callback de resposta. Em iOS 26 esse callback pode
        // coincidir com a captura/restauração do snapshot da cena; o build 25 abortou em
        // `_updateStateRestorationArchiveForBackgroundEvent`. Enfileiramos a intenção e entregamos
        // somente depois de a aplicação estar ativa e a transação inicial ter sido concluída.
        await enqueueAccidentNotificationOpen()
    }
}

extension Notification.Name {
    static let checkingOpenAccident = Notification.Name("br.com.tscode.checking.open-accident")
}

private extension AppDelegate {
    func enqueueAccidentNotificationOpen() {
        pendingAccidentNotificationOpen = true
        deliverPendingAccidentNotificationWhenUIIsStable()
    }

    func deliverPendingAccidentNotificationWhenUIIsStable() {
        guard pendingAccidentNotificationOpen,
              UIApplication.shared.applicationState == .active else { return }
        accidentNotificationRouteTask?.cancel()
        accidentNotificationRouteTask = Task { @MainActor [weak self] in
            // `Task.yield` sozinho ainda pode cair no mesmo commit de restauração; a pequena janela
            // também cobre a animação de desbloqueio/abertura disparada pelo toque na notificação.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled,
                  let self,
                  self.pendingAccidentNotificationOpen,
                  UIApplication.shared.applicationState == .active else { return }
            self.pendingAccidentNotificationOpen = false
            NotificationCenter.default.post(name: .checkingOpenAccident, object: nil)
        }
    }
}
