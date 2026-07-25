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
    private final class SpyCenter: ScheduledNotificationCenter, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(
            identifier: String,
            title: String,
            body: String,
            category: String,
            event: String?,
            nextTriggerDate: Date?
        )] = []
        private var removedIdentifiers: [[String]] = []
        private var removedDeliveredIdentifiers: [[String]] = []
        var requests: [(
            identifier: String,
            title: String,
            body: String,
            category: String,
            event: String?,
            nextTriggerDate: Date?
        )] {
            lock.withLock { recorded }
        }
        var removals: [[String]] { lock.withLock { removedIdentifiers } }
        var deliveredRemovals: [[String]] { lock.withLock { removedDeliveredIdentifiers } }

        func add(_ request: UNNotificationRequest) async throws {
            lock.withLock {
                recorded.append((
                    request.identifier,
                    request.content.title,
                    request.content.body,
                    request.content.categoryIdentifier,
                    request.content.userInfo["checking_event"] as? String,
                    (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()))
            }
        }

        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
            lock.withLock { removedIdentifiers.append(identifiers) }
        }

        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
            lock.withLock { removedDeliveredIdentifiers.append(identifiers) }
        }
    }

    private final class BlockingCenter: ScheduledNotificationCenter, @unchecked Sendable {
        let addGate = AsyncGate()
        private let lock = NSLock()
        private var addStartedValue = false
        private var removedIdentifiers: [[String]] = []
        var addStarted: Bool { lock.withLock { addStartedValue } }
        var removals: [[String]] { lock.withLock { removedIdentifiers } }

        func add(_ request: UNNotificationRequest) async throws {
            lock.withLock { addStartedValue = true }
            await addGate.wait()
        }
        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
            lock.withLock { removedIdentifiers.append(identifiers) }
        }
        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    }

    private func makeSUT() -> (AutoActivityNotificationsLive, SpyCenter) {
        let spy = SpyCenter()
        return (AutoActivityNotificationsLive(center: spy), spy)
    }

    // O post é fire-and-forget (`Task { ... }`, sem suspensão no protocolo — fiel ao `notify()` síncrono
    // do Android). Poll curto com timeout — mesma estratégia de `awaitActive` no teste instrumentado Kotlin.
    private func awaitRequests(
        _ spy: SpyCenter,
        count: Int = 1,
        timeout: TimeInterval = 1.0
    ) async -> [(
        identifier: String,
        title: String,
        body: String,
        category: String,
        event: String?,
        nextTriggerDate: Date?
    )] {
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
        XCTAssertEqual(requests.first?.category, AppDelegate.accidentNotificationCategory)
        XCTAssertEqual(requests.first?.event, "accident")
    }

    func test_postActivityNotification_checkIn_postsCheckinMessage() async {
        let (sut, spy) = makeSUT()
        sut.postActivityNotification(action: .checkIn, local: "Unidade P80", lang: "pt")
        let requests = await awaitRequests(spy)
        XCTAssertEqual(requests.first?.title, "Checking")
        XCTAssertEqual(requests.first?.body, "Check-In @ Unidade P80")
    }

    func test_postActivityNotification_checkOut_postsLocation() async {
        let (sut, spy) = makeSUT()
        sut.postActivityNotification(action: .checkOut, local: "Zona Mista", lang: "pt")
        let requests = await awaitRequests(spy)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.body, "Check-Out @ Zona Mista")
    }

    func test_postActivityNotification_withoutLocation_keepsGenericMessage() async {
        let (sut, spy) = makeSUT()
        sut.postActivityNotification(action: .checkOut, local: "  ", lang: "pt")
        let requests = await awaitRequests(spy)
        XCTAssertEqual(requests.first?.body, "Check-Out realizado.")
    }

    func test_postActivityNotification_localizesActionLabel() async {
        let (sut, spy) = makeSUT()
        sut.postActivityNotification(action: .checkIn, local: "办公区", lang: "zh")
        let requests = await awaitRequests(spy)
        XCTAssertEqual(requests.first?.body, "签到 @ 办公区")
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

    func test_lowAccuracyNotification_usesExpectedActionAndStableLocalizedContent() async {
        let (sut, spy) = makeSUT()
        await sut.postLowAccuracyNotification(expectedAction: .checkIn, lang: "pt")
        await sut.postLowAccuracyNotification(expectedAction: .checkIn, lang: "pt")

        let requests = await awaitRequests(spy, count: 2)
        XCTAssertEqual(requests.map(\.identifier), ["autoActivities.lowAccuracy", "autoActivities.lowAccuracy"])
        XCTAssertEqual(requests.first?.title, "Check-in - Falha!")
        XCTAssertEqual(requests.first?.body, "Baixa Precisão. Tentará novamente.")
        XCTAssertEqual(requests.first?.event, "low_accuracy")
    }

    func test_lowAccuracyNotification_usesGenericTitleWhenActionIsAmbiguous_andCanBeCleared() async {
        let (sut, spy) = makeSUT()
        await sut.postLowAccuracyNotification(expectedAction: nil, lang: "en")
        let requests = await awaitRequests(spy)

        XCTAssertEqual(requests.first?.title, "Automatic activity - Failed!")
        XCTAssertEqual(requests.first?.body, "Low accuracy. Will try again.")

        await sut.clearLowAccuracyNotification()

        XCTAssertEqual(spy.removals.last, ["autoActivities.lowAccuracy"])
        XCTAssertEqual(spy.deliveredRemovals.last, ["autoActivities.lowAccuracy"])
    }

    func test_pauseScheduler_postsTimedStart_andConsumesItAfterDueTime() async {
        let spy = SpyCenter()
        let suite = "br.com.tscode.checking.tests.pause.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sut = LocalNotificationPauseAlarmScheduler(center: spy, defaults: defaults)
        let fireDate = Date().addingTimeInterval(120)

        await sut.scheduleStart(at: fireDate, notify: true, lang: "pt")

        XCTAssertEqual(spy.requests.count, 1)
        XCTAssertEqual(spy.requests.first?.body, "Checking em pausa.")
        XCTAssertEqual(spy.requests.first?.event, "scheduled_pause_started")
        XCTAssertNotNil(spy.requests.first?.nextTriggerDate)
        let pendingRemovalsBeforeConsume = spy.removals
        let deliveredRemovalsBeforeConsume = spy.deliveredRemovals
        let beforeDue = await sut.consumeScheduledTransition(
            started: true,
            dueAtOrBefore: fireDate.addingTimeInterval(-1))
        let atDue = await sut.consumeScheduledTransition(
            started: true,
            dueAtOrBefore: fireDate)
        let afterConsume = await sut.consumeScheduledTransition(
            started: true,
            dueAtOrBefore: fireDate.addingTimeInterval(1))
        XCTAssertFalse(beforeDue)
        XCTAssertTrue(atDue)
        XCTAssertFalse(afterConsume)
        XCTAssertEqual(spy.removals, pendingRemovalsBeforeConsume)
        XCTAssertEqual(spy.deliveredRemovals, deliveredRemovalsBeforeConsume)
    }

    func test_pauseScheduler_cancelledOrDisabled_doesNotLeaveRequest() async {
        let spy = SpyCenter()
        let suite = "br.com.tscode.checking.tests.pause.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sut = LocalNotificationPauseAlarmScheduler(center: spy, defaults: defaults)

        await sut.scheduleResume(at: Date().addingTimeInterval(120), notify: false, lang: "pt")

        XCTAssertTrue(spy.requests.isEmpty)
        XCTAssertFalse(spy.removals.isEmpty)
        XCTAssertEqual(spy.deliveredRemovals.last, ["scheduledPause.transition.resume"])
    }

    func test_pauseScheduler_serializesCancellationAfterInflightAdd() async {
        let center = BlockingCenter()
        let suite = "br.com.tscode.checking.tests.pause.serial.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sut = LocalNotificationPauseAlarmScheduler(center: center, defaults: defaults)
        let scheduling = Task {
            await sut.scheduleResume(at: Date().addingTimeInterval(120), notify: true, lang: "pt")
        }
        await waitUntil { center.addStarted }

        let cancellation = Task {
            await sut.scheduleResume(at: nil, notify: false, lang: "pt")
        }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(center.removals.count, 1, "cancel deve aguardar o add em voo")

        await center.addGate.release()
        await scheduling.value
        await cancellation.value
        XCTAssertEqual(center.removals.count, 2)
        XCTAssertEqual(center.removals.last, ["scheduledPause.transition.resume"])
    }

    func test_accidentPushPayloadRecognition_acceptsContractVariants() {
        XCTAssertTrue(AppDelegate.isAccidentPayload(["checking_event": "accident"]))
        XCTAssertTrue(AppDelegate.isAccidentPayload(["event": "accident_opened"]))
        XCTAssertTrue(AppDelegate.isAccidentPayload([
            "aps": ["category": AppDelegate.accidentNotificationCategory],
        ]))
        XCTAssertFalse(AppDelegate.isAccidentPayload(["type": "checkin"]))
        XCTAssertFalse(AppDelegate.isAccidentPayload(["aps": ["alert": "hello"]]))
    }
}
