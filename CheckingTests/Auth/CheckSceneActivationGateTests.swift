import XCTest
@testable import Checking

final class CheckSceneActivationGateTests: XCTestCase {
    func test_firstActiveFromUnknownBecomesActiveExactlyOnce() {
        var gate = CheckSceneActivationGate()

        XCTAssertEqual(gate.transition(to: .active), .becameActive)
        XCTAssertEqual(gate.transition(to: .active), .unchanged)
        XCTAssertEqual(gate.currentState, .active)
    }

    func test_inactiveAndBackgroundEndAnActiveTransition() {
        for nonActiveState in [
            EvaluationApplicationState.inactive,
            EvaluationApplicationState.background
        ] {
            var gate = CheckSceneActivationGate()

            XCTAssertEqual(gate.transition(to: .active), .becameActive)
            XCTAssertEqual(gate.transition(to: nonActiveState), .becameInactive)
            XCTAssertEqual(gate.transition(to: nonActiveState), .unchanged)
            XCTAssertEqual(gate.currentState, nonActiveState)
        }
    }

    func test_nonActiveToActiveStartsANewActivation() {
        for nonActiveState in [
            EvaluationApplicationState.inactive,
            EvaluationApplicationState.background
        ] {
            var gate = CheckSceneActivationGate()

            XCTAssertEqual(gate.transition(to: nonActiveState), .unchanged)
            XCTAssertEqual(gate.transition(to: .active), .becameActive)
            XCTAssertEqual(gate.transition(to: .active), .unchanged)
        }
    }

    func test_unknownConservativelyEndsActiveAndRequiresNewActivation() {
        var activeGate = CheckSceneActivationGate()
        XCTAssertEqual(activeGate.transition(to: .active), .becameActive)
        XCTAssertEqual(activeGate.transition(to: .unknown), .becameInactive)
        XCTAssertEqual(activeGate.currentState, .unknown)
        XCTAssertEqual(activeGate.transition(to: .active), .becameActive)

        var backgroundGate = CheckSceneActivationGate()
        XCTAssertEqual(backgroundGate.transition(to: .background), .unchanged)
        XCTAssertEqual(backgroundGate.transition(to: .unknown), .unchanged)
        XCTAssertEqual(backgroundGate.currentState, .unknown)
        XCTAssertEqual(backgroundGate.transition(to: .active), .becameActive)
    }

    func test_eachRealDeactivationAllowsExactlyOneLaterActivation() {
        var gate = CheckSceneActivationGate()

        XCTAssertEqual(gate.transition(to: .active), .becameActive)
        XCTAssertEqual(gate.transition(to: .inactive), .becameInactive)
        XCTAssertEqual(gate.transition(to: .active), .becameActive)
        XCTAssertEqual(gate.transition(to: .background), .becameInactive)
        XCTAssertEqual(gate.transition(to: .active), .becameActive)
        XCTAssertEqual(gate.transition(to: .active), .unchanged)
    }
}
