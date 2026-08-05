import Foundation

/// Identificador aleatório de uma avaliação. A codificação single-value evita transformar o UUID em um
/// objeto extensível no schema persistido.
struct EvaluationID: Codable, Hashable, Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// UUID efêmero criado uma vez por composição do processo. Não é PID, ID de instalação ou ID de usuário.
struct EvaluationProcessID: Codable, Hashable, Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum EvaluationStage: String, Codable, CaseIterable, Sendable {
    case started
    case admitted
    case drained
    case restore
    case contextLoaded = "context_loaded"
    case settings
    case pause
    case options
    case movement
    case state
    case acquisition
    case captureStarted = "capture_started"
    case captured
    case match
    case matched
    case decision
    case decisionCompleted = "decision_completed"
    case submit
    case submitStarted = "submit_started"
    case submitted
    case notification

    fileprivate var rank: Int {
        switch self {
        case .started: 0
        case .admitted: 1
        case .drained: 2
        case .restore: 3
        case .contextLoaded: 4
        case .settings: 5
        case .pause: 6
        case .options: 7
        case .movement: 8
        case .state: 9
        case .acquisition, .captureStarted: 10
        case .captured: 11
        case .match, .matched: 12
        case .decision, .decisionCompleted: 13
        case .submit, .submitStarted: 14
        case .submitted: 15
        case .notification: 16
        }
    }

    static func furthest(_ lhs: Self, _ rhs: Self) -> Self {
        lhs.rank >= rhs.rank ? lhs : rhs
    }
}

/// Taxonomia fechada do plano §9.4. Não aceita texto do backend nem descrições de `Error`.
enum EvaluationTerminalOutcome: String, Codable, CaseIterable, Sendable {
    /// A invocação encontrou outra avaliação em voo e, portanto, não foi admitida nem persistida.
    /// Este valor aparece somente em `EvaluationCompletion`; o Prompt 11 decidirá o destino do wake.
    case notAdmitted = "not_admitted"
    case noKey = "no_key"
    case toggleOff = "toggle_off"
    case paused
    case notConfigured = "not_configured"
    case staleContext = "stale_context"
    case skippedNoMovement = "skipped_no_movement"
    case captured
    case bestPartial = "best_partial"
    case locationTimeout = "location_timeout"
    case timeout
    case unavailable
    case permissionDenied = "permission_denied"
    case accuracyTooLow = "accuracy_too_low"
    case cancelled
    case networkFailure = "network_failure"
    case unauthorized
    case reloginFailed = "relogin_failed"
    case httpRejected = "http_rejected"
    case conflict
    case noAction = "no_action"
    case queuedOfflineRaw = "queued_offline_raw"
    case queuedOfflineDecided = "queued_offline_decided"
    case queuedOffline = "queued_offline"
    case submissionOutcomeUnknown = "submission_outcome_unknown"
    case submittedCheckIn = "submitted_check_in"
    case submittedCheckOut = "submitted_check_out"
    case expired
    case abandoned
    case internalFailure = "internal_failure"
    case coalescedCovered = "coalesced_covered"
}

/// Resultado explícito de uma invocação do orquestrador. Uma chamada rejeitada pelo single-flight recebe
/// `admitted == false` e nunca cria record no journal; toda chamada admitida usa o mesmo ID em begin,
/// finish e completion.
struct EvaluationCompletion: Sendable, Equatable {
    let evaluationID: EvaluationID
    let outcome: EvaluationTerminalOutcome
    let completedBeforeExpiration: Bool
    let admitted: Bool

    init(
        evaluationID: EvaluationID,
        outcome: EvaluationTerminalOutcome,
        completedBeforeExpiration: Bool,
        admitted: Bool = true
    ) {
        self.evaluationID = evaluationID
        self.outcome = outcome
        self.completedBeforeExpiration = completedBeforeExpiration
        self.admitted = admitted
    }
}

enum EvaluationTrigger: String, Codable, CaseIterable, Sendable {
    case timer
    case geofence
    case significantLocation = "significant_location"
    case foreground
    case accuracyRetry = "accuracy_retry"
    case pauseActivation = "pause_activation"
    case pauseTransition = "pause_transition"

