import Foundation

/// Estágio máximo alcançado pelo motor automático. Este tipo é somente memória e deliberadamente separado
/// do schema persistido do journal; o mapeamento durável pertence à integração do Prompt 08.
enum AutomaticActivitiesStage: Int, Sendable, Equatable {
    case started
    case admitted
    case captureStarted
    case captured
    case matched
    case decisionCompleted
    case submitStarted
    case submitted

    static func furthest(_ lhs: Self, _ rhs: Self) -> Self {
        lhs.rawValue >= rhs.rawValue ? lhs : rhs
    }
}

/// Origem operacional sanitizável da amostra usada pela avaliação.
enum AutomaticCaptureSource: Sendable, Equatable {
    case freshCapture
    case seed
    case bestPartial
}

/// Qualidade grosseira, sem coordenadas nem métricas livres.
enum AutomaticCaptureQuality: Sendable, Equatable {
    case usable
    case coarse
    case rejected(LocationSampleValidity)
}

/// Buckets somente em memória. A camada Platform os converte explicitamente para o schema persistido;
/// manter tipos separados impede que o Domain passe a depender dos modelos `Codable` do journal.
enum AutomaticCaptureAccuracyBucket: Sendable, Equatable {
    case zeroTo10Meters
    case elevenTo25Meters
    case twentySixTo50Meters
    case fiftyOneTo100Meters
    case over100Meters
    case unknown

    static func classify(meters: Double?) -> Self {
        guard let meters, meters.isFinite, meters >= 0 else { return .unknown }
        return switch meters {
        case ...10: .zeroTo10Meters
        case ...25: .elevenTo25Meters
        case ...50: .twentySixTo50Meters
        case ...100: .fiftyOneTo100Meters
        default: .over100Meters
        }
    }
}

enum AutomaticCaptureAgeBucket: Sendable, Equatable {
    case under1Second
    case oneTo5Seconds
    case sixTo15Seconds
    case over15Seconds
    case unknown

    static func classify(seconds: TimeInterval?) -> Self {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return .unknown }
        return switch seconds {
        case ..<1: .under1Second
        case ...5: .oneTo5Seconds
        case ...15: .sixTo15Seconds
        default: .over15Seconds
        }
    }
}

/// Metadados de captura estritamente sanitizáveis. A origem física não identifica região, local ou usuário.
struct AutomaticCaptureTrace: Sendable, Equatable {
    let source: AutomaticCaptureSource
    let physicalSource: LocationSampleSource
    let reused: Bool
    let quality: AutomaticCaptureQuality
    let accuracyBucket: AutomaticCaptureAccuracyBucket
    let ageBucket: AutomaticCaptureAgeBucket

    init(
        source: AutomaticCaptureSource,
        physicalSource: LocationSampleSource,
        reused: Bool,
        quality: AutomaticCaptureQuality,
        accuracyBucket: AutomaticCaptureAccuracyBucket = .unknown,
        ageBucket: AutomaticCaptureAgeBucket = .unknown
    ) {
        self.source = source
        self.physicalSource = physicalSource
        self.reused = reused
        self.quality = quality
        self.accuracyBucket = accuracyBucket
        self.ageBucket = ageBucket
    }

    func markingReused() -> Self {
        Self(
            source: source,
            physicalSource: physicalSource,
            reused: true,
            quality: quality,
            accuracyBucket: accuracyBucket,
            ageBucket: ageBucket
        )
    }
}

/// Falha enriquecida do chokepoint captura/match. `LocationCaptureResult` permanece como fachada legada.
enum LocationCaptureExecutionFailure: Sendable, Equatable {
    case acquisition(LocationAcquisitionFailure)
    case sampleRejected(LocationSampleValidity)
    case match(ApiError)
    case cancelled(EvaluationCancellationReason)
}

/// Envelope em memória que impede a perda do `ApiError` antes de o motor automático recebê-lo.
struct LocationCaptureExecution: Sendable, Equatable {
    let result: LocationCaptureResult
    let maximumStage: AutomaticActivitiesStage
    let capture: AutomaticCaptureTrace?
    let failure: LocationCaptureExecutionFailure?
    /// A única amostra que pode voltar ao matcher depois de um refresh de sessão. Existe somente em
    /// memória, exclusivamente para `.match(.unauthorized)`, e deliberadamente não adota `Codable` nem
    /// participa do trace sanitizável. Qualquer retry ainda precisa passar por `.finalSample`, que revalida
    /// integridade/frescor e não abre orçamento para o provider.
    let retryableMatchSample: LocationSample?

    init(
        result: LocationCaptureResult,
        maximumStage: AutomaticActivitiesStage,
        capture: AutomaticCaptureTrace?,
        failure: LocationCaptureExecutionFailure?,
        retryableMatchSample: LocationSample? = nil
    ) {
        self.result = result
        self.maximumStage = maximumStage
        self.capture = capture
        self.failure = failure
        self.retryableMatchSample = retryableMatchSample
    }

