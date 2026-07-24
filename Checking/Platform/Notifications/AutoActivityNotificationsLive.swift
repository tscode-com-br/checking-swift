import Foundation
import UserNotifications

/// Seam fina sobre `UNUserNotificationCenter.add(_:)` — permite testar `AutoActivityNotificationsLive`
/// sem tocar no centro real. `UNUserNotificationCenter` já satisfaz via seu próprio `add(_:) async throws`.
protocol NotificationRequestPosting: Sendable {
    func add(_ request: UNNotificationRequest) async throws
}
extension UNUserNotificationCenter: NotificationRequestPosting {}

protocol ScheduledNotificationCenter: NotificationRequestPosting {
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}
extension UNUserNotificationCenter: ScheduledNotificationCenter {}

/// Agenda as mensagens de início/fim da pausa no próprio sistema. Isso dá pontualidade à informação
/// mesmo quando o processo está suspenso; não promete execução de código no horário (restrição do iOS).
final class LocalNotificationPauseAlarmScheduler: PauseAlarmScheduling, @unchecked Sendable {
    private static let startIdentifier = "scheduledPause.transition.start"
    private static let resumeIdentifier = "scheduledPause.transition.resume"
    private static let startDateKey = "pref_scheduled_pause_notification_start_at"
    private static let resumeDateKey = "pref_scheduled_pause_notification_resume_at"

    private let center: any ScheduledNotificationCenter
    private let defaults: UserDefaults

    init(
        center: any ScheduledNotificationCenter = UNUserNotificationCenter.current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
    }

    func scheduleResume(at: Date?, notify: Bool, lang: String) async {
        await schedule(started: false, at: at, notify: notify, lang: lang)
    }

    func scheduleStart(at: Date?, notify: Bool, lang: String) async {
        await schedule(started: true, at: at, notify: notify, lang: lang)
    }

    func consumeScheduledTransition(started: Bool, dueAtOrBefore now: Date) async -> Bool {
        let key = started ? Self.startDateKey : Self.resumeDateKey
        let timestamp = defaults.double(forKey: key)
        guard timestamp > 0, timestamp <= now.timeIntervalSince1970 else { return false }
        defaults.removeObject(forKey: key)
        center.removePendingNotificationRequests(
            withIdentifiers: [started ? Self.startIdentifier : Self.resumeIdentifier])
        return true
    }

    private func schedule(started: Bool, at date: Date?, notify: Bool, lang: String) async {
        let identifier = started ? Self.startIdentifier : Self.resumeIdentifier
        let key = started ? Self.startDateKey : Self.resumeDateKey
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        defaults.removeObject(forKey: key)

        guard notify, let date, date.timeIntervalSinceNow > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = t("autoActivities.notification.brandTitle", lang: lang)
        content.body = t(
            started
                ? "autoActivities.notification.pauseStartMessage"
                : "autoActivities.notification.pauseEndMessage",
            lang: lang)
        content.sound = .default
        content.userInfo = [
            "checking_event": started ? "scheduled_pause_started" : "scheduled_pause_ended",
        ]

        let calendar = Calendar.current
        var components = calendar.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: date)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        do {
            try await center.add(request)
            defaults.set(date.timeIntervalSince1970, forKey: key)
        } catch {
            AppLog.background.error(
                "Could not schedule pause transition notification: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Implementação viva de `AutoActivityNotifying` — port de
/// platform/background/notifications/AutoActivityNotifications.kt (§23.9, T3B.6).
///
/// Sem `buildServiceNotification`/`updateServiceNotification`: o iOS não tem a notificação ongoing
/// persistente de FGS (ver comentário em `OrchestratorSeams.swift`).
///
/// `notify(id, ...)` do Android substitui a notificação existente com o mesmo id; aqui o mesmo
/// `identifier` faz o `UNUserNotificationCenter` substituir a pendente/entregue equivalente — mesma
/// semântica de "no máximo 1 notificação viva por tipo".
///
/// Falha ao postar (ex.: permissão não concedida) é silenciosa — fiel ao Android, onde `notify()`
/// sem `POST_NOTIFICATIONS` também não propaga erro ao chamador. Solicitar a permissão em si é do
/// slice de permissões (`port_spec_permissions_diagnostics §7`), não deste.
struct AutoActivityNotificationsLive: AutoActivityNotifying {
    private let center: any NotificationRequestPosting

    init(center: any NotificationRequestPosting = UNUserNotificationCenter.current()) {
        self.center = center
    }

    func postAccidentNotification(lang: String) {
        postSimpleEvent(identifier: "autoActivities.accident",
                        message: t("autoActivities.notification.accidentMessage", lang: lang),
                        lang: lang,
                        categoryIdentifier: AppDelegate.accidentNotificationCategory,
                        userInfo: ["checking_event": "accident"])
    }

    func postActivityNotification(action: CheckAction, local: String?, lang: String) {
        let genericMessage = action == .checkIn
            ? t("autoActivities.notification.checkinMessage", lang: lang)
            : t("autoActivities.notification.checkoutMessage", lang: lang)
        let actionLabel = t(action == .checkIn
            ? "history.activityCheckin"
            : "history.activityCheckout", lang: lang)
        let normalizedLocation = local?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = normalizedLocation.flatMap { $0.isEmpty ? nil : "\(actionLabel) @ \($0)" }
            ?? genericMessage
        postSimpleEvent(identifier: "autoActivities.event", message: message, lang: lang)
    }

    func postReauthNotification(lang: String) {
        post(identifier: "autoActivities.reauth",
             title: t("autoActivities.notification.reauthTitle", lang: lang),
             body: t("autoActivities.notification.reauthBody", lang: lang))
    }

    func postScheduledPauseTransition(started: Bool, lang: String) {
        let message = started
            ? t("autoActivities.notification.pauseStartMessage", lang: lang)
            : t("autoActivities.notification.pauseEndMessage", lang: lang)
        postSimpleEvent(identifier: "autoActivities.pause", message: message, lang: lang)
    }

    // Builder compartilhado das notificações simples "marca + mensagem" — port de postSimpleEvent.
    private func postSimpleEvent(
        identifier: String,
        message: String,
        lang: String,
        categoryIdentifier: String = "",
        userInfo: [String: String] = [:]
    ) {
        post(
            identifier: identifier,
            title: t("autoActivities.notification.brandTitle", lang: lang),
            body: message,
            categoryIdentifier: categoryIdentifier,
            userInfo: userInfo)
    }

    private func post(
        identifier: String,
        title: String,
        body: String,
        categoryIdentifier: String = "",
        userInfo: [String: String] = [:]
    ) {
        let center = center
        Task {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = categoryIdentifier
            content.userInfo = userInfo
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
