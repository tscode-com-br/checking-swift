import Foundation

/// Origem em memória da amostra. Não identifica região, local, projeto ou usuário.
enum LocationSampleSource: Sendable, Equatable {
    case standardCapture
    case significantChange
}

/// Valor de domínio neutro de plataforma. A conversão de `CLLocation.timestamp` ocorre somente na
/// fronteira Platform do driver Core Location.
struct LocationSample: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyMeters: Double
    let capturedAt: Date
    let source: LocationSampleSource
}

/// Falhas operacionais da aquisição, separando timeout de cancelamento cooperativo.
enum LocationAcquisitionFailure: Sendable, Equatable {
    case timeout
    case unavailable
    case permissionDenied
    case cancelled(EvaluationCancellationReason)
}

enum EvaluationCancellationReason: Sendable, Equatable {
    case bgTaskExpired
    case uiBackgroundTimeExpired
    case contextInvalidated
    case taskCancelled
}
