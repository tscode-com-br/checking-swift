import XCTest
@testable import Checking

// Port de CheckoutPreservationTest.kt (nunca dois check-outs consecutivos; ciclos).
// Ver docs/port_spec_decision_engine.md §9.3.
final class CheckoutPreservationTests: XCTestCase {

    private let interval = 15

    private func match(_ status: MatchStatus, _ resolvedLocal: String? = nil) -> LocationMatch {
        LocationMatch(matched: status == .matched, resolvedLocal: resolvedLocal, label: resolvedLocal ?? "",
                      status: status, message: "", accuracyMeters: 10.0, accuracyThresholdMeters: 50,
                      minimumCheckoutDistanceMeters: 2000, nearestWorkplaceDistanceMeters: nil)
    }
    private func checkedIn(_ local: String, at: Date? = nil) -> HistoryState {
        HistoryState(found: true, chave: "CO01", projeto: "P80", currentAction: .checkIn, currentLocal: local,
                     hasCurrentDayCheckin: true, lastCheckinAt: at ?? Date(), lastCheckoutAt: nil, transportEnabled: false)
    }
    private func checkedOut(_ local: String, at: Date? = nil) -> HistoryState {
        HistoryState(found: true, chave: "CO01", projeto: "P80", currentAction: .checkOut, currentLocal: local,
                     hasCurrentDayCheckin: false, lastCheckinAt: nil, lastCheckoutAt: at ?? Date(), transportEnabled: false)
    }
    private func apply(_ prev: HistoryState, _ activity: AutomaticActivity?) -> HistoryState {
        guard let activity = activity else { return prev }
        var s = prev
        switch activity.action {
        case .checkIn: s.currentAction = .checkIn; s.currentLocal = activity.local; s.lastCheckinAt = Date().addingTimeInterval(1); s.lastCheckoutAt = nil
        case .checkOut: s.currentAction = .checkOut; s.currentLocal = activity.local; s.lastCheckoutAt = Date().addingTimeInterval(1); s.lastCheckinAt = nil
        }
        return s
    }
    private func decide(_ m: LocationMatch, _ s: HistoryState) -> AutomaticActivity? { resolveAutomaticActivityForMatch(m, s, interval) }
    private func activity(_ a: CheckAction, _ l: String?) -> AutomaticActivity { AutomaticActivity(action: a, local: l) }

    func test_checkin_in_checkout_zone_checks_out() {
        XCTAssertEqual(decide(match(.matched, "Zona de CheckOut"), checkedIn("P80-Portaria")), activity(.checkOut, "Zona de CheckOut"))
    }
    func test_checkin_far_checks_out() {
        XCTAssertEqual(decide(match(.outsideWorkplace), checkedIn("P80-Portaria")), activity(.checkOut, "Fora do Local de Trabalho"))
    }
    func test_no_second_checkout_in_checkout_zone() {
        XCTAssertNil(decide(match(.matched, "Zona de CheckOut"), checkedOut("Zona de CheckOut")))
    }
    func test_no_second_checkout_when_far() {
        XCTAssertNil(decide(match(.outsideWorkplace), checkedOut("Fora do Local de Trabalho")))
    }
    func test_after_checkout_entering_area_checks_in() {
        XCTAssertEqual(decide(match(.matched, "P80-Portaria"), checkedOut("Zona de CheckOut")), activity(.checkIn, "P80-Portaria"))
    }
    func test_mixed_zone_checkin_toggles_to_checkout() {
        let s = checkedIn("Zona Mista", at: Date().addingTimeInterval(-20 * 60))
        XCTAssertEqual(decide(match(.matched, "Zona Mista"), s), activity(.checkOut, "Zona Mista"))
    }
    func test_mixed_zone_checkin_then_far_immediate_checkout() {
        XCTAssertEqual(decide(match(.outsideWorkplace), checkedIn("Zona Mista")), activity(.checkOut, "Fora do Local de Trabalho"))
    }
    func test_never_two_consecutive_checkouts() {
        var s = checkedIn("P80-Portaria")
        let out = decide(match(.outsideWorkplace), s)
        XCTAssertEqual(out, activity(.checkOut, "Fora do Local de Trabalho"))
        s = apply(s, out)
        XCTAssertNil(decide(match(.outsideWorkplace), s))
        XCTAssertNil(decide(match(.matched, "Zona de CheckOut"), s))
    }
    func test_after_checkout_next_action_is_checkin_then_checkout_cycle() {
        var s = checkedOut("Zona de CheckOut")
        let cin = decide(match(.matched, "P80-Portaria"), s)
        XCTAssertEqual(cin, activity(.checkIn, "P80-Portaria"))
        s = apply(s, cin)
        XCTAssertEqual(decide(match(.outsideWorkplace), s), activity(.checkOut, "Fora do Local de Trabalho"))
    }
}
