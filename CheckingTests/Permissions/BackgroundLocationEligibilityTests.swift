import XCTest
@testable import Checking

final class BackgroundLocationEligibilityTests: XCTestCase {
    private func input(
        validContext: Bool = true,
        automatic: Bool = true,
        activeProject: Bool = true,
        consent: Bool = true,
        authorization: LocationAuthorization = .always,
        precise: Bool = true,
        locationServicesEnabled: Bool = true,
        backgroundRefresh: BackgroundRefreshAvailability = .available,
        lowPowerMode: Bool = false
    ) -> BackgroundLocationEligibilityInput {
        BackgroundLocationEligibilityInput(
            hasValidAccountContext: validContext,
            automaticActivitiesEnabled: automatic,
            hasActiveProject: activeProject,
            hasBackgroundLocationConsent: consent,
            locationAuthorization: authorization,
            preciseAccuracy: precise,
            locationServicesEnabled: locationServicesEnabled,
            backgroundRefresh: backgroundRefresh,
            lowPowerMode: lowPowerMode
        )
    }

    func test_alwaysPreciseWithValidBusinessGatesIsOperationalAndReadyForCoreLocation() {
        let result = BackgroundLocationEligibility.evaluate(input())

        XCTAssertEqual(result.state, .operational)
        XCTAssertTrue(result.canEvaluateInForeground)
        XCTAssertEqual(result.nativeBackgroundReadiness, .readyForCoreLocation)
        XCTAssertEqual(result.blockingReasons, [])
        XCTAssertEqual(result.degradationReasons, [])
        XCTAssertEqual(result.timerBackgroundSignal, .available)
        XCTAssertEqual(result.lowPowerSignal, .normal)
    }

    func test_whenInUsePreciseIsForegroundOnlyWithoutChangingTheBusinessEligibility() {
        let result = BackgroundLocationEligibility.evaluate(input(authorization: .whenInUse))

        XCTAssertEqual(result.state, .foregroundOnly)
        XCTAssertTrue(result.canEvaluateInForeground)
        XCTAssertEqual(result.nativeBackgroundReadiness, .notReady)
        XCTAssertEqual(result.blockingReasons, [])
        XCTAssertEqual(result.degradationReasons, [.whenInUseAuthorization])
    }

    func test_businessGatesBlockWithDeterministicTypedReasons() {
        let cases: [(String, BackgroundLocationEligibilityInput, BackgroundLocationEligibility.BlockingReason)] = [
            ("context", input(validContext: false), .invalidAccountContext),
            ("automatic", input(automatic: false), .automaticActivitiesDisabled),
            ("project", input(activeProject: false), .missingActiveProject),
            ("consent", input(consent: false), .missingBackgroundLocationConsent),
        ]

        for (name, candidate, reason) in cases {
            let result = BackgroundLocationEligibility.evaluate(candidate)
            XCTAssertEqual(result.state, .blocked, name)
            XCTAssertFalse(result.canEvaluateInForeground, name)
            XCTAssertEqual(result.nativeBackgroundReadiness, .notReady, name)
            XCTAssertEqual(result.blockingReasons, [reason], name)
        }
    }

    func test_locationBlockersAreTyped() {
        let cases: [(String, BackgroundLocationEligibilityInput, BackgroundLocationEligibility.BlockingReason)] = [
            ("services", input(locationServicesEnabled: false), .locationServicesDisabled),
            ("not determined", input(authorization: .notDetermined), .locationAuthorizationNotDetermined),
            ("denied", input(authorization: .denied), .locationAuthorizationDenied),
            ("reduced", input(authorization: .always, precise: false), .reducedAccuracy),
        ]

        for (name, candidate, reason) in cases {
            let result = BackgroundLocationEligibility.evaluate(candidate)
            XCTAssertEqual(result.state, .blocked, name)
            XCTAssertFalse(result.canEvaluateInForeground, name)
            XCTAssertEqual(result.nativeBackgroundReadiness, .notReady, name)
            XCTAssertEqual(result.blockingReasons, [reason], name)
        }
    }

