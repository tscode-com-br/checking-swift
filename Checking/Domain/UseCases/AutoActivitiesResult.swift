import Foundation

/// Resultado do motor automático — port de RunAutomaticActivitiesUseCase.AutoActivitiesResult.
enum AutoActivitiesResult: Sendable, Equatable {
    case submitted(action: CheckAction, local: String?, newState: HistoryState)
    case noAction
    case networkError
    case notConfigured
}
