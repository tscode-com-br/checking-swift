import Foundation

enum CheckUILifecycleBehavior: Sendable, Equatable {
    case legacyCompatible
    case headlessGuarded
}

/// Seleção coerente de pipeline para builds/pilotos. Não é um kill switch remoto: alterar o perfil de
/// Release exige gerar e distribuir um novo build.
public enum BackgroundReliabilityProfile: String, CaseIterable, Sendable {
    case legacyWithDiagnostics
    case candidate
    case candidateWithMovementExperiment

    public static let infoDictionaryKey = "CHECKINGBackgroundReliabilityProfile"

    /// Traduz o valor público/auditável de build para o contrato neutro consumido pelo orquestrador.
    /// O experimento de movimento nunca cria um quarto pipeline operacional implícito.
    var operationalPipeline: BackgroundAutomaticEvaluationPipeline {
        switch self {
        case .legacyWithDiagnostics:
            .legacy
        case .candidate, .candidateWithMovementExperiment:
            .candidate
        }
    }

    public var movementExperimentEnabled: Bool {
        self == .candidateWithMovementExperiment
    }

    var locationCaptureBehavior: LocationCaptureBehavior {
        switch operationalPipeline {
        case .legacy:
            .legacyCompatible
        case .candidate:
            .freshnessValidated
        }
    }

    var uiLifecycleBehavior: CheckUILifecycleBehavior {
        switch self {
        case .legacyWithDiagnostics:
            .legacyCompatible
        case .candidate, .candidateWithMovementExperiment:
            .headlessGuarded
        }
    }

    /// Parsing total e conservador. Ausência, tipo incorreto, placeholder não expandido ou valor
    /// desconhecido preservam o pipeline legado; o experimento nunca é escolhido por fallback.
    public static func resolve(configuredValue: Any?) -> BackgroundReliabilityProfile {
        guard let rawValue = configuredValue as? String,
              let profile = BackgroundReliabilityProfile(rawValue: rawValue) else {
            return .legacyWithDiagnostics
        }
        return profile
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> BackgroundReliabilityProfile {
        resolve(configuredValue: bundle.object(forInfoDictionaryKey: infoDictionaryKey))
    }
}