    /// Merge monotônico do trigger efetivo de um pending normal. Eventos nunca podem ser rebaixados por
    /// uma escrita assíncrona atrasada de TIMER/GEOFENCE.
    func promoted(with candidate: Self) -> Self {
        let normalPriority: (Self) -> Int? = {
            switch $0 {
            case .timer: 0
            case .geofence: 1
            case .significantLocation: 2
            case .foreground, .accuracyRetry, .pauseActivation, .pauseTransition: nil
            }
        }
        if let currentPriority = normalPriority(self),
           let candidatePriority = normalPriority(candidate) {
            return candidatePriority > currentPriority ? candidate : self
        }
        return self == candidate ? self : candidate
    }
}

enum EvaluationWakeKind: String, Codable, CaseIterable, Sendable {
    case timer
    case geofence
    case significantLocation = "significant_location"
    case foreground
    case accuracyRetry = "accuracy_retry"
    case pauseActivation = "pause_activation"
    case pauseTransition = "pause_transition"
}

enum EvaluationLocationSource: String, Codable, CaseIterable, Sendable {
    case freshCapture = "fresh_capture"
    case seed
    case bestPartial = "best_partial"
}

enum EvaluationPermissionMode: String, Codable, CaseIterable, Sendable {
    case notDetermined = "not_determined"
    case whenInUse = "when_in_use"
    case always
    case denied
    case restricted
    case unknown
}

enum EvaluationAccuracyMode: String, Codable, CaseIterable, Sendable {
    case full
    case reduced
    case unknown
}

enum EvaluationApplicationState: String, Codable, CaseIterable, Sendable {
    case active
    case inactive
    case background
    case unknown
}

enum EvaluationLaunchState: String, Codable, CaseIterable, Sendable {
    case cold
    case warm
    case unknown
}

enum EvaluationBackgroundRefreshState: String, Codable, CaseIterable, Sendable {
    case available
    case denied
    case restricted
    case unknown
}

enum EvaluationMonitorState: String, Codable, CaseIterable, Sendable {
    case active
    case inactive
    case unavailable
    case unknown
}

/// Classe Core Location por whitelist de códigos; nunca persiste `localizedDescription` ou o `Error`.
enum EvaluationCoreLocationErrorCategory: String, Codable, CaseIterable, Sendable {
    case locationUnknown = "location_unknown"
    case denied
    case network
    case heading
    case monitoring
    case geocoding
    case deferred
    case ranging
    case promptDeclined = "prompt_declined"
    case unknown

    static func classify(code: Int) -> Self {
        switch code {
        case 0: .locationUnknown
        case 1: .denied
        case 2: .network
        case 3: .heading
        case 4, 5, 6, 7: .monitoring
        case 8, 9, 10: .geocoding
        case 11, 12, 13, 14, 15: .deferred
        case 16, 17: .ranging
        case 18: .promptDeclined
        default: .unknown
        }
    }
}

enum EvaluationHTTPClass: String, Codable, CaseIterable, Sendable {
    case none
    case informational
    case success
    case redirection
    case clientError = "client_error"
    case serverError = "server_error"
    case unknown
}

/// Somente status numérico válido e sua classe. Não há campo para body, URL, header ou detalhe.
struct EvaluationHTTPDiagnostic: Codable, Equatable, Sendable {
    let status: Int?
    let classification: EvaluationHTTPClass

    init(status: Int?) {
        guard let status, (100 ... 599).contains(status) else {
            self.status = nil
            classification = status == nil ? .none : .unknown
            return
        }
        self.status = status
        classification = switch status {
        case 100 ... 199: .informational
        case 200 ... 299: .success
        case 300 ... 399: .redirection
        case 400 ... 499: .clientError
        case 500 ... 599: .serverError
        default: .unknown
        }
    }

