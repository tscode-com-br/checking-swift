import XCTest
@testable import Checking

// Port de SituationMatrixTest.kt (18) + os testes puros de shouldAttemptAutomaticMixedZoneLocationEvent
// de AutoActivitiesSituationTest (4). Ver docs/port_spec_decision_engine.md §9.1.
final class DecisionMatrixTests: XCTestCase {

    private let interval = 15 // MIXED_INTERVAL

    private func match(_ status: MatchStatus, _ resolvedLocal: String? = nil) -> LocationMatch {
        LocationMatch(
            matched: status == .matched, resolvedLocal: resolvedLocal, label: resolvedLocal ?? "",
            status: status, message: "", accuracyMeters: 10.0, accuracyThresholdMeters: 50,
            minimumCheckoutDistanceMeters: 2000, nearestWorkplaceDistanceMeters: nil
        )
    }

    private func state(_ last: CheckAction?, currentLocal: String? = nil,
                       lastCheckinAt: Date? = nil, lastCheckoutAt: Date? = nil) -> HistoryState {
        HistoryState(
            found: true, chave: "STM1", projeto: "P80", currentAction: last, currentLocal: currentLocal,
            hasCurrentDayCheckin: last == .checkIn,
            lastCheckinAt: lastCheckinAt ?? (last == .checkIn ? Date() : nil),
            lastCheckoutAt: lastCheckoutAt ?? (last == .checkOut ? Date() : nil),
            transportEnabled: false
        )
    }

