import XCTest
@testable import Checking

// Port de AutoActivitiesTest.kt — funções-helper puras. Ver docs/port_spec_decision_engine.md §9.2.
final class AutoActivitiesHelpersTests: XCTestCase {

    private let t0 = iso("2024-01-01T08:00:00Z")
    private let t1 = iso("2024-01-01T09:00:00Z")
    private let t2 = iso("2024-01-01T10:00:00Z")
    private var defaultSettings: MixedZoneDecisionSettings { MixedZoneDecisionSettings(mixedZoneIntervalMinutes: 30) }

    private func checkedInState(_ local: String = "Office A", lastCheckinAt: Date? = nil, lastCheckoutAt: Date? = nil) -> HistoryState {
        HistoryState(found: true, chave: "TEST", projeto: nil, currentAction: .checkIn, currentLocal: local,
                     hasCurrentDayCheckin: true, lastCheckinAt: lastCheckinAt ?? t1, lastCheckoutAt: lastCheckoutAt, transportEnabled: false)
    }
    private func checkedOutState(_ local: String? = nil, lastCheckinAt: Date? = nil, lastCheckoutAt: Date? = nil) -> HistoryState {
        HistoryState(found: true, chave: "TEST", projeto: nil, currentAction: .checkOut, currentLocal: local,
                     hasCurrentDayCheckin: true, lastCheckinAt: lastCheckinAt ?? t0, lastCheckoutAt: lastCheckoutAt ?? t1, transportEnabled: false)
    }
    private func firstRegistrationState() -> HistoryState {
        HistoryState(found: true, chave: "TEST", projeto: nil, currentAction: nil, currentLocal: nil,
                     hasCurrentDayCheckin: false, lastCheckinAt: nil, lastCheckoutAt: nil, transportEnabled: false)
    }
    private func matched(_ local: String = "Office A") -> LocationMatch {
        LocationMatch(matched: true, resolvedLocal: local, label: local, status: .matched, message: "",
                      accuracyMeters: 15.0, accuracyThresholdMeters: 30, minimumCheckoutDistanceMeters: 500, nearestWorkplaceDistanceMeters: nil)
    }
    private func outsideWorkplace(_ nearestM: Double = 1000.0) -> LocationMatch {
        LocationMatch(matched: false, resolvedLocal: nil, label: "Outside", status: .outsideWorkplace, message: "",
                      accuracyMeters: 15.0, accuracyThresholdMeters: 30, minimumCheckoutDistanceMeters: 500, nearestWorkplaceDistanceMeters: nearestM)
    }

    // ── resolveLastRecordedAction ──
    func test_resolveLastRecordedAction_noBothTimestamps_returnsCurrentAction() {
        let s = HistoryState(found: true, chave: "T", projeto: nil, currentAction: .checkIn, currentLocal: nil,
                             hasCurrentDayCheckin: true, lastCheckinAt: nil, lastCheckoutAt: nil, transportEnabled: false)
        XCTAssertEqual(resolveLastRecordedAction(s), .checkIn)
    }
    func test_resolveLastRecordedAction_onlyCheckinTimestamp_returnsCheckin() {
        XCTAssertEqual(resolveLastRecordedAction(checkedInState()), .checkIn)
    }
    func test_resolveLastRecordedAction_checkinNewerThanCheckout_returnsCheckin() {
        XCTAssertEqual(resolveLastRecordedAction(checkedInState(lastCheckinAt: t2, lastCheckoutAt: t1)), .checkIn)
    }
    func test_resolveLastRecordedAction_checkoutNewerThanCheckin_returnsCheckout() {
        XCTAssertEqual(resolveLastRecordedAction(checkedOutState(lastCheckinAt: t1, lastCheckoutAt: t2)), .checkOut)
    }
    func test_resolveLastRecordedAction_nullState_returnsNull() {
        XCTAssertNil(resolveLastRecordedAction(nil))
    }

