import XCTest
@testable import Checking

/// A peça central do slice: a "degradação honesta" (`AutomationHealthLevel`) + as regras de severidade do
/// painel. Lógica NOVA (o Android não tem esse conceito de nível — ele promete background via FGS); é o
/// ponto onde o iOS reporta o que realmente consegue. Sem contraparte de teste no Kotlin.
final class AutomationHealthTests: XCTestCase {

    private func status(auth: LocationAuthorization = .always, precise: Bool = true,
                        notif: NotificationAuthorization = .authorized,
                        cameraMic: Bool = true, lowPower: Bool = false,
                        bg: BackgroundRefreshAvailability = .available) -> PermissionsStatus {
        PermissionsStatus(locationAuthorization: auth, preciseAccuracy: precise, cameraMicGranted: cameraMic,
                          notificationAuthorization: notif, lowPowerMode: lowPower, backgroundRefresh: bg)
    }

    // MARK: AutomationHealthLevel

    func test_blocked_whenMinimumNotGranted() {
        XCTAssertEqual(status(auth: .denied, precise: false).automationHealthLevel, .blocked)     // sem localização
        XCTAssertEqual(status(notif: .denied).automationHealthLevel, .blocked)                       // sem notificações
        XCTAssertEqual(status(auth: .whenInUse, precise: false).automationHealthLevel, .blocked)   // precisão reduzida (não é "precisa")
    }

    func test_operational_whenMinimumPlusAlwaysPlusBackgroundRefresh() {
        XCTAssertEqual(status(auth: .always, precise: true, bg: .available).automationHealthLevel, .operational)
    }

    func test_degradedForeground_whenMinimumButNoAlways() {
        XCTAssertEqual(status(auth: .whenInUse, precise: true, bg: .available).automationHealthLevel, .degradedForeground)
    }

    func test_degradedForeground_whenMinimumAndAlwaysButBackgroundRefreshOff() {
        XCTAssertEqual(status(auth: .always, precise: true, bg: .denied).automationHealthLevel, .degradedForeground)
        XCTAssertEqual(status(auth: .always, precise: true, bg: .restricted).automationHealthLevel, .degradedForeground)
    }

    func test_lowPowerMode_doesNotDemoteLevel() {
        // Low Power é recomendado-não-bloqueante: NÃO rebaixa o nível (só vira aviso na severidade).
        XCTAssertEqual(status(auth: .always, precise: true, lowPower: true, bg: .available).automationHealthLevel, .operational)
    }

    // MARK: severidades por sinal

    private func report(_ s: PermissionsStatus, consent: Bool = true, automatic: Bool = true,
                        pauseActive: Bool = false, nextPause: Date? = nil, monitored: Int = 0, omitted: Int = 0,
                        lastEval: EvaluationEntry? = nil, offline: Int = 0) -> HealthReport {
        HealthReport(permissions: s, lgpdConsentGranted: consent, automaticEnabled: automatic,
                     scheduledPauseActive: pauseActive, nextPauseTransition: nextPause,
                     monitoredRegions: monitored, omittedRegions: omitted, lastEvaluation: lastEval, offlinePendingCount: offline)
    }

    func test_locationSeverity() {
        XCTAssertEqual(report(status(auth: .always, precise: true)).locationSeverity, .ok)
        XCTAssertEqual(report(status(auth: .whenInUse, precise: false)).locationSeverity, .warning)
        XCTAssertEqual(report(status(auth: .denied, precise: true)).locationSeverity, .critical)
    }

    func test_notificationsSeverity_criticalWhenMissing() {
        XCTAssertEqual(report(status(notif: .authorized)).notificationsSeverity, .ok)
        XCTAssertEqual(report(status(notif: .denied)).notificationsSeverity, .critical)
    }

    func test_alwaysLocationSeverity_warningWhenNotAlways() {
        XCTAssertEqual(report(status(auth: .always, precise: true)).alwaysLocationSeverity, .ok)
        XCTAssertEqual(report(status(auth: .whenInUse, precise: true)).alwaysLocationSeverity, .warning)
    }

    func test_backgroundRefreshSeverity() {
        XCTAssertEqual(report(status(bg: .available)).backgroundRefreshSeverity, .ok)
        XCTAssertEqual(report(status(bg: .denied)).backgroundRefreshSeverity, .warning)
        XCTAssertEqual(report(status(bg: .restricted)).backgroundRefreshSeverity, .warning)
    }

    func test_lowPowerSeverity() {
        XCTAssertEqual(report(status(lowPower: false)).lowPowerSeverity, .ok)
        XCTAssertEqual(report(status(lowPower: true)).lowPowerSeverity, .warning)
    }

    func test_consentSeverity_criticalWithoutConsent() {
        XCTAssertEqual(report(status(), consent: true).consentSeverity, .ok)
        XCTAssertEqual(report(status(), consent: false).consentSeverity, .critical)
    }

    func test_omittedRegionsSeverity() {
        XCTAssertEqual(report(status(), omitted: 0).omittedRegionsSeverity, .ok)
        XCTAssertEqual(report(status(), omitted: 3).omittedRegionsSeverity, .warning)
    }

    func test_offlineQueueSeverity() {
        XCTAssertEqual(report(status(), offline: 0).offlineQueueSeverity, .ok)
        XCTAssertEqual(report(status(), offline: 5).offlineQueueSeverity, .warning)
    }

    func test_reportLevel_matchesPermissionsLevel() {
        XCTAssertEqual(report(status(auth: .always, precise: true, bg: .available)).level, .operational)
        XCTAssertEqual(report(status(auth: .whenInUse, precise: true)).level, .degradedForeground)
        XCTAssertEqual(report(status(notif: .denied)).level, .blocked)
    }

    // MARK: needsOpenSettings

    func test_needsOpenSettings_trueWhenLocationDenied() {
        XCTAssertTrue(report(status(auth: .denied, precise: true)).needsOpenSettings)
    }

    func test_needsOpenSettings_trueWhenBackgroundRefreshNotAvailable() {
        XCTAssertTrue(report(status(bg: .denied)).needsOpenSettings)
        XCTAssertTrue(report(status(bg: .restricted)).needsOpenSettings)
    }

    func test_needsOpenSettings_falseWhenNotDeterminedOrWhenInUse() {
        // Estados resolvíveis por prompt in-app (fluxo da escada), NÃO por Ajustes.
        XCTAssertFalse(report(status(auth: .notDetermined, precise: true, bg: .available)).needsOpenSettings)
        XCTAssertFalse(report(status(auth: .whenInUse, precise: true, bg: .available)).needsOpenSettings)
    }

    // Regressão (achado MEDIUM da revisão): notificações NEGADAS deixavam o usuário blocked sem remédio —
    // `requestAuthorization` não re-pede depois de negado, então o painel PRECISA rotear p/ Ajustes.
    func test_needsOpenSettings_trueWhenNotificationsDenied() {
        XCTAssertTrue(report(status(auth: .always, precise: true, notif: .denied, bg: .available)).needsOpenSettings)
    }

    func test_needsOpenSettings_falseWhenNotificationsNotDetermined() {
        // Ainda pedível in-app pela escada → NÃO força Ajustes.
        XCTAssertFalse(report(status(auth: .always, precise: true, notif: .notDetermined, bg: .available)).needsOpenSettings)
    }

    func test_needsOpenSettings_falseWhenAllGood() {
        XCTAssertFalse(report(status(auth: .always, precise: true, bg: .available)).needsOpenSettings)
    }
}