    private func assertActivity(_ result: AutomaticActivity?, _ action: CheckAction, _ local: String?,
                                _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result, AutomaticActivity(action: action, local: local), message, file: file, line: line)
    }

    // ── Situação 1-8 ──────────────────────────────────────────────────────────
    func test_1a_checkin_in_checkout_zone_checks_out() {
        assertActivity(resolveAutomaticActivityForMatch(match(.matched, "Zona de CheckOut"), state(.checkIn), interval), .checkOut, "Zona de CheckOut")
    }
    func test_1b_checkin_far_checks_out() {
        assertActivity(resolveAutomaticActivityForMatch(match(.outsideWorkplace), state(.checkIn), interval), .checkOut, "Fora do Local de Trabalho")
    }
    func test_2a_checkout_in_checkout_zone_no_action() {
        XCTAssertNil(resolveAutomaticActivityForMatch(match(.matched, "Zona de CheckOut"), state(.checkOut), interval))
    }
    func test_2b_checkout_far_no_action() {
        XCTAssertNil(resolveAutomaticActivityForMatch(match(.outsideWorkplace), state(.checkOut), interval))
    }
    func test_3a_checkout_enters_registered_area_checks_in() {
        assertActivity(resolveAutomaticActivityForMatch(match(.matched, "P80-Portaria"), state(.checkOut), interval), .checkIn, "P80-Portaria")
    }
    func test_3b_checkout_near_but_outside_no_action() {
        XCTAssertNil(resolveAutomaticActivityForMatch(match(.notInKnownLocation), state(.checkOut), interval))
    }
    func test_4a_checkin_same_registered_area_no_action() {
        XCTAssertNil(resolveAutomaticActivityForMatch(match(.matched, "P80-Portaria"), state(.checkIn, currentLocal: "P80-Portaria"), interval))
    }
    func test_4b_checkin_different_registered_area_rechecks_in() {
        assertActivity(resolveAutomaticActivityForMatch(match(.matched, "P80-Refeitorio"), state(.checkIn, currentLocal: "P80-Portaria"), interval), .checkIn, "P80-Refeitorio")
    }
    func test_5a_checkin_near_outside_checks_in_unregistered() {
        assertActivity(resolveAutomaticActivityForMatch(match(.notInKnownLocation), state(.checkIn, currentLocal: "P80-Portaria"), interval), .checkIn, "Localização não Cadastrada")
    }
    func test_5b_checkin_already_unregistered_no_repeat() {
        XCTAssertNil(resolveAutomaticActivityForMatch(match(.notInKnownLocation), state(.checkIn, currentLocal: "Localização não Cadastrada"), interval))
    }
    func test_6a_refresh_same_area_no_action() {
        XCTAssertNil(resolveAutomaticActivityForMatch(match(.matched, "P80-Portaria"), state(.checkIn, currentLocal: "P80-Portaria"), interval))
    }
    func test_6b_refresh_different_area_rechecks_in() {
        assertActivity(resolveAutomaticActivityForMatch(match(.matched, "P80-Refeitorio"), state(.checkIn, currentLocal: "P80-Portaria"), interval), .checkIn, "P80-Refeitorio")
    }
    func test_7A_checkout_enters_registered_area_checks_in() {
        assertActivity(resolveAutomaticActivityForMatch(match(.matched, "P80-Portaria"), state(.checkOut), interval), .checkIn, "P80-Portaria")
    }
    func test_7B_checkout_near_but_outside_no_action() {
        XCTAssertNil(resolveAutomaticActivityForMatch(match(.notInKnownLocation), state(.checkOut), interval))
    }
    func test_8a_mixed_zone_last_checkin_cooldown_elapsed_checks_out() {
        let s = state(.checkIn, currentLocal: "Zona Mista", lastCheckinAt: Date().addingTimeInterval(-20 * 60))
        assertActivity(resolveAutomaticActivityForMatch(match(.matched, "Zona Mista"), s, interval), .checkOut, "Zona Mista")
    }
    func test_8b_mixed_zone_last_checkout_cooldown_elapsed_checks_in() {
        let s = state(.checkOut, currentLocal: "Zona Mista", lastCheckoutAt: Date().addingTimeInterval(-20 * 60))
        assertActivity(resolveAutomaticActivityForMatch(match(.matched, "Zona Mista"), s, interval), .checkIn, "Zona Mista")
    }
    func test_8c_mixed_zone_within_cooldown_no_action() {
        let s = state(.checkIn, currentLocal: "Zona Mista", lastCheckinAt: Date().addingTimeInterval(-5 * 60))
        XCTAssertNil(resolveAutomaticActivityForMatch(match(.matched, "Zona Mista"), s, interval))
    }
    func test_8d_mixed_zone_checkin_then_far_checks_out() {
        assertActivity(resolveAutomaticActivityForMatch(match(.outsideWorkplace), state(.checkIn, currentLocal: "Zona Mista"), interval), .checkOut, "Fora do Local de Trabalho")
    }

    // ── shouldAttemptAutomaticMixedZoneLocationEvent com referenceTime injetado ─
    private let now = iso("2026-06-16T12:00:00Z")

    func test_s8_mixed_zone_cooldown_blocks_consecutive_toggle() {
        let s = state(.checkIn, currentLocal: "Zona Mista", lastCheckinAt: now.addingTimeInterval(-5 * 60))
        let settings = MixedZoneDecisionSettings(mixedZoneIntervalMinutes: 15, referenceTime: now)
        XCTAssertFalse(shouldAttemptAutomaticMixedZoneLocationEvent(match(.matched, "Zona Mista"), s, settings))
    }
    func test_s8_mixed_zone_cooldown_expired_allows_toggle() {
        let s = state(.checkIn, currentLocal: "Zona Mista", lastCheckinAt: now.addingTimeInterval(-20 * 60))
        let settings = MixedZoneDecisionSettings(mixedZoneIntervalMinutes: 15, referenceTime: now)
        XCTAssertTrue(shouldAttemptAutomaticMixedZoneLocationEvent(match(.matched, "Zona Mista"), s, settings))
    }
    func test_s8_mixed_zone_drift_checkout_pure_within_then_after() {
        let settings = MixedZoneDecisionSettings(mixedZoneIntervalMinutes: 15, referenceTime: now)
        let within = state(.checkIn, currentLocal: "Unidade P80", lastCheckinAt: now.addingTimeInterval(-5 * 60))
        let after = state(.checkIn, currentLocal: "Unidade P80", lastCheckinAt: now.addingTimeInterval(-20 * 60))
        XCTAssertFalse(shouldAttemptAutomaticMixedZoneLocationEvent(match(.matched, "Zona Mista"), within, settings))
        XCTAssertTrue(shouldAttemptAutomaticMixedZoneLocationEvent(match(.matched, "Zona Mista"), after, settings))
    }
    func test_s8_mixed_zone_drift_checkin_pure_within_then_after() {
        let settings = MixedZoneDecisionSettings(mixedZoneIntervalMinutes: 15, referenceTime: now)
        let within = state(.checkOut, currentLocal: "Unidade P80", lastCheckoutAt: now.addingTimeInterval(-5 * 60))
        let after = state(.checkOut, currentLocal: "Unidade P80", lastCheckoutAt: now.addingTimeInterval(-20 * 60))
        XCTAssertFalse(shouldAttemptAutomaticMixedZoneLocationEvent(match(.matched, "Zona Mista"), within, settings))
        XCTAssertTrue(shouldAttemptAutomaticMixedZoneLocationEvent(match(.matched, "Zona Mista"), after, settings))
    }
    func test_s8_mixed_zone_real_incident_25_seconds_after_checkin_is_suppressed() {
        let settings = MixedZoneDecisionSettings(mixedZoneIntervalMinutes: 30, referenceTime: now)
        let stateAfterCheckin = state(
            .checkIn,
            currentLocal: "Escritório Principal",
            lastCheckinAt: now.addingTimeInterval(-25)
        )

        XCTAssertFalse(
            shouldAttemptAutomaticMixedZoneLocationEvent(
                match(.matched, "Zona Mista"),
                stateAfterCheckin,
                settings
            )
        )
    }
    func test_s8_mixed_zone_exact_cooldown_boundary_allows_toggle() {
        let settings = MixedZoneDecisionSettings(mixedZoneIntervalMinutes: 15, referenceTime: now)
        let atBoundary = state(
            .checkIn,
            currentLocal: "Unidade P80",
            lastCheckinAt: now.addingTimeInterval(-15 * 60)
        )

        XCTAssertTrue(
            shouldAttemptAutomaticMixedZoneLocationEvent(
                match(.matched, "Zona Mista"),
                atBoundary,
                settings
            )
        )
    }
    func test_s8_mixed_zone_without_previous_activity_allows_initial_checkin() {
        let noActivity = HistoryState(
            found: true, chave: "STM1", projeto: "P80", currentAction: nil, currentLocal: nil,
            hasCurrentDayCheckin: false, lastCheckinAt: nil, lastCheckoutAt: nil, transportEnabled: false
        )
        let settings = MixedZoneDecisionSettings(mixedZoneIntervalMinutes: 15, referenceTime: now)

        XCTAssertTrue(
            shouldAttemptAutomaticMixedZoneLocationEvent(
                match(.matched, "Zona Mista"),
                noActivity,
                settings
            )
        )
    }
    func test_s8_mixed_zone_branch_a_checkout_within_cooldown_remains_suppressed() {
        let settings = MixedZoneDecisionSettings(mixedZoneIntervalMinutes: 15, referenceTime: now)
        let recentCheckout = state(
            .checkOut,
            currentLocal: "Zona Mista",
            lastCheckoutAt: now.addingTimeInterval(-5 * 60)
        )

        XCTAssertFalse(
            shouldAttemptAutomaticMixedZoneLocationEvent(
                match(.matched, "Zona Mista"),
                recentCheckout,
                settings
            )
        )
    }
}
