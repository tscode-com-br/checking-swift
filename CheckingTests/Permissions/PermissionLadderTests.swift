import XCTest
@testable import Checking

/// Port dos predicados puros da escada (PermissionLadder.kt) — obrigações de teste da spec §9. O Kotlin não
/// tem teste dedicado (só `EvaluationLogDialogSmokeTest` de instrumentação), então estes são novos.
final class PermissionLadderTests: XCTestCase {

    private func ladder(_ n: Bool, _ p: Bool, _ a: Bool) -> PermissionLadderStatus {
        PermissionLadderStatus(notificationsGranted: n, preciseLocationGranted: p, alwaysLocationGranted: a)
    }

    // MARK: minimumToStartGranted (D5)

    func test_minimumToStart_needsNotificationsAndPrecise() {
        XCTAssertTrue(ladder(true, true, false).minimumToStartGranted)   // Always ausente NÃO afeta o mínimo
        XCTAssertTrue(ladder(true, true, true).minimumToStartGranted)
    }

    func test_minimumToStart_falseIfEitherMissing() {
        XCTAssertFalse(ladder(false, true, true).minimumToStartGranted)  // sem notificações
        XCTAssertFalse(ladder(true, false, true).minimumToStartGranted)  // sem precisa
        XCTAssertFalse(ladder(false, false, false).minimumToStartGranted)
    }

    func test_minimumToStart_alwaysDoesNotAffect() {
        // O mínimo é idêntico com e sem "Always" (a única diferença é o 3º arg).
        XCTAssertEqual(ladder(true, true, false).minimumToStartGranted,
                       ladder(true, true, true).minimumToStartGranted)
    }

    // MARK: allRecommendedGranted

    func test_allRecommended_onlyTrueWithAllThree() {
        XCTAssertTrue(ladder(true, true, true).allRecommendedGranted)
        XCTAssertFalse(ladder(true, true, false).allRecommendedGranted)   // falta Always
        XCTAssertFalse(ladder(true, false, true).allRecommendedGranted)
        XCTAssertFalse(ladder(false, true, true).allRecommendedGranted)
    }

    // MARK: nextStep (ordem)

    func test_nextStep_ordersNotificationsFirst() {
        XCTAssertEqual(ladder(false, false, false).nextStep, .notifications)
        XCTAssertEqual(ladder(false, true, true).nextStep, .notifications)
    }

    func test_nextStep_thenPreciseLocation() {
        XCTAssertEqual(ladder(true, false, false).nextStep, .preciseLocation)
        XCTAssertEqual(ladder(true, false, true).nextStep, .preciseLocation)
    }

    func test_nextStep_thenAlwaysLocation() {
        XCTAssertEqual(ladder(true, true, false).nextStep, .alwaysLocation)
    }

    func test_nextStep_nilWhenAllGranted() {
        XCTAssertNil(ladder(true, true, true).nextStep)
    }
}
