import Foundation

/// Token efêmero de uma transição explícita de conta/projeto/toggle/consentimento. Não é persistido nem
/// identifica usuário ou instalação.
struct AutomationContextTransitionToken: Sendable, Equatable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Classificação da admissão separada do terminal de negócio.
///
/// `deferred` e `coalesced` descrevem apenas como a chamada chegou à avaliação canônica. Elas nunca
/// substituem `EvaluationTerminalOutcome` nem autorizam um owner de background a encerrar sua lease.
enum EvaluationAdmission: Sendable, Equatable {
    case admitted
    case deferred
    case coalesced
    case staleContext
    case legacyDropped
}

/// Máscara fechada e somente em memória. Não carrega região, direção, local ou qualquer coordenada.
struct EvaluationWakeSourceMask: OptionSet, Sendable, Equatable {
    let rawValue: UInt8

    static let timer = Self(rawValue: 1 << 0)
    static let geofence = Self(rawValue: 1 << 1)
    static let significantLocation = Self(rawValue: 1 << 2)
    static let foreground = Self(rawValue: 1 << 3)
    static let accuracyRetry = Self(rawValue: 1 << 4)
    static let pauseActivation = Self(rawValue: 1 << 5)
    static let pauseTransition = Self(rawValue: 1 << 6)

    static func source(for trigger: OrchestratorTrigger) -> Self {
        switch trigger {
        case .timer: .timer
        case .geofence: .geofence
        case .significantLocation: .significantLocation
        case .foreground: .foreground
        case .accuracyRetry: .accuracyRetry
        case .pauseActivation: .pauseActivation
        case .pauseTransition: .pauseTransition
        }
    }
}

/// Contadores fixos e saturados do envelope em memória. Três campos normais bastam nesta fase e evitam
/// tanto arrays crescentes quanto chaves arbitrárias.
struct EvaluationRequestWakeCounts: Sendable, Equatable {
    private(set) var timer: UInt16 = 0
    private(set) var geofence: UInt16 = 0
    private(set) var significantLocation: UInt16 = 0
    private(set) var foreground: UInt16 = 0
    private(set) var accuracyRetry: UInt16 = 0
    private(set) var pauseActivation: UInt16 = 0
    private(set) var pauseTransition: UInt16 = 0

    init(trigger: OrchestratorTrigger) {
        increment(trigger)
    }

    mutating func increment(_ trigger: OrchestratorTrigger, by count: UInt16 = 1) {
        switch trigger {
        case .timer:
            timer = Self.saturatingAdd(timer, count)
        case .geofence:
            geofence = Self.saturatingAdd(geofence, count)
        case .significantLocation:
            significantLocation = Self.saturatingAdd(significantLocation, count)
        case .foreground:
            foreground = Self.saturatingAdd(foreground, count)
        case .accuracyRetry:
            accuracyRetry = Self.saturatingAdd(accuracyRetry, count)
        case .pauseActivation:
            pauseActivation = Self.saturatingAdd(pauseActivation, count)
        case .pauseTransition:
            pauseTransition = Self.saturatingAdd(pauseTransition, count)
        }
    }

    func count(for wake: EvaluationWakeKind) -> UInt16 {
        switch wake {
        case .timer: timer
        case .geofence: geofence
        case .significantLocation: significantLocation
        case .foreground: foreground
        case .accuracyRetry: accuracyRetry
        case .pauseActivation: pauseActivation
        case .pauseTransition: pauseTransition
        }
    }

    func merging(_ other: Self) -> Self {
        var result = self
        result.timer = Self.saturatingAdd(timer, other.timer)
        result.geofence = Self.saturatingAdd(geofence, other.geofence)
        result.significantLocation = Self.saturatingAdd(
            significantLocation,
            other.significantLocation
        )
        result.foreground = Self.saturatingAdd(foreground, other.foreground)
        result.accuracyRetry = Self.saturatingAdd(accuracyRetry, other.accuracyRetry)
        result.pauseActivation = Self.saturatingAdd(pauseActivation, other.pauseActivation)
        result.pauseTransition = Self.saturatingAdd(pauseTransition, other.pauseTransition)
        return result
    }

    var total: UInt16 {
        [
            timer,
            geofence,
            significantLocation,
            foreground,
            accuracyRetry,
            pauseActivation,
            pauseTransition,
        ].reduce(0, Self.saturatingAdd)
    }

    private static func saturatingAdd(_ lhs: UInt16, _ rhs: UInt16) -> UInt16 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

/// Envelope externo criado exclusivamente na fronteira controlada do orquestrador.
///
/// A geração de automação é carimbada somente na admissão pelo actor e, portanto, não faz parte deste
/// valor. A amostra permanece somente em memória; este tipo não adota `Codable` nem descrição textual.
struct EvaluationRequest: Sendable, Equatable {
    static let maximumCoalescedWakeCount = UInt16.max

    let id: EvaluationID
    let trigger: OrchestratorTrigger
    let receivedAt: Date
    let sample: LocationSample?
    let appStateAtReceipt: EvaluationApplicationState
    let sourceMask: EvaluationWakeSourceMask
    let wakeCounts: EvaluationRequestWakeCounts

