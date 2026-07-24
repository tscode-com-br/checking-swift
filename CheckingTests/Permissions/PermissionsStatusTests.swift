import XCTest
@testable import Checking

/// Mapeamento do inspector (PermissionsInspector.kt) + derivações — spec §9 ("inspect mapping").
final class PermissionsStatusTests: XCTestCase {

    private func status(auth: LocationAuthorization, precise: Bool,
                        notif: NotificationAuthorization = .authorized, cameraMic: Bool = true,
                        lowPower: Bool = false, bg: BackgroundRefreshAvailability = .available) -> PermissionsStatus {
        PermissionsStatus(locationAuthorization: auth, preciseAccuracy: precise, cameraMicGranted: cameraMic,
                          notificationAuthorization: notif, lowPowerMode: lowPower, backgroundRefresh: bg)
    }

    // MARK: LocationStatus (fullAccuracy/reducedAccuracy/denied)

    func test_location_preciseWhenAuthorizedAndFullAccuracy() {
        XCTAssertEqual(status(auth: .whenInUse, precise: true).location, .precise)
        XCTAssertEqual(status(auth: .always, precise: true).location, .precise)
    }

    func test_location_impreciseWhenAuthorizedButReducedAccuracy() {
        XCTAssertEqual(status(auth: .whenInUse, precise: false).location, .imprecise)
        XCTAssertEqual(status(auth: .always, precise: false).location, .imprecise)
    }

    func test_location_deniedWhenNotAuthorized_regardlessOfAccuracyFlag() {
        XCTAssertEqual(status(auth: .denied, precise: true).location, .denied)
        XCTAssertEqual(status(auth: .notDetermined, precise: true).location, .denied)
    }

    // MARK: derivações da escada

    func test_preciseLocationGranted_needsAuthorizedAndFullAccuracy() {
        XCTAssertTrue(status(auth: .whenInUse, precise: true).preciseLocationGranted)
        XCTAssertTrue(status(auth: .always, precise: true).preciseLocationGranted)
        XCTAssertFalse(status(auth: .whenInUse, precise: false).preciseLocationGranted)  // reduzida
        XCTAssertFalse(status(auth: .denied, precise: true).preciseLocationGranted)      // negada
        XCTAssertFalse(status(auth: .notDetermined, precise: true).preciseLocationGranted)
    }

    func test_alwaysLocationGranted_onlyWhenAlways() {
        XCTAssertTrue(status(auth: .always, precise: true).alwaysLocationGranted)
        XCTAssertFalse(status(auth: .whenInUse, precise: true).alwaysLocationGranted)
    }

    func test_ladder_derivedFromStatus() {
        let s = status(auth: .always, precise: true, notif: .authorized)
        XCTAssertEqual(s.ladder, PermissionLadderStatus(notificationsGranted: true, preciseLocationGranted: true, alwaysLocationGranted: true))
        let s2 = status(auth: .whenInUse, precise: false, notif: .denied)
        XCTAssertEqual(s2.ladder, PermissionLadderStatus(notificationsGranted: false, preciseLocationGranted: false, alwaysLocationGranted: false))
    }

    // MARK: mapeamentos estáticos do inspector vivo (funções puras)

    func test_mapAuthorization() {
        XCTAssertEqual(PermissionsInspectorLive.mapAuthorization(.authorizedAlways), .always)
        XCTAssertEqual(PermissionsInspectorLive.mapAuthorization(.authorizedWhenInUse), .whenInUse)
        XCTAssertEqual(PermissionsInspectorLive.mapAuthorization(.denied), .denied)
        XCTAssertEqual(PermissionsInspectorLive.mapAuthorization(.restricted), .denied)
        XCTAssertEqual(PermissionsInspectorLive.mapAuthorization(.notDetermined), .notDetermined)
    }

    func test_mapBackgroundRefresh() {
        XCTAssertEqual(PermissionsInspectorLive.mapBackgroundRefresh(.available), .available)
        XCTAssertEqual(PermissionsInspectorLive.mapBackgroundRefresh(.denied), .denied)
        XCTAssertEqual(PermissionsInspectorLive.mapBackgroundRefresh(.restricted), .restricted)
    }

    func test_mapNotificationAuthorization() {
        XCTAssertEqual(PermissionsInspectorLive.mapNotificationAuthorization(.authorized), .authorized)
        XCTAssertEqual(PermissionsInspectorLive.mapNotificationAuthorization(.provisional), .authorized)
        XCTAssertEqual(PermissionsInspectorLive.mapNotificationAuthorization(.ephemeral), .authorized)
        XCTAssertEqual(PermissionsInspectorLive.mapNotificationAuthorization(.denied), .denied)
        XCTAssertEqual(PermissionsInspectorLive.mapNotificationAuthorization(.notDetermined), .notDetermined)
    }

    func test_mapNotificationSetting_preservesEveryNativeState() {
        XCTAssertEqual(PermissionsInspectorLive.mapNotificationSetting(.enabled), .enabled)
        XCTAssertEqual(PermissionsInspectorLive.mapNotificationSetting(.disabled), .disabled)
        XCTAssertEqual(PermissionsInspectorLive.mapNotificationSetting(.notSupported), .notSupported)
    }

    func test_notificationDelivery_reportsWhetherAnyVisualDestinationIsEnabled() {
        let hidden = NotificationDeliveryStatus(
            alerts: .disabled, lockScreen: .disabled, notificationCenter: .disabled,
            badges: .enabled, sounds: .enabled, scheduledDelivery: .disabled)
        XCTAssertFalse(hidden.hasVisibleDestination)

        let visible = NotificationDeliveryStatus(
            alerts: .disabled, lockScreen: .enabled, notificationCenter: .disabled,
            badges: .disabled, sounds: .disabled, scheduledDelivery: .disabled)
        XCTAssertTrue(visible.hasVisibleDestination)
    }

    func test_globalLocationServicesOff_makesLocationOperationallyUnavailable() {
        let s = PermissionsStatus(
            locationAuthorization: .always,
            preciseAccuracy: true,
            cameraMicGranted: true,
            notificationAuthorization: .authorized,
            lowPowerMode: false,
            backgroundRefresh: .available,
            locationServicesEnabled: false)
        XCTAssertFalse(s.preciseLocationGranted)
        XCTAssertFalse(s.alwaysLocationGranted)
    }
}
