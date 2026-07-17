import XCTest
@testable import Checking

// Port de LocationChangeContinuationTest.kt (change A/P6.1 + continuação P6.2).
// Ver docs/port_spec_decision_engine.md §9.3.
final class LocationChangeContinuationTests: XCTestCase {

    private let interval = 15
    private let base = iso("2026-06-18T08:00:00Z")
    private var tick = 0
    // Relógio monotônico (nenhum caso usa Zona Mista, então só a ordem importa).
    private func advance() -> Date { tick += 1; return base.addingTimeInterval(Double(tick * 60)) }

    private func match(_ status: MatchStatus, _ resolvedLocal: String? = nil) -> LocationMatch {
        LocationMatch(matched: status == .matched, resolvedLocal: resolvedLocal, label: resolvedLocal ?? "",
                      status: status, message: "", accuracyMeters: 10.0, accuracyThresholdMeters: 50,
                      minimumCheckoutDistanceMeters: 2000, nearestWorkplaceDistanceMeters: nil)
    }
    private func checkedIn(_ local: String, at: Date? = nil) -> HistoryState {
        HistoryState(found: true, chave: "TP2X", projeto: "P80", currentAction: .checkIn, currentLocal: local,
                     hasCurrentDayCheckin: true, lastCheckinAt: at ?? advance(), lastCheckoutAt: nil, transportEnabled: false)
    }
    private func checkedOut(_ local: String, at: Date? = nil) -> HistoryState {
        HistoryState(found: true, chave: "TP2X", projeto: "P80", currentAction: .checkOut, currentLocal: local,
                     hasCurrentDayCheckin: false, lastCheckinAt: nil, lastCheckoutAt: at ?? advance(), transportEnabled: false)
    }
    private func apply(_ prev: HistoryState, _ activity: AutomaticActivity?) -> HistoryState {
        guard let activity = activity else { return prev }
        var s = prev
        switch activity.action {
        case .checkIn: s.currentAction = .checkIn; s.currentLocal = activity.local; s.lastCheckinAt = advance(); s.hasCurrentDayCheckin = true
        case .checkOut: s.currentAction = .checkOut; s.currentLocal = activity.local; s.lastCheckoutAt = advance()
        }
        return s
    }
    private func decide(_ m: LocationMatch, _ s: HistoryState) -> AutomaticActivity? {
        resolveAutomaticActivityForMatch(m, s, interval)
    }
    private func activity(_ a: CheckAction, _ l: String?) -> AutomaticActivity { AutomaticActivity(action: a, local: l) }

    func test_repeated_identical_matched_reads_check_in_only_once() {
        var s = checkedIn("P80-Refeitorio")
        let r1 = decide(match(.matched, "P80-Portaria"), s)
        XCTAssertEqual(r1, activity(.checkIn, "P80-Portaria"))
        s = apply(s, r1)
        XCTAssertNil(decide(match(.matched, "P80-Portaria"), s))
        XCTAssertNil(decide(match(.matched, "P80-Portaria"), s))
    }
    func test_only_the_move_to_a_new_area_checks_in() {
        let s = checkedIn("P80-Portaria")
        XCTAssertNil(decide(match(.matched, "P80-Portaria"), s))
        XCTAssertEqual(decide(match(.matched, "P80-Refeitorio"), s), activity(.checkIn, "P80-Refeitorio"))
    }
    func test_not_in_known_location_continuation_cycle() {
        var s = checkedIn("P80-Portaria")
        let r1 = decide(match(.notInKnownLocation), s)
        XCTAssertEqual(r1, activity(.checkIn, "Localização não Cadastrada"))
        s = apply(s, r1)
        XCTAssertNil(decide(match(.notInKnownLocation), s))
        XCTAssertEqual(decide(match(.matched, "P80-Portaria"), s), activity(.checkIn, "P80-Portaria"))
    }
    func test_checkout_then_not_in_known_location_no_action() {
        XCTAssertNil(decide(match(.notInKnownLocation), checkedOut("Zona de CheckOut")))
    }
    func test_accuracy_too_low_is_always_null() {
        XCTAssertNil(decide(match(.accuracyTooLow), checkedIn("P80-Portaria")))
        XCTAssertNil(decide(match(.accuracyTooLow), checkedOut("Zona de CheckOut")))
    }
    func test_no_known_locations_is_always_null() {
        XCTAssertNil(decide(match(.noKnownLocations), checkedIn("P80-Portaria")))
        XCTAssertNil(decide(match(.noKnownLocations), checkedOut("Zona de CheckOut")))
    }
}