    /// Sanitiza a taxonomia já tipada do app. O `detail`/`description` associado nunca atravessa a API.
    static func sanitized(from error: ApiError) -> Self? {
        switch error {
        case .http(let status, _): Self(status: status)
        case .conflict: Self(status: 409)
        // `ApiError.unauthorized` representa tanto 401 quanto 403; não inventar um status exato.
        case .unauthorized, .network, .unknown: nil
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let persistedStatus = try container.decodeIfPresent(Int.self, forKey: .status)
        let persistedClass = try container.decode(EvaluationHTTPClass.self, forKey: .classification)
        if persistedStatus == nil {
            guard persistedClass == .none || persistedClass == .unknown else {
                throw DecodingError.dataCorruptedError(
                    forKey: .classification,
                    in: container,
                    debugDescription: "HTTP diagnostic without status has an invalid classification."
                )
            }
            status = nil
            classification = persistedClass
            return
        }
        let sanitized = Self(status: persistedStatus)
        guard persistedClass == sanitized.classification else {
            throw DecodingError.dataCorruptedError(
                forKey: .classification,
                in: container,
                debugDescription: "HTTP diagnostic classification does not match its sanitized status."
            )
        }
        self = sanitized
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encode(classification, forKey: .classification)
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case classification
    }
}

enum EvaluationAccuracyBucket: String, Codable, CaseIterable, Sendable {
    case zeroTo10Meters = "0_to_10_m"
    case elevenTo25Meters = "11_to_25_m"
    case twentySixTo50Meters = "26_to_50_m"
    case fiftyOneTo100Meters = "51_to_100_m"
    case over100Meters = "over_100_m"
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

enum EvaluationAgeBucket: String, Codable, CaseIterable, Sendable {
    case under1Second = "under_1_s"
    case oneTo5Seconds = "1_to_5_s"
    case sixTo15Seconds = "6_to_15_s"
    case over15Seconds = "over_15_s"
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

enum EvaluationDurationBucket: String, Codable, CaseIterable, Sendable {
    case under1Second = "under_1_s"
    case oneTo5Seconds = "1_to_5_s"
    case sixTo15Seconds = "6_to_15_s"
    case over15Seconds = "over_15_s"
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

struct EvaluationMonitorFlags: Codable, Equatable, Sendable {
    let geofence: EvaluationMonitorState
    let significantLocation: EvaluationMonitorState
    let backgroundTask: EvaluationMonitorState

    init(
        geofence: EvaluationMonitorState = .unknown,
        significantLocation: EvaluationMonitorState = .unknown,
        backgroundTask: EvaluationMonitorState = .unknown
    ) {
        self.geofence = geofence
        self.significantLocation = significantLocation
        self.backgroundTask = backgroundTask
    }

    private enum CodingKeys: String, CodingKey {
        case geofence
        case significantLocation = "significant_location"
        case backgroundTask = "background_task"
    }
}

/// Categoria fechada e exclusiva do journal para o owner cujo orçamento expirou. Este tipo não aceita
/// tokens/UUIDs de lease, IDs do sistema ou razões em texto livre.
enum EvaluationJournalOwnerKind: String, Codable, CaseIterable, Sendable {
    case bgAppRefresh = "bg_app_refresh"
    case uiBackgroundTask = "ui_background_task"
    case bgProcessing = "bg_processing"
}

/// Diagnóstico monotônico e bounded de expiração. Cada combinação possível é representada por um campo
/// booleano fixo: repetir o mesmo evento é idempotente e não cria listas, contadores arbitrários ou um
/// marker de handoff. O valor apenas explica o que ocorreu com uma avaliação que já possui ID próprio.
struct EvaluationOwnerExpirationDiagnostics: Codable, Equatable, Sendable {
    private(set) var bgAppRefreshExpired = false
    private(set) var uiBackgroundTaskExpired = false
    private(set) var bgProcessingExpired = false
    private(set) var bgAppRefreshCancelledCanonicalWork = false
    private(set) var uiBackgroundTaskCancelledCanonicalWork = false
    private(set) var bgProcessingCancelledCanonicalWork = false

    @discardableResult
    mutating func record(
        owner: EvaluationJournalOwnerKind,
        cancelledCanonicalWork: Bool
    ) -> Bool {
        let previous = self
        switch owner {
        case .bgAppRefresh:
            bgAppRefreshExpired = true
            bgAppRefreshCancelledCanonicalWork =
                bgAppRefreshCancelledCanonicalWork || cancelledCanonicalWork
        case .uiBackgroundTask:
            uiBackgroundTaskExpired = true
            uiBackgroundTaskCancelledCanonicalWork =
                uiBackgroundTaskCancelledCanonicalWork || cancelledCanonicalWork
        case .bgProcessing:
            bgProcessingExpired = true
            bgProcessingCancelledCanonicalWork =
                bgProcessingCancelledCanonicalWork || cancelledCanonicalWork
        }
        return self != previous
    }

    func didExpire(_ owner: EvaluationJournalOwnerKind) -> Bool {
        switch owner {
        case .bgAppRefresh: bgAppRefreshExpired
        case .uiBackgroundTask: uiBackgroundTaskExpired
        case .bgProcessing: bgProcessingExpired
        }
    }

