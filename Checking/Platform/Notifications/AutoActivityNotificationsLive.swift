import Foundation
import UserNotifications

/// Seam fina sobre `UNUserNotificationCenter.add(_:)` — permite testar `AutoActivityNotificationsLive`
/// sem tocar no centro real. `UNUserNotificationCenter` já satisfaz via seu próprio `add(_:) async throws`.
protocol NotificationRequestPosting: Sendable {
    func add(_ request: UNNotificationRequest) async throws
}
extension UNUserNotificationCenter: NotificationRequestPosting {}

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
                        message: t("autoActivities.notification.accidentMessage", lang: lang), lang: lang)
    }

    func postActivityNotification(action: CheckAction, local _: String?, lang: String) {
        let message = action == .checkIn
            ? t("autoActivities.notification.checkinMessage", lang: lang)
            : t("autoActivities.notification.checkoutMessage", lang: lang)
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
    private func postSimpleEvent(identifier: String, message: String, lang: String) {
        post(identifier: identifier, title: t("autoActivities.notification.brandTitle", lang: lang), body: message)
    }

    private func post(identifier: String, title: String, body: String) {
        let center = center
        Task {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
