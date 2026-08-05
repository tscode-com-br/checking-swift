import Foundation

/// Traduz o terminal técnico para o `success` do BackgroundTasks framework.
///
/// O booleano informa ao iOS se o trabalho terminou de forma controlada dentro do orçamento; ele não
/// representa sucesso de check-in. Falhas de negócio conhecidas continuam sendo terminais processados e
/// permanecem detalhadas exclusivamente no journal.
enum BGTaskCompletionPolicy {
    static func success(for completion: EvaluationCompletion) -> Bool {
        guard completion.admitted,
              completion.completedBeforeExpiration else { return false }

        return switch completion.outcome {
        case .expired,
             .cancelled,
             .submissionOutcomeUnknown,
             .internalFailure,
             .abandoned,
             .notAdmitted,
             .coalescedCovered:
            false

        case .noKey,
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
             .submittedCheckOut:
            true
        }
    }
}