    // ── shouldAttemptAutomaticOutOfRangeCheckout ──
    func test_outOfRangeCheckout_checkedIn_returnsTrue() { XCTAssertTrue(shouldAttemptAutomaticOutOfRangeCheckout(outsideWorkplace(), checkedInState())) }
    func test_outOfRangeCheckout_checkedOut_returnsFalse() { XCTAssertFalse(shouldAttemptAutomaticOutOfRangeCheckout(outsideWorkplace(), checkedOutState())) }
    func test_outOfRangeCheckout_firstRegistration_returnsFalse() { XCTAssertFalse(shouldAttemptAutomaticOutOfRangeCheckout(outsideWorkplace(), firstRegistrationState())) }
    func test_outOfRangeCheckout_matchedLocation_returnsFalse() { XCTAssertFalse(shouldAttemptAutomaticOutOfRangeCheckout(matched(), checkedInState())) }
    func test_outOfRangeCheckout_nullMatch_returnsFalse() { XCTAssertFalse(shouldAttemptAutomaticOutOfRangeCheckout(nil, checkedInState())) }

    // ── shouldAttemptAutomaticLocationEvent ──
    func test_locationEvent_checkoutZone_checkedIn_returnsTrue() { XCTAssertTrue(shouldAttemptAutomaticLocationEvent(matched("Zona de Checkout"), checkedInState(), defaultSettings)) }
    func test_locationEvent_checkoutZone_checkedOut_returnsFalse() { XCTAssertFalse(shouldAttemptAutomaticLocationEvent(matched("Zona de Checkout"), checkedOutState(), defaultSettings)) }
    func test_locationEvent_regularLocation_checkedOut_returnsTrue() { XCTAssertTrue(shouldAttemptAutomaticLocationEvent(matched("Office A"), checkedOutState(), defaultSettings)) }
    func test_locationEvent_regularLocation_firstRegistration_returnsTrue() { XCTAssertTrue(shouldAttemptAutomaticLocationEvent(matched("Office A"), firstRegistrationState(), defaultSettings)) }
    func test_locationEvent_regularLocation_checkedIn_returnsTrue() { XCTAssertTrue(shouldAttemptAutomaticLocationEvent(matched("Office B"), checkedInState("Office A"), defaultSettings)) }
    func test_locationEvent_nullMatch_checkedIn_returnsFalse() { XCTAssertFalse(shouldAttemptAutomaticLocationEvent(nil, checkedInState(), defaultSettings)) }
    func test_locationEvent_nullMatch_checkedOut_returnsTrue() { XCTAssertTrue(shouldAttemptAutomaticLocationEvent(nil, checkedOutState(), defaultSettings)) }

    // ── resolveAutomaticLocationAction ──
    func test_locationAction_checkoutZone_returnsCheckout() { XCTAssertEqual(resolveAutomaticLocationAction(matched("Zona de Checkout"), checkedInState()), .checkOut) }
    func test_locationAction_regularZone_returnsCheckin() { XCTAssertEqual(resolveAutomaticLocationAction(matched("Office A"), checkedOutState()), .checkIn) }
    func test_locationAction_mixedZone_checkedIn_returnsCheckout() { XCTAssertEqual(resolveAutomaticLocationAction(matched("Zona Mista"), checkedInState()), .checkOut) }
    func test_locationAction_mixedZone_checkedOut_returnsCheckin() { XCTAssertEqual(resolveAutomaticLocationAction(matched("Zona Mista"), checkedOutState()), .checkIn) }

    // ── isMixedZoneCooldownActive ──
    func test_mixedZoneCooldown_withinWindow_returnsTrue() {
        let s = HistoryState(found: true, chave: "T", projeto: nil, currentAction: .checkIn, currentLocal: "Zona Mista",
                             hasCurrentDayCheckin: true, lastCheckinAt: t1, lastCheckoutAt: nil, transportEnabled: false)
        XCTAssertTrue(isMixedZoneCooldownActive(s, 30, t1.addingTimeInterval(20 * 60)))
    }
    func test_mixedZoneCooldown_afterWindow_returnsFalse() {
        let s = HistoryState(found: true, chave: "T", projeto: nil, currentAction: .checkIn, currentLocal: "Zona Mista",
                             hasCurrentDayCheckin: true, lastCheckinAt: t1, lastCheckoutAt: nil, transportEnabled: false)
        XCTAssertFalse(isMixedZoneCooldownActive(s, 30, t1.addingTimeInterval(40 * 60)))
    }
    func test_mixedZoneCooldown_notInMixedZone_returnsFalse() { XCTAssertFalse(isMixedZoneCooldownActive(checkedInState("Office A"), 30)) }
    func test_mixedZoneCooldown_zeroCooldown_returnsFalse() { XCTAssertFalse(isMixedZoneCooldownActive(checkedInState("Zona Mista"), 0)) }

