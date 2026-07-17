import XCTest
import UserNotifications
@testable import Checking

/// Port comportamental de NotificationMechanismTest.kt (instrumented no Android, `NotificationManager`
/// real). Aqui um spy da seam `NotificationRequestPosting` no lugar do `UNUserNotificationCenter` real —
/// XCTest não tem o equivalente de `getActiveNotifications()`. Cobre título/corpo por tipo. O teste
/// `accidentNotification_localizesByLanguage` do Kotlin (pt vs en) NÃO é portado: o catálogo multi-idioma
/// é do slice de i18n (`Localization.swift` hoje só tem PT) — mesma lacuna documentada alhures.
final class AutoActivityNotificationsLiveTests: XCTestCase {

    // `UNNotificationRequest` não é `Sendable` na SDK — um `actor` aqui exigiria cruzar o limite de
    // isolamento com um tipo não-Sendable. Classe com `NSLock` (mesmo padrão de `FakeProjectsApi`).
    private final class SpyCenter: NotificationRequestPosting, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(identifier: String, title: String, body: String)] = []
        var requests: [(identifier: String, title: String, body: String)] { lock.withLock { recorded } }

        func add(_ request: UNNotificationRequest) async throws {
            lock.withLock { recorded.append((request.identifier, request.content.title, request.content.body)) }
        }
    }

    private func makeSUT() -> (AutoActivityNotificationsLive, SpyCenter) {
        let spy = SpyCenter()
        return (AutoActivityNotificationsLive(center: spy), spy)
    }

    // O post é fire-and-forget (`Task { ... }`, sem suspensão no protocolo — fiel ao `notify()` síncrono
    // do Android). Poll curto com timeout — mesma estratégia de `awaitActive` no teste instrumentado Kotlin.
    private func awaitRequests(_ spy: SpyCenter, count: Int = 1, timeout: TimeInterval = 1.0) async -> [(identifier: String, title: String, body: String)] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = spy.requests
            if current.count >= count { return current }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return spy.requests
    }

    func test_postAccidentNotification_postsBrandTitleAndAccidentMessage() async {
        let (sut, spy) = makeSUT()
        sut.postAccidentNotification(lang: "pt")
        let requests = await awaitRequests(spy)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.title, "Checking")
        XCTAssertEqual(requests.first?.body, "Checking: acidente reportado!")
    }

    func test_postActivityNotification_checkIn_postsCheckinMessage() async {
        let (sut, spy) = makeSUT()
        sut.postActivityNotification(action: .checkIn, local: "Unidade P80", lang: "pt")
        let requests = await awaitRequests(spy)
        XCTAssertEqual(requests.first?.title, "Checking")
        XCTAssertEqual(requests.first?.body, "Check-In realizado.")
    }

    func test_postActivityNotification_checkOut_postsCheckoutMessage() async {
        let (sut, spy) = makeSUT()
        sut.postActivityNotification(action: .checkOut, local: nil, lang: "pt")
        let requests = await awaitRequests(spy)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.body, "Check-Out realizado.")
    }

    func test_postScheduledPauseTransition_started_postsPauseStartMessage() async {
        let (sut, spy) = makeSUT()
        sut.postScheduledPauseTransition(started: true, lang: "pt")
        let requests = await awaitRequests(spy)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.body, "Checking em pausa.")
    }

    func test_postScheduledPauseTransition_ended_postsPauseEndMessage() async {
        let (sut, spy) = makeSUT()
        sut.postScheduledPauseTransition(started: false, lang: "pt")
        let requests = await awaitRequests(spy)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.body, "Checking em atividade.")
    }

    func test_postReauthNotification_postsReauthTitleAndBody() async {
        let (sut, spy) = makeSUT()
        sut.postReauthNotification(lang: "pt")
        let requests = await awaitRequests(spy)
        XCTAssertEqual(requests.first?.title, "Checking — Reautenticação necessária")
        XCTAssertEqual(requests.first?.body, "Abra o aplicativo para entrar novamente.")
    }

    // `notify(NOTIFICATION_ID_EVENT, ...)` no Android sempre substitui a notificação anterior do mesmo
    // tipo (mesmo id). Aqui, mesmo `identifier` faz o UNUserNotificationCenter substituir na mesma forma.
    func test_repeatedActivityPosts_shareTheSameIdentifier() async {
        let (sut, spy) = makeSUT()
        sut.postActivityNotification(action: .checkIn, local: nil, lang: "pt")
        sut.postActivityNotification(action: .checkOut, local: nil, lang: "pt")
        let requests = await awaitRequests(spy, count: 2)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.identifier).first, requests.map(\.identifier).last)
    }

    // Tipos diferentes não devem colidir no mesmo identifier (senão um cancelaria o outro indevidamente).
    func test_differentNotificationTypes_useDifferentIdentifiers() async {
        let (sut, spy) = makeSUT()
        sut.postAccidentNotification(lang: "pt")
        sut.postReauthNotification(lang: "pt")
        let requests = await awaitRequests(spy, count: 2)
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests[0].identifier, requests[1].identifier)
    }
}
