import Foundation

/// Resultado do motor automático — port de RunAutomaticActivitiesUseCase.AutoActivitiesResult.
enum AutoActivitiesResult: Sendable, Equatable {
    case submitted(action: CheckAction, local: String?, newState: HistoryState)
    /// A API recusou o match porque o fix excedeu o limite do projeto. A ação esperada só é conhecida
    /// quando não há atividade anterior ou a última atividade foi check-out; após check-in, a localização
    /// precisa é necessária para distinguir check-out, permanência ou mudança de área.
    case accuracyTooLow(expectedAction: CheckAction?)
    /// Timeout é separado de falta de permissão para que um episódio de baixa precisão já aberto possa
    /// continuar tentando, sem criar um episódio novo a partir de uma captura que não produziu fix.
    case locationTimeout
    case noPermission
    case noAction
    case networkError
    case notConfigured
}