    // ── temp006: cooldown da última atividade em qualquer localização ──
    func test_resolveLastRecordedActivityTimestamp_returnsLatestCheckinTimestamp() {
        XCTAssertEqual(
            resolveLastRecordedActivityTimestamp(checkedInState(lastCheckinAt: t2, lastCheckoutAt: t1)),
            t2
        )
    }
    func test_resolveLastRecordedActivityTimestamp_returnsLatestCheckoutTimestamp() {
        XCTAssertEqual(
            resolveLastRecordedActivityTimestamp(checkedOutState(lastCheckinAt: t1, lastCheckoutAt: t2)),
            t2
        )
    }
    func test_resolveLastRecordedActivityTimestamp_withoutRecordedTimestamp_returnsNil() {
        let state = HistoryState(
            found: true, chave: "T", projeto: nil, currentAction: .checkIn, currentLocal: "Office A",
            hasCurrentDayCheckin: true, lastCheckinAt: nil, lastCheckoutAt: nil, transportEnabled: false
        )
        XCTAssertNil(resolveLastRecordedActivityTimestamp(state))
    }
    func test_mixedZoneCooldownForLastActivity_withinWindow_returnsTrue() {
        XCTAssertTrue(isMixedZoneCooldownActiveForLastActivity(
            checkedInState("Office A", lastCheckinAt: t1),
            30,
            t1.addingTimeInterval(20 * 60)
        ))
    }
    func test_mixedZoneCooldownForLastActivity_afterWindow_returnsFalse() {
        XCTAssertFalse(isMixedZoneCooldownActiveForLastActivity(
            checkedOutState("Zona de CheckOut", lastCheckoutAt: t1),
            30,
            t1.addingTimeInterval(40 * 60)
        ))
    }
    func test_mixedZoneCooldownForLastActivity_atExactBoundary_returnsFalse() {
        XCTAssertFalse(isMixedZoneCooldownActiveForLastActivity(
            checkedInState("Office A", lastCheckinAt: t1),
            30,
            t1.addingTimeInterval(30 * 60)
        ))
    }
    func test_mixedZoneCooldownForLastActivity_invalidInterval_returnsFalse() {
        XCTAssertFalse(isMixedZoneCooldownActiveForLastActivity(checkedInState(), 0, t1))
    }
    func test_mixedZoneCooldownForLastActivity_withoutTimestamp_returnsFalse() {
        let state = HistoryState(
            found: true, chave: "T", projeto: nil, currentAction: .checkOut, currentLocal: "Office A",
            hasCurrentDayCheckin: false, lastCheckinAt: nil, lastCheckoutAt: nil, transportEnabled: false
        )
        XCTAssertFalse(isMixedZoneCooldownActiveForLastActivity(state, 30, t1))
    }

    // ── normalizeLocationName / isCheckoutZone / isMixedZone ──
    func test_normalizeLocationName_trimsCaseAndExtraSpaces() { XCTAssertEqual(normalizeLocationName("  Zona  Mista  "), "zona mista") }
    func test_normalizeLocationName_nullReturnsEmpty() { XCTAssertEqual(normalizeLocationName(nil), "") }
    func test_isCheckoutZoneLocationName_matchesCaseInsensitive() {
        XCTAssertTrue(isCheckoutZoneLocationName("ZONA DE CHECKOUT"))
        XCTAssertTrue(isCheckoutZoneLocationName("Zona de Checkout"))
        XCTAssertFalse(isCheckoutZoneLocationName("Office A"))
    }
    func test_isMixedZoneLocationName_matchesCaseInsensitive() {
        XCTAssertTrue(isMixedZoneLocationName("ZONA MISTA"))
        XCTAssertTrue(isMixedZoneLocationName("Zona Mista"))
        XCTAssertFalse(isMixedZoneLocationName("Office A"))
    }
}