    func test_backgroundRefreshOnlyDegradesTimerAndDoesNotRemoveNativeReadiness() {
        let cases: [(BackgroundRefreshAvailability, BackgroundLocationEligibility.TimerBackgroundSignal, BackgroundLocationEligibility.DegradationReason)] = [
            (.denied, .degradedDenied, .backgroundRefreshDenied),
            (.restricted, .degradedRestricted, .backgroundRefreshRestricted),
        ]

        for (availability, timerSignal, reason) in cases {
            let result = BackgroundLocationEligibility.evaluate(input(backgroundRefresh: availability))
            XCTAssertEqual(result.state, .operational)
            XCTAssertTrue(result.canEvaluateInForeground)
            XCTAssertEqual(result.nativeBackgroundReadiness, .readyForCoreLocation)
            XCTAssertEqual(result.timerBackgroundSignal, timerSignal)
            XCTAssertEqual(result.degradationReasons, [reason])
        }
    }

    func test_lowPowerIsOnlyAWarning() {
        let result = BackgroundLocationEligibility.evaluate(input(lowPowerMode: true))

        XCTAssertEqual(result.state, .operational)
        XCTAssertTrue(result.canEvaluateInForeground)
        XCTAssertEqual(result.nativeBackgroundReadiness, .readyForCoreLocation)
        XCTAssertEqual(result.lowPowerSignal, .warning)
        XCTAssertEqual(result.degradationReasons, [.lowPowerMode])
    }

    func test_cartesianMatrixKeepsBusinessNativeAndTimerSignalsIndependent() {
        let authorizations: [LocationAuthorization] = [.notDetermined, .denied, .whenInUse, .always]
        let backgroundRefreshes: [BackgroundRefreshAvailability] = [.available, .denied, .restricted]

        for validContext in [false, true] {
            for automatic in [false, true] {
                for activeProject in [false, true] {
                    for consent in [false, true] {
                        for locationServicesEnabled in [false, true] {
                            for authorization in authorizations {
                                for precise in [false, true] {
                                    for backgroundRefresh in backgroundRefreshes {
                                        for lowPowerMode in [false, true] {
                                            let candidate = input(
                                                validContext: validContext,
                                                automatic: automatic,
                                                activeProject: activeProject,
                                                consent: consent,
                                                authorization: authorization,
                                                precise: precise,
                                                locationServicesEnabled: locationServicesEnabled,
                                                backgroundRefresh: backgroundRefresh,
                                                lowPowerMode: lowPowerMode
                                            )
                                            let result = BackgroundLocationEligibility.evaluate(candidate)
                                            let businessReady = validContext && automatic && activeProject && consent
                                            let locationReady = locationServicesEnabled
                                                && precise
                                                && (authorization == .whenInUse || authorization == .always)

                                            if !businessReady || !locationReady {
                                                XCTAssertEqual(result.state, .blocked)
                                                XCTAssertFalse(result.canEvaluateInForeground)
                                                XCTAssertEqual(result.nativeBackgroundReadiness, .notReady)
                                            } else if authorization == .whenInUse {
                                                XCTAssertEqual(result.state, .foregroundOnly)
                                                XCTAssertTrue(result.canEvaluateInForeground)
                                                XCTAssertEqual(result.nativeBackgroundReadiness, .notReady)
                                            } else {
                                                XCTAssertEqual(result.state, .operational)
                                                XCTAssertTrue(result.canEvaluateInForeground)
                                                XCTAssertEqual(result.nativeBackgroundReadiness, .readyForCoreLocation)
                                            }

                                            let expectedTimer: BackgroundLocationEligibility.TimerBackgroundSignal = switch backgroundRefresh {
                                            case .available: .available
                                            case .denied: .degradedDenied
                                            case .restricted: .degradedRestricted
                                            }
                                            XCTAssertEqual(result.timerBackgroundSignal, expectedTimer)
                                            XCTAssertEqual(result.lowPowerSignal, lowPowerMode ? .warning : .normal)
                                            XCTAssertEqual(result, BackgroundLocationEligibility.evaluate(candidate))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func test_evaluationIsDeterministicWithoutUIOrGlobalState() {
        let operational = input()
        let blocked = input(validContext: false, authorization: .denied, backgroundRefresh: .restricted)

        let first = BackgroundLocationEligibility.evaluate(operational)
        _ = BackgroundLocationEligibility.evaluate(blocked)
        let second = BackgroundLocationEligibility.evaluate(operational)

        XCTAssertEqual(first, second)
    }
}