    func cancelledCanonicalWork(for owner: EvaluationJournalOwnerKind) -> Bool {
        switch owner {
        case .bgAppRefresh: bgAppRefreshCancelledCanonicalWork
        case .uiBackgroundTask: uiBackgroundTaskCancelledCanonicalWork
        case .bgProcessing: bgProcessingCancelledCanonicalWork
        }
    }

    /// Rejeita representações adulteradas em que uma cancellation aparece sem a expiração correspondente.
    var isValid: Bool {
        EvaluationJournalOwnerKind.allCases.allSatisfy {
            !cancelledCanonicalWork(for: $0) || didExpire($0)
        } && EvaluationJournalOwnerKind.allCases.contains(where: didExpire)
    }

    private enum CodingKeys: String, CodingKey {
        case bgAppRefreshExpired = "bg_app_refresh_expired"
        case uiBackgroundTaskExpired = "ui_background_task_expired"
        case bgProcessingExpired = "bg_processing_expired"
        case bgAppRefreshCancelledCanonicalWork = "bg_app_refresh_cancelled_canonical_work"
        case uiBackgroundTaskCancelledCanonicalWork = "ui_background_task_cancelled_canonical_work"
        case bgProcessingCancelledCanonicalWork = "bg_processing_cancelled_canonical_work"
    }
}

/// Contadores fixos evitam dicionários/chaves arbitrárias e impossibilitam persistir region IDs.
struct EvaluationWakeCounts: Codable, Equatable, Sendable {
    static let maximumPerKind = 10_000

    private(set) var timer = 0
    private(set) var geofence = 0
    private(set) var significantLocation = 0
    private(set) var foreground = 0
    private(set) var accuracyRetry = 0
    private(set) var pauseActivation = 0
    private(set) var pauseTransition = 0

    init(primary: EvaluationWakeKind) {
        increment(primary)
    }

    mutating func ensurePresent(_ kind: EvaluationWakeKind) {
        if count(for: kind) == 0 { increment(kind) }
    }

    @discardableResult
    mutating func ensureCount(_ kind: EvaluationWakeKind, atLeast target: Int) -> Bool {
        let boundedTarget = min(max(0, target), Self.maximumPerKind)
        let current = count(for: kind)
        guard boundedTarget > current else { return false }
        return increment(kind, by: boundedTarget - current)
    }

    @discardableResult
    mutating func increment(_ kind: EvaluationWakeKind) -> Bool {
        increment(kind, by: 1)
    }

    @discardableResult
    mutating func increment(_ kind: EvaluationWakeKind, by count: Int) -> Bool {
        guard count > 0 else { return false }
        return switch kind {
        case .timer: Self.incrementIfPossible(&timer, by: count)
        case .geofence: Self.incrementIfPossible(&geofence, by: count)
        case .significantLocation: Self.incrementIfPossible(&significantLocation, by: count)
        case .foreground: Self.incrementIfPossible(&foreground, by: count)
        case .accuracyRetry: Self.incrementIfPossible(&accuracyRetry, by: count)
        case .pauseActivation: Self.incrementIfPossible(&pauseActivation, by: count)
        case .pauseTransition: Self.incrementIfPossible(&pauseTransition, by: count)
        }
    }

    func count(for kind: EvaluationWakeKind) -> Int {
        switch kind {
        case .timer: timer
        case .geofence: geofence
        case .significantLocation: significantLocation
        case .foreground: foreground
        case .accuracyRetry: accuracyRetry
        case .pauseActivation: pauseActivation
        case .pauseTransition: pauseTransition
        }
    }

    var total: Int {
        timer + geofence + significantLocation + foreground + accuracyRetry + pauseActivation + pauseTransition
    }

    var isValid: Bool {
        EvaluationWakeKind.allCases.allSatisfy {
            (0 ... Self.maximumPerKind).contains(count(for: $0))
        } && total > 0
    }

