import Foundation
import XCTest
@testable import Checking

final class AutomaticActivitiesEffectGuardValidityTests: XCTestCase {
    func test_currentSessionAndEvaluationPerformEffectExactlyOnce() {
        let sessionValidity = AuthSessionGenerationValidity()
        let evaluationValidity = AutomaticActivitiesEvaluationValidity()
        let sut = AutomaticActivitiesEffectGuard(
            sessionGeneration: AuthSessionGeneration(
                value: 7,
                validity: sessionValidity
            ),
            evaluationValidity: evaluationValidity
        )
        var effects = 0

        XCTAssertTrue(sut.allowsIrreversibleEffect())
        XCTAssertTrue(sut.performIfCurrent { effects += 1 })
        XCTAssertEqual(effects, 1)
    }

    func test_invalidatedSessionRejectsEffectEvenWhenEvaluationRemainsCurrent() {
        let sessionValidity = AuthSessionGenerationValidity()
        let evaluationValidity = AutomaticActivitiesEvaluationValidity()
        let sut = AutomaticActivitiesEffectGuard(
            sessionGeneration: AuthSessionGeneration(
                value: 7,
                validity: sessionValidity
            ),
            evaluationValidity: evaluationValidity
        )
        sessionValidity.invalidate()
        var effects = 0

        XCTAssertFalse(sut.allowsIrreversibleEffect())
        XCTAssertFalse(sut.performIfCurrent { effects += 1 })
        XCTAssertEqual(effects, 0)
        XCTAssertTrue(evaluationValidity.isCurrentNow)
    }

    func test_invalidatedEvaluationRejectsEffectEvenWhenSessionRemainsCurrent() {
        let sessionValidity = AuthSessionGenerationValidity()
        let evaluationValidity = AutomaticActivitiesEvaluationValidity()
        let sut = AutomaticActivitiesEffectGuard(
            sessionGeneration: AuthSessionGeneration(
                value: 7,
                validity: sessionValidity
            ),
            evaluationValidity: evaluationValidity
        )
        evaluationValidity.invalidate()
        var effects = 0

        XCTAssertFalse(sut.allowsIrreversibleEffect())
        XCTAssertFalse(sut.performIfCurrent { effects += 1 })
        XCTAssertEqual(effects, 0)
        XCTAssertTrue(sessionValidity.isCurrentNow)
    }

    func test_legacyClosureAndUnrestrictedGuardsRemainCompatible() {
        var legacyEffects = 0
        let rejected = AutomaticActivitiesEffectGuard(
            operationIsCurrent: { false }
        )

        XCTAssertFalse(rejected.performIfCurrent { legacyEffects += 1 })
        XCTAssertEqual(legacyEffects, 0)

        XCTAssertTrue(
            AutomaticActivitiesEffectGuard.unrestricted.performIfCurrent {
                legacyEffects += 1
            }
        )
        XCTAssertEqual(legacyEffects, 1)
    }
}
