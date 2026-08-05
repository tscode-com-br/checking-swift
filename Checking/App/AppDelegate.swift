import UIKit
import BackgroundTasks
import UserNotifications

/// Mantém `BGTask` confinado ao `AppDelegate`; a seleção candidato/legado é exercitável sem instanciar
/// uma task do framework em testes. O adapter não retém estado de execução nem altera completion.
@MainActor
private final class UIKitSystemBackgroundTaskAdapter: SystemBackgroundTaskHandling {
    private let task: BGTask

    init(task: BGTask) {
        self.task = task
    }

    func installExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        task.expirationHandler = { handler() }
    }
}

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
    static let refreshTaskID = BGTaskAppRefreshScheduler.taskIdentifier
    static let processingTaskID = BGTaskSyncScheduler.taskIdentifier   // "…​.processing"
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
        let evaluationJournal = environment.evaluationJournal
        Task(priority: .utility) { await evaluationJournal.reconcileOrphans() }
        let refreshSubmissionError = environment.appRefreshScheduler.scheduleRegularRefresh()
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
                        // O relatório Debug não persiste `Error` bruto. O Simulator só precisa distinguir
                        // scheduled de indisponibilidade conhecida para manter o resultado inconclusivo.
                        "refreshSubmission": Self.validationRefreshSubmission(
                            from: refreshSubmissionError
                        )
                    ]
                )
                let requests = await BGTaskScheduler.shared.pendingTaskRequests()
                await BackgroundValidationRecorder.shared.record(
                    "bg_task_pending_requests",
                    details: [
                        "count": String(requests.count),
                        "hasRefresh": String(
                            requests.contains { $0.identifier == BGTaskAppRefreshScheduler.taskIdentifier }
                        ),
                        "hasProcessing": String(
                            requests.contains { $0.identifier == BGTaskSyncScheduler.taskIdentifier }
                        )
                    ]
                )
            }
        }
#endif
        return true
    }

#if DEBUG
    private static func validationRefreshSubmission(from errorDescription: String?) -> String {
        guard let errorDescription else { return "scheduled" }
        // Só a categoria estável cruza o boundary do report; `errorDescription` nunca é gravada.
        return errorDescription.contains("BGTaskSchedulerErrorDomain Code=1") ? "unavailable" : "rejected"
    }