    func markingCaptureReused() -> Self {
        Self(
            result: result,
            maximumStage: maximumStage,
            capture: capture?.markingReused(),
            failure: failure,
            retryableMatchSample: retryableMatchSample
        )
    }

    static func cancelled(
        at stage: AutomaticActivitiesStage = .captureStarted,
        reason: EvaluationCancellationReason = .taskCancelled
    ) -> Self {
        Self(
            result: .timeout,
            maximumStage: stage,
            capture: nil,
            failure: .cancelled(reason),
            retryableMatchSample: nil
        )
    }
}

/// Causa operacional preservada somente em memória. `ApiError` pode manter detail/description para
/// roteamento futuro, mas nunca deve ser escrito diretamente no journal.
enum AutomaticActivitiesFailure: Sendable, Equatable {
    case acquisition(LocationAcquisitionFailure)
    case sampleRejected(LocationSampleValidity)
    case match(ApiError)
    case submit(ApiError)
    case cancelled(EvaluationCancellationReason)

    var sanitized: SanitizedAutomaticActivitiesFailure {
        switch self {
        case .acquisition(let failure):
            return .acquisition(failure)
        case .sampleRejected(let validity):
            return .sampleRejected(validity)
        case .match(let error):
            return .match(SanitizedAutomaticApiFailure(error))
        case .submit(let error):
            return .submit(SanitizedAutomaticApiFailure(error))
        case .cancelled(let reason):
            return .cancelled(reason)
        }
    }
}

/// Efeito offline separado da causa. Uma falha de rede pode, portanto, manter `.match(.network)` ou
/// `.submit(.network)` e registrar também qual fila recebeu o evento.
enum AutomaticOfflineDisposition: Sendable, Equatable {
    case queuedRaw
    case queuedDecided
}

struct AutomaticActivitiesTrace: Sendable, Equatable {
    let maximumStage: AutomaticActivitiesStage
    let capture: AutomaticCaptureTrace?
    let failure: AutomaticActivitiesFailure?
    let offlineDisposition: AutomaticOfflineDisposition?
}

/// Contexto efêmero para repetir somente o matcher depois de unauthorized. Ele nunca atravessa a fronteira
/// do journal, não contém decisão/submit e não oferece orçamento de aquisição: `locationAttempt` é sempre
/// `.finalSample` da mesma amostra, para que a política central revalide o fix no instante do retry.
struct AutomaticMatchRetryContext: Sendable, Equatable {
    let configuration: AutomaticActivitiesConfiguration
    let accuracyThresholdMeters: Int
    let sample: LocationSample

    var locationAttempt: LocationAttemptInput {
        .finalSample(sample)
    }
}

/// Validade efêmera de uma única avaliação automática. A revogação é síncrona para fechar a janela entre
/// a última checagem assíncrona do actor e um efeito irreversível que não pode atravessar `await`.
/// O lock nunca deve proteger rede, reentrar no orquestrador ou atravessar um ponto de suspensão.
final class AutomaticActivitiesEvaluationValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Bool

    init(isCurrent: Bool = true) {
        current = isCurrent
    }

    var isCurrentNow: Bool {
        lock.withLock { current }
    }

    func invalidate() {
        lock.withLock { current = false }
    }

    func performIfCurrent(_ operation: () -> Void) -> Bool {
        lock.withLock {
            guard current else { return false }
            operation()
            return true
        }
    }
}

/// Fence efêmera de efeitos irreversíveis. O caminho automático combina a geração da sessão com a validade
/// da própria avaliação; callers manuais/testes antigos podem continuar usando o inicializador por closure.
/// A ordem global de locks é sempre sessão -> avaliação e a operação deve ser curta, síncrona e não reentrante.
struct AutomaticActivitiesEffectGuard: Sendable {
    private let operationIsCurrent: @Sendable () -> Bool
    private let sessionGeneration: AuthSessionGeneration?
    private let evaluationValidity: AutomaticActivitiesEvaluationValidity?

    init(operationIsCurrent: @escaping @Sendable () -> Bool) {
        self.operationIsCurrent = operationIsCurrent
        sessionGeneration = nil
        evaluationValidity = nil
    }

    init(
        sessionGeneration: AuthSessionGeneration,
        evaluationValidity: AutomaticActivitiesEvaluationValidity
    ) {
        self.sessionGeneration = sessionGeneration
        self.evaluationValidity = evaluationValidity
        operationIsCurrent = {
            sessionGeneration.isCurrentNow && evaluationValidity.isCurrentNow
        }
    }

    func allowsIrreversibleEffect() -> Bool {
        operationIsCurrent()
    }

