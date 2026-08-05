import XCTest
@testable import Checking

final class BGTaskCompletionPolicyTests: XCTestCase {
    func test_approvedControlledTerminalsMapToTrue() {
        let expectedTrue: Set<EvaluationTerminalOutcome> = [
            .noKey,
            .toggleOff,
            .paused,
            .notConfigured,
            .staleContext,
            .skippedNoMovement,
            .captured,
            .bestPartial,
            .locationTimeout,
            .timeout,
            .unavailable,
            .permissionDenied,
            .accuracyTooLow,
            .networkFailure,
            .unauthorized,
            .reloginFailed,
            .httpRejected,
            .conflict,
            .noAction,
            .queuedOfflineRaw,
            .queuedOfflineDecided,
            .queuedOffline,
            .submittedCheckIn,
            .submittedCheckOut,
        ]

        for outcome in expectedTrue {
            XCTAssertTrue(
                BGTaskCompletionPolicy.success(for: completion(outcome)),
                "Expected a controlled terminal for \(outcome.rawValue)."
            )
        }
    }

    func test_expirationCancellationUnknownAndInternalFailuresMapToFalse() {
        let expectedFalse: Set<EvaluationTerminalOutcome> = [
            .expired,
            .cancelled,
            .submissionOutcomeUnknown,
            .internalFailure,
            .abandoned,
            .notAdmitted,
            .coalescedCovered,
        ]

        for outcome in expectedFalse {
            XCTAssertFalse(
                BGTaskCompletionPolicy.success(for: completion(outcome)),
                "Expected a failed system task for \(outcome.rawValue)."
            )
        }

        XCTAssertEqual(
            Set(EvaluationTerminalOutcome.allCases).subtracting(expectedFalse),
            Set(EvaluationTerminalOutcome.allCases).filter {
                BGTaskCompletionPolicy.success(for: completion($0))
            }
        )
    }

    func test_evenSuccessfulBusinessTerminalIsFalseAfterExpiration() {
        XCTAssertFalse(BGTaskCompletionPolicy.success(for: completion(
            .submittedCheckIn,
            completedBeforeExpiration: false
        )))
        XCTAssertFalse(BGTaskCompletionPolicy.success(for: completion(
            .queuedOfflineDecided,
            completedBeforeExpiration: false
        )))
    }

    func test_nonAdmittedWorkIsNeverReportedAsSuccessful() {
        XCTAssertFalse(BGTaskCompletionPolicy.success(for: EvaluationCompletion(
            evaluationID: EvaluationID(),
            outcome: .noAction,
            completedBeforeExpiration: true,
            admitted: false
        )))
    }

    private func completion(
        _ outcome: EvaluationTerminalOutcome,
        completedBeforeExpiration: Bool = true
    ) -> EvaluationCompletion {
        EvaluationCompletion(
            evaluationID: EvaluationID(),
            outcome: outcome,
            completedBeforeExpiration: completedBeforeExpiration
        )
    }
}