#endif

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

    private func registerBackgroundTasks() -> (refresh: Bool, processing: Bool) {
        // Reconciliação curta oportunista — equivalente ao timer 15min do FGS Android (§9, "Sem tick garantido").
        let orchestrator = environment.orchestrator
        let refreshScheduler = environment.appRefreshScheduler
        let refreshRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskID,
            // `AppDelegate` e este handler são isolados na MainActor. Se o sistema escolher sua fila
            // privada (`using: nil`), Swift 6 encerra o processo em `_dispatch_assert_queue_fail` antes
            // mesmo do primeiro `Task`. A fila explícita torna o contrato do callback compatível.
            using: .main
        ) { task in
            nonisolated(unsafe) let bgTask = task     // BGTask não é Sendable; usado serialmente aqui
            let systemTask = UIKitSystemBackgroundTaskAdapter(task: bgTask)
            AppDelegateBackgroundTaskHandlerRouter.install(
                profile: self.environment.backgroundReliabilityProfile,
                task: systemTask,
                startCandidate: {
                    let trigger = refreshScheduler.triggerForPendingRefresh()
                    let controller = BGAppRefreshExecutionController(
                        startEvaluation: { trigger, ownerRegistration in
#if DEBUG
                            if UserDefaults.standard.bool(forKey: "debug.background_validation.enabled") {
                                await BackgroundValidationRecorder.shared.record("bg_app_refresh_started")
                            }
#endif
                            return await orchestrator.evaluationTicket(
                                trigger,
                                ownerRegistration: ownerRegistration
                            )
                        },
                        scheduleRegularRefresh: {
                            // Reagendar "regular" preserva os deadlines persistidos de precisão e pausa.
                            _ = refreshScheduler.scheduleRegularRefresh()
                        }
                    )
                    let handle = controller.start(trigger: trigger) { success in
#if DEBUG
                        if UserDefaults.standard.bool(forKey: "debug.background_validation.enabled") {
                            Task {
                                await BackgroundValidationRecorder.shared.record(
                                    "bg_app_refresh_completed",
                                    details: ["success": String(success)]
                                )
                            }
                        }
#endif
                        bgTask.setTaskCompleted(success: success)
                    }
                    // A expiração é síncrona: ela só marca/libera este owner e o trabalho canônico faz
                    // journal + cleanup antes do terminal quando este era o último orçamento válido.
                    return SystemBackgroundTaskExpirationHandle { _ = handle.expire() }
                },
                startLegacy: {
                    // `legacyWithDiagnostics` continua no handler histórico e não instancia o controller.
                    let work = Task {
#if DEBUG
                        if UserDefaults.standard.bool(forKey: "debug.background_validation.enabled") {
                            await BackgroundValidationRecorder.shared.record("bg_app_refresh_started")
                        }
#endif
                        let trigger = refreshScheduler.triggerForPendingRefresh()
                        await orchestrator.runOnce(trigger)
                        // Reagendar "regular" preserva os deadlines persistidos de precisão e pausa no mesmo request.
                        refreshScheduler.scheduleRegularRefresh()
#if DEBUG
                        if UserDefaults.standard.bool(forKey: "debug.background_validation.enabled") {
                            await BackgroundValidationRecorder.shared.record("bg_app_refresh_completed")
                        }
#endif
                        bgTask.setTaskCompleted(success: true)
                    }
                    return SystemBackgroundTaskExpirationHandle { work.cancel() }
                }
            )
        }
        // Replay da fila offline (port de SyncPendingChecksWorker) — dispara o drain do coordenador.
        let coordinator = environment.offlineSyncCoordinator
        let backgroundProcessingScheduler = environment.backgroundProcessingScheduler
        let processingRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskID,
            using: .main
        ) { task in
            nonisolated(unsafe) let bgTask = task     // BGTask não é Sendable; usado serialmente aqui
            let systemTask = UIKitSystemBackgroundTaskAdapter(task: bgTask)
            AppDelegateBackgroundTaskHandlerRouter.install(
                profile: self.environment.backgroundReliabilityProfile,
                task: systemTask,
                startCandidate: {
                    let controller = BGProcessingExecutionController(
                        startDrain: {
#if DEBUG
                            if UserDefaults.standard.bool(forKey: "debug.background_validation.enabled") {
                                await BackgroundValidationRecorder.shared.record("bg_processing_started")
                            }
#endif
                            return await coordinator.drainTicket()
                        },
                        scheduleProcessing: {
                            // Reenvia apenas o request oportunista; não inicia um segundo drain em loop.
                            backgroundProcessingScheduler.rescheduleBackgroundProcessing()
                        }
                    )
                    let handle = controller.start { success in
#if DEBUG
                        if UserDefaults.standard.bool(forKey: "debug.background_validation.enabled") {
                            Task {
                                await BackgroundValidationRecorder.shared.record(
                                    "bg_processing_completed",
                                    details: ["success": String(success)]
                                )
                            }
                        }
#endif
                        bgTask.setTaskCompleted(success: success)
                    }
                    return SystemBackgroundTaskExpirationHandle { _ = handle.expire() }
                },
                startLegacy: {
                    // `legacyWithDiagnostics` continua no handler histórico e não instancia o controller.
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
                    return SystemBackgroundTaskExpirationHandle { work.cancel() }
                }
            )
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
        // Não promover descrições de erro do sistema ao log exportável.
        AppLog.background.error("APNs registration failed.")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
#if DEBUG
        if BackgroundValidationHarness.isEnabled {
            let hasValidationMarker = userInfo["checking_validation"] != nil
            Task {
                await BackgroundValidationRecorder.shared.record(
                    "remote_notification_received",
                    details: ["hasValidationMarker": String(hasValidationMarker)]
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

    nonisolated static func shouldOpenAccidentNotification(
        actionIdentifier: String,
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> Bool {
        let isOpenAction = actionIdentifier == openAccidentAction
            || actionIdentifier == UNNotificationDefaultActionIdentifier
        guard isOpenAction else { return false }
        return categoryIdentifier == accidentNotificationCategory || isAccidentPayload(userInfo)
    }
}

/// A closure de conclusão vem de Objective-C e nem todos os SDKs usados pelo projeto a importam
/// como `@Sendable`. O box atravessa somente a fronteira até a MainActor, onde a closure é chamada.
private final class NotificationResponseCompletionBox: @unchecked Sendable {
    let call: () -> Void

    init(_ call: @escaping () -> Void) {
        self.call = call
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
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let shouldOpenAccident = Self.shouldOpenAccidentNotification(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: content.categoryIdentifier,
            userInfo: content.userInfo
        )
        let completion = NotificationResponseCompletionBox(completionHandler)

        // Não usar aqui a overload async do delegate: no Swift 6 sua ponte Objective-C pode concluir
        // em uma worker thread. Em iOS 26, o UIKit então aborta ao atualizar o snapshot/restauração.
        Task { @MainActor [weak self] in
            // O sistema deve ser liberado logo após enfileirar a intenção; a entrega à UI mantém,
            // separadamente, o atraso de estabilização de 350 ms.
            defer { completion.call() }
            guard shouldOpenAccident else { return }
            self?.enqueueAccidentNotificationOpen()
        }
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