    init(
        id: EvaluationID,
        trigger: OrchestratorTrigger,
        receivedAt: Date,
        sample: LocationSample?,
        appStateAtReceipt: EvaluationApplicationState = .unknown,
        sourceMask: EvaluationWakeSourceMask? = nil,
        wakeCounts: EvaluationRequestWakeCounts? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.receivedAt = receivedAt
        self.sample = sample
        self.appStateAtReceipt = appStateAtReceipt
        self.sourceMask = sourceMask ?? .source(for: trigger)
        self.wakeCounts = wakeCounts ?? EvaluationRequestWakeCounts(trigger: trigger)
    }

    var coalescedWakeCount: UInt16 { wakeCounts.total }

    var isNormalWake: Bool {
        switch trigger {
        case .timer, .geofence, .significantLocation:
            true
        case .foreground, .accuracyRetry, .pauseActivation, .pauseTransition:
            false
        }
    }

    var isExclusivelyTimer: Bool {
        sourceMask == .timer
    }
}

/// Merge puro do único slot normal.
///
/// O ID e, consequentemente, o ticket da primeira admissão nunca mudam. O trigger efetivo privilegia
/// eventos sobre TIMER e `SIGNIFICANT_LOCATION` sobre GEOFENCE porque somente ele pode transportar seed.
/// Mesmo assim, o matcher remoto e a matriz existente continuam sendo as únicas fontes de local/ação.
enum PendingWakeMerge {
    static func mergePendingWake(
        current: EvaluationRequest,
        new: EvaluationRequest,
        now: Date,
        samplePolicy: LocationSamplePolicy = .candidateTrial,
        requiredAccuracyMeters: Int = 0
    ) -> EvaluationRequest? {
        guard current.isNormalWake, new.isNormalWake else { return nil }

        let mergedSources = current.sourceMask.union(new.sourceMask)
        let effectiveTrigger: OrchestratorTrigger
        if mergedSources.contains(.significantLocation) {
            effectiveTrigger = .significantLocation
        } else if mergedSources.contains(.geofence) {
            effectiveTrigger = .geofence
        } else {
            effectiveTrigger = .timer
        }

        let selectedSample = samplePolicy.preferredSeed(
            current: current.sample,
            candidate: new.sample,
            now: now,
            requiredAccuracyMeters: requiredAccuracyMeters
        )
        let latest = current.receivedAt >= new.receivedAt ? current : new

        return EvaluationRequest(
            id: current.id,
            trigger: effectiveTrigger,
            receivedAt: max(current.receivedAt, new.receivedAt),
            sample: selectedSample,
            appStateAtReceipt: latest.appStateAtReceipt,
            sourceMask: mergedSources,
            wakeCounts: current.wakeCounts.merging(new.wakeCounts)
        )
    }
}

/// One-shot bounded: somente a task canônica chama `wait`, enquanto qualquer quantidade de callers
/// aguarda essa mesma task. Assim há, no máximo, uma continuation por avaliação e nenhum vetor de waiters.
actor EvaluationOneShot<Value: Sendable> {
    private var value: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        if let value { return value }
        return await withCheckedContinuation { continuation in
            precondition(self.continuation == nil, "EvaluationOneShot has more than one canonical waiter.")
            if let value = self.value {
                continuation.resume(returning: value)
            } else {
                self.continuation = continuation
            }
        }
    }

    func resolve(_ value: Value) {
        guard self.value == nil else { return }
        self.value = value
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }
}

struct SharedEvaluationCompletion: Sendable {
    let task: Task<EvaluationCompletion, Never>
    private let oneShot: EvaluationOneShot<EvaluationCompletion>

    init() {
        let oneShot = EvaluationOneShot<EvaluationCompletion>()
        self.oneShot = oneShot
        task = Task { await oneShot.wait() }
    }

    func resolve(_ completion: EvaluationCompletion) async {
        await oneShot.resolve(completion)
    }
}

/// Handle aguardável da avaliação canônica. Cancelar a task do caller não cancela `completionTask`, o
/// driver compartilhado nem os demais callers.
struct EvaluationTicket: Sendable {
    typealias OwnerExpirationReporter = @Sendable (
        _ owner: EvaluationJournalOwnerKind,
        _ cancelledCanonicalWork: Bool
    ) async -> Void

    let evaluationID: EvaluationID
    let admission: EvaluationAdmission
    let completionTask: Task<EvaluationCompletion, Never>
    private let ownerExpirationReporter: OwnerExpirationReporter?

    init(
        evaluationID: EvaluationID,
        admission: EvaluationAdmission,
        completionTask: Task<EvaluationCompletion, Never>,
        ownerExpirationReporter: OwnerExpirationReporter? = nil
    ) {
        self.evaluationID = evaluationID
        self.admission = admission
        self.completionTask = completionTask
        self.ownerExpirationReporter = ownerExpirationReporter
    }

    func completion() async -> EvaluationCompletion {
        await completionTask.value
    }

    /// O ticket conhece o record canônico, portanto um owner que expira na fronteira final pode anexar
    /// diagnóstico mesmo depois do terminal. Isso não cria handoff, não altera o resultado e o journal
    /// trata a atualização como monotônica/idempotente.
    func recordOwnerExpiration(
        owner: EvaluationJournalOwnerKind,
        cancelledCanonicalWork: Bool
    ) async {
        guard let ownerExpirationReporter else { return }
        await ownerExpirationReporter(owner, cancelledCanonicalWork)
    }
}