    /// Lineariza a validação da sessão e da avaliação com um efeito síncrono mínimo. A variante por closure
    /// permanece apenas como seam de compatibilidade; o pipeline automático sempre usa os dois tokens.
    func performIfCurrent(_ operation: () -> Void) -> Bool {
        guard let sessionGeneration, let evaluationValidity else {
            guard operationIsCurrent() else { return false }
            operation()
            return true
        }

        var evaluationPerformed = false
        let sessionPerformed = sessionGeneration.performIfCurrent {
            evaluationPerformed = evaluationValidity.performIfCurrent(operation)
        }
        return sessionPerformed && evaluationPerformed
    }

    static let unrestricted = Self(operationIsCurrent: { true })
}

/// Resultado operacional completo do motor. Nenhum destes tipos adota `Codable`.
struct AutomaticActivitiesExecution: Sendable, Equatable {
    let result: AutoActivitiesResult
    let trace: AutomaticActivitiesTrace
    let submissionContext: AutomaticSubmissionContext?
    /// Presente somente quando `prepare` terminou em `.match(.unauthorized)`. Não é um contexto de submit.
    let matchRetryContext: AutomaticMatchRetryContext?

    init(
        result: AutoActivitiesResult,
        trace: AutomaticActivitiesTrace,
        submissionContext: AutomaticSubmissionContext?,
        matchRetryContext: AutomaticMatchRetryContext? = nil
    ) {
        self.result = result
        self.trace = trace
        self.submissionContext = submissionContext
        self.matchRetryContext = matchRetryContext
    }
}

/// Contexto validado antes de qualquer aquisição. É somente memória e contém apenas os valores já
/// necessários ao motor; em particular, não carrega `LocationSample`.
struct AutomaticActivitiesConfiguration: Sendable, Equatable {
    let chave: String
    let projeto: String
    let mixedZoneIntervalMinutes: Int
}

enum AutomaticActivitiesPreflight: Sendable, Equatable {
    case ready(AutomaticActivitiesConfiguration)
    case terminal(AutomaticActivitiesExecution)
}

/// Match já resolvido e pronto para a matriz. Não contém amostra nem coordenadas. O trace guarda apenas
/// categorias fechadas; o `LocationMatch` continua sendo a resposta autoritativa do servidor.
struct PreparedAutomaticActivitiesMatch: Sendable, Equatable {
    let configuration: AutomaticActivitiesConfiguration
    let match: LocationMatch
    let capture: AutomaticCaptureTrace?

    /// `noKnownLocations` é terminalmente no-action pela matriz atual e não precisa atrasar o match com
    /// uma leitura de state. Accuracy baixa ainda precisa de state para preservar `expectedAction`.
    var requiresCurrentState: Bool {
        switch match.status {
        case .noKnownLocations:
            false
        case .matched, .accuracyTooLow, .notInKnownLocation, .outsideWorkplace:
            true
        }
    }
}

enum AutomaticActivitiesPreparation: Sendable, Equatable {
    case ready(PreparedAutomaticActivitiesMatch)
    case terminal(AutomaticActivitiesExecution)

    var requiresCurrentState: Bool {
        switch self {
        case .ready(let prepared):
            prepared.requiresCurrentState
        case .terminal:
            false
        }
    }

    /// O orquestrador pode usar este contexto uma única vez após refresh bem-sucedido. Chamar novamente
    /// `prepare` com `locationAttempt` revalida a mesma amostra e nunca chama o provider.
    var matchRetryContext: AutomaticMatchRetryContext? {
        switch self {
        case .ready:
            nil
        case .terminal(let execution):
            execution.matchRetryContext
        }
    }
}

enum SanitizedAutomaticApiFailureKind: Sendable, Equatable {
    case http
    case unauthorized
    case conflict
    case network
    case unknown
}

/// Projeção fechada que remove explicitamente detail/description. O status só é mantido dentro da faixa
/// HTTP válida; nenhum texto externo possui campo de destino neste tipo.
struct SanitizedAutomaticApiFailure: Sendable, Equatable {
    let kind: SanitizedAutomaticApiFailureKind
    let httpStatus: Int?

    init(_ error: ApiError) {
        switch error {
        case .http(let status, _):
            kind = .http
            httpStatus = (100 ... 599).contains(status) ? status : nil
        case .unauthorized:
            kind = .unauthorized
            httpStatus = nil
        case .conflict:
            kind = .conflict
            httpStatus = 409
        case .network:
            kind = .network
            httpStatus = nil
        case .unknown:
            kind = .unknown
            httpStatus = nil
        }
    }
}

enum SanitizedAutomaticActivitiesFailure: Sendable, Equatable {
    case acquisition(LocationAcquisitionFailure)
    case sampleRejected(LocationSampleValidity)
    case match(SanitizedAutomaticApiFailure)
    case submit(SanitizedAutomaticApiFailure)
    case cancelled(EvaluationCancellationReason)
}