    private static func incrementIfPossible(_ value: inout Int, by count: Int = 1) -> Bool {
        guard value < Self.maximumPerKind else { return false }
        value = min(Self.maximumPerKind, value + count)
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case timer
        case geofence
        case significantLocation = "significant_location"
        case foreground
        case accuracyRetry = "accuracy_retry"
        case pauseActivation = "pause_activation"
        case pauseTransition = "pause_transition"
    }
}

struct EvaluationStart: Equatable, Sendable {
    let id: EvaluationID
    let trigger: EvaluationTrigger
    let primaryWake: EvaluationWakeKind
    let stage: EvaluationStage
    let appState: EvaluationApplicationState
    let launchState: EvaluationLaunchState
    let permissionMode: EvaluationPermissionMode
    let accuracyMode: EvaluationAccuracyMode
    let backgroundRefresh: EvaluationBackgroundRefreshState
    let lowPowerMode: Bool
    let monitors: EvaluationMonitorFlags
    let locationSource: EvaluationLocationSource?
    let captureReused: Bool?
    let accuracyBucket: EvaluationAccuracyBucket?
    let ageBucket: EvaluationAgeBucket?

    init(
        id: EvaluationID = EvaluationID(),
        trigger: EvaluationTrigger,
        primaryWake: EvaluationWakeKind,
        stage: EvaluationStage = .started,
        appState: EvaluationApplicationState = .unknown,
        launchState: EvaluationLaunchState = .unknown,
        permissionMode: EvaluationPermissionMode = .unknown,
        accuracyMode: EvaluationAccuracyMode = .unknown,
        backgroundRefresh: EvaluationBackgroundRefreshState = .unknown,
        lowPowerMode: Bool = false,
        monitors: EvaluationMonitorFlags = EvaluationMonitorFlags(),
        locationSource: EvaluationLocationSource? = nil,
        captureReused: Bool? = nil,
        accuracyBucket: EvaluationAccuracyBucket? = nil,
        ageBucket: EvaluationAgeBucket? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.primaryWake = primaryWake
        self.stage = stage
        self.appState = appState
        self.launchState = launchState
        self.permissionMode = permissionMode
        self.accuracyMode = accuracyMode
        self.backgroundRefresh = backgroundRefresh
        self.lowPowerMode = lowPowerMode
        self.monitors = monitors
        self.locationSource = locationSource
        self.captureReused = captureReused
        self.accuracyBucket = accuracyBucket
        self.ageBucket = ageBucket
    }
}

struct EvaluationCoalescence: Equatable, Sendable {
    let evaluationID: EvaluationID
    let wake: EvaluationWakeKind
    let stage: EvaluationStage?
    let count: Int
    /// Snapshot total idempotente. Permite registrar no merge e repetir no drain sem duplicar contadores.
    let targetCount: Int?
    let effectiveTrigger: EvaluationTrigger?

    init(
        evaluationID: EvaluationID,
        wake: EvaluationWakeKind,
        stage: EvaluationStage? = nil,
        count: Int = 1,
        targetCount: Int? = nil,
        effectiveTrigger: EvaluationTrigger? = nil
    ) {
        self.evaluationID = evaluationID
        self.wake = wake
        self.stage = stage
        self.count = min(max(1, count), EvaluationWakeCounts.maximumPerKind)
        self.targetCount = targetCount.map {
            min(max(1, $0), EvaluationWakeCounts.maximumPerKind)
        }
        self.effectiveTrigger = effectiveTrigger
    }
}

struct EvaluationProgress: Equatable, Sendable {
    let evaluationID: EvaluationID
    let stage: EvaluationStage
    let effectiveTrigger: EvaluationTrigger?

    init(
        evaluationID: EvaluationID,
        stage: EvaluationStage,
        effectiveTrigger: EvaluationTrigger? = nil
    ) {
        self.evaluationID = evaluationID
        self.stage = stage
        self.effectiveTrigger = effectiveTrigger
    }
}

struct EvaluationTerminal: Equatable, Sendable {
    let outcome: EvaluationTerminalOutcome
    let stage: EvaluationStage?
    let durationBucket: EvaluationDurationBucket
    let locationSource: EvaluationLocationSource?
    let captureReused: Bool?
    let accuracyBucket: EvaluationAccuracyBucket?
    let ageBucket: EvaluationAgeBucket?
    let coreLocationError: EvaluationCoreLocationErrorCategory?
    let http: EvaluationHTTPDiagnostic?
    /// `true`/`false` só devem ser usados quando o seam confirma o agendamento. `nil` representa estado
    /// desconhecido, inclusive o seam histórico fire-and-forget que não expõe o resultado do iOS.
    let notificationScheduled: Bool?

    init(
        outcome: EvaluationTerminalOutcome,
        stage: EvaluationStage? = nil,
        durationBucket: EvaluationDurationBucket = .unknown,
        locationSource: EvaluationLocationSource? = nil,
        captureReused: Bool? = nil,
        accuracyBucket: EvaluationAccuracyBucket? = nil,
        ageBucket: EvaluationAgeBucket? = nil,
        coreLocationError: EvaluationCoreLocationErrorCategory? = nil,
        http: EvaluationHTTPDiagnostic? = nil,
        notificationScheduled: Bool? = nil
    ) {
        self.outcome = outcome
        self.stage = stage
        self.durationBucket = durationBucket
        self.locationSource = locationSource
        self.captureReused = captureReused
        self.accuracyBucket = accuracyBucket
        self.ageBucket = ageBucket
        self.coreLocationError = coreLocationError
        self.http = http
        self.notificationScheduled = notificationScheduled
    }
}

struct EvaluationRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let evaluationID: EvaluationID
    let processID: EvaluationProcessID
    let sequence: UInt64
    let startedAt: Date
    var finishedAt: Date?
    var trigger: EvaluationTrigger
    var wakes: EvaluationWakeCounts
    var stage: EvaluationStage
    let appState: EvaluationApplicationState
    let launchState: EvaluationLaunchState
    let permissionMode: EvaluationPermissionMode
    let accuracyMode: EvaluationAccuracyMode
    let backgroundRefresh: EvaluationBackgroundRefreshState
    let lowPowerMode: Bool
    let monitors: EvaluationMonitorFlags
    var locationSource: EvaluationLocationSource?
    var captureReused: Bool?
    var accuracyBucket: EvaluationAccuracyBucket?
    var ageBucket: EvaluationAgeBucket?
    var durationBucket: EvaluationDurationBucket?
    var terminal: EvaluationTerminalOutcome?
    var coreLocationError: EvaluationCoreLocationErrorCategory?
    var http: EvaluationHTTPDiagnostic?
    var notificationScheduled: Bool?
    /// Campo opcional mantém compatibilidade de leitura com records schema v1 gravados antes deste
    /// diagnóstico. Não é marker de retomada e nunca é consultado para decidir trabalho futuro.
    var ownerExpirations: EvaluationOwnerExpirationDiagnostics?

    var isStarted: Bool { terminal == nil }

    mutating func merge(_ start: EvaluationStart) {
        wakes.ensurePresent(start.primaryWake)
        stage = .furthest(stage, start.stage)
        locationSource = start.locationSource ?? locationSource
        captureReused = start.captureReused ?? captureReused
        accuracyBucket = start.accuracyBucket ?? accuracyBucket
        ageBucket = start.ageBucket ?? ageBucket
    }

    mutating func apply(_ terminal: EvaluationTerminal, finishedAt: Date) {
        self.finishedAt = finishedAt
        self.terminal = terminal.outcome
        if let terminalStage = terminal.stage {
            stage = .furthest(stage, terminalStage)
        }
        durationBucket = terminal.durationBucket
        locationSource = terminal.locationSource ?? locationSource
        captureReused = terminal.captureReused ?? captureReused
        accuracyBucket = terminal.accuracyBucket ?? accuracyBucket
        ageBucket = terminal.ageBucket ?? ageBucket
        coreLocationError = terminal.coreLocationError
        http = terminal.http
        notificationScheduled = terminal.notificationScheduled
    }

    @discardableResult
    mutating func recordOwnerExpiration(
        owner: EvaluationJournalOwnerKind,
        cancelledCanonicalWork: Bool
    ) -> Bool {
        var diagnostics = ownerExpirations ?? EvaluationOwnerExpirationDiagnostics()
        guard diagnostics.record(
            owner: owner,
            cancelledCanonicalWork: cancelledCanonicalWork
        ) else { return false }
        ownerExpirations = diagnostics
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case evaluationID = "evaluation_id"
        case processID = "process_id"
        case sequence
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case trigger
        case wakes
        case stage
        case appState = "app_state"
        case launchState = "launch_state"
        case permissionMode = "permission_mode"
        case accuracyMode = "accuracy_mode"
        case backgroundRefresh = "background_refresh"
        case lowPowerMode = "low_power_mode"
        case monitors
        case locationSource = "location_source"
        case captureReused = "capture_reused"
        case accuracyBucket = "accuracy_bucket"
        case ageBucket = "age_bucket"
        case durationBucket = "duration_bucket"
        case terminal
        case coreLocationError = "core_location_error"
        case http
        case notificationScheduled = "notification_scheduled"
        case ownerExpirations = "owner_expirations"
    }
}
