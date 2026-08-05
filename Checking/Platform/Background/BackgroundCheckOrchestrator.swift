import Foundation
import CoreLocation

/// Orçamento efêmero e estritamente local a uma avaliação. O actor torna a reserva atômica mesmo
/// quando o coordenador de sessão coalesce este refresh com outro caller (por exemplo, a UI ativa).
private actor EvaluationAuthRetryBudget {
    nonisolated let sessionGeneration: AuthSessionGeneration
    nonisolated let evaluationEffectValidity: AutomaticActivitiesEvaluationValidity
    private var didReserveSilentRelogin = false

    init(
        sessionGeneration: AuthSessionGeneration,
        evaluationEffectValidity: AutomaticActivitiesEvaluationValidity
    ) {
        self.sessionGeneration = sessionGeneration
        self.evaluationEffectValidity = evaluationEffectValidity
    }

    func reserveSilentRelogin() -> Bool {
        guard !didReserveSilentRelogin else { return false }
        didReserveSilentRelogin = true
        return true
    }
}

private enum AuthenticatedDependencyResolution<Value: Sendable>: Sendable {
    case resolution(BackgroundInputResolution<Value>)
    case terminal(EvaluationTerminal)
}

private enum AuthenticatedActivitiesExecution: Sendable {
    case execution(AutomaticActivitiesExecution)
    case terminal(EvaluationTerminal)
}

/// Núcleo do motor de background — port de BackgroundCheckOrchestrator.kt. O actor mantém concorrência
/// máxima 1: o perfil legado conserva o drop histórico; o candidate agrega no máximo um pending normal,
/// além dos tickets especiais bounded. A matriz continua no use-case de domínio.
actor BackgroundCheckOrchestrator {
    // Constantes (§11)
    private static let seedAdmissionAccuracyFloorMeters = 0
    static let skipThresholdMeters = 50.0
    static let stateCacheTTL: TimeInterval = 45
    static let locationOptionsTTL: TimeInterval = 15 * 60
    static let reauthNotificationCooldown: TimeInterval = 60 * 60
    static let accuracyRetryInterval: TimeInterval = 180
    static let scheduledPauseActivationDelay: TimeInterval = 10
    static let scheduledPauseConfirmationBackoff: TimeInterval = 180
    static let flagPauseActive = "scheduled_pause_active"

    private enum SkipDecision { case run, skip, noFix, cancelled }

    private struct EvaluationContextSnapshot: Sendable, Equatable {
        let automation: UInt64
        let accuracyRetry: UInt64
        let scheduledPause: UInt64
    }

    private struct CanonicalEvaluationWork: Sendable {
        var request: EvaluationRequest
        var isPauseReconciliation: Bool
        let automationContextGeneration: UInt64
        let forceFreshState: Bool
        let wasDeferred: Bool
        let journalPrimaryWake: EvaluationWakeKind
        let journalAdmission: Task<Void, Never>
        let ownership: BackgroundWorkOwnership
        let completion: SharedEvaluationCompletion
    }

    private struct SharedAccidentCompletion: Sendable {
        let task: Task<Void, Never>
        private let oneShot: EvaluationOneShot<Void>

        init() {
            let oneShot = EvaluationOneShot<Void>()
            self.oneShot = oneShot
            task = Task { await oneShot.wait() }
        }

        func resolve() async {
            await oneShot.resolve(())
        }
    }

    private struct CanonicalAccidentWork: Sendable {
        let automationContextGeneration: UInt64
        let completion: SharedAccidentCompletion
    }

    private enum CanonicalWork: Sendable {
        case evaluation(CanonicalEvaluationWork)
        case accident(CanonicalAccidentWork)
    }

    private enum AutomationQuiescenceWait: Sendable {
        case evaluation(Task<EvaluationCompletion, Never>)
        case accident(Task<Void, Never>)

        func wait() async {
            switch self {
            case .evaluation(let task):
                _ = await task.value
            case .accident(let task):
                await task.value
            }
        }
    }

    /// Ordem aprovada no gate humano do Prompt 11. O pending normal bounded é drenado antes do retry
    /// vencido; ambos continuam atrás das transições/reconciliações especiais de pausa.
    private enum DrainClass: Int, CaseIterable, Sendable {
        case pauseTransition
        case pauseActivation
        case foregroundReconciliation
        case normal
        case accuracyRetry
        case accident
    }

    /// Proposta somente em memória. O baseline só é efetivado depois que a avaliação termina sem
    /// cancelamento/invalidação; assim um `await` interrompido nunca contamina o próximo TIMER.
    private struct CandidateMovementBaseline: Sendable {
        let latitude: Double
        let longitude: Double
    }

    private enum CandidateTimerMovementResult: Sendable {
        case proceed(
            LocationSample,
            trace: AutomaticCaptureTrace,
            baseline: CandidateMovementBaseline?
        )
        case skip(trace: AutomaticCaptureTrace, baseline: CandidateMovementBaseline)
        case rejected(LocationSampleValidity, AutomaticCaptureTrace)
        case interrupted(EvaluationTerminalOutcome, AutomaticCaptureTrace?)
        case failed(LocationAcquisitionFailure)
    }

    private enum CandidateTimerEvaluationResult: Sendable {
        case execution(
            AutomaticActivitiesExecution,
            configuration: AutomaticActivitiesConfiguration,
            prepared: PreparedAutomaticActivitiesMatch?,
            movementBaseline: CandidateMovementBaseline?
        )
        case terminal(LockedEvaluationResult)
    }

    private enum ScheduledPauseStopReason {
        case paused
        case noAction
        case failure(ApiError)
        case terminal(EvaluationTerminal)
    }

    private struct LockedEvaluationResult: Sendable {
        let terminal: EvaluationTerminal
        let legacyEntry: EvaluationEntry?
        let candidateMovementBaseline: CandidateMovementBaseline?
        let protectedAction: CheckAction?

        init(
            terminal: EvaluationTerminal,
            legacyEntry: EvaluationEntry?,
            candidateMovementBaseline: CandidateMovementBaseline? = nil,
            protectedAction: CheckAction? = nil
        ) {
            self.terminal = terminal
            self.legacyEntry = legacyEntry
            self.candidateMovementBaseline = candidateMovementBaseline
            self.protectedAction = protectedAction
        }

        var hasIrreversibleEffect: Bool {
            switch terminal.outcome {
            case .submittedCheckIn, .submittedCheckOut, .queuedOfflineRaw, .queuedOfflineDecided,
                 .submissionOutcomeUnknown:
                true
            default:
                false
            }
        }

        var protectedActionAfterIrreversibleEffect: CheckAction? {
            hasIrreversibleEffect ? protectedAction : nil
        }
    }

    private struct AdmittedEvaluationResult: Sendable {
        let terminal: EvaluationTerminal
        let legacyEntries: [EvaluationEntry]
        let backgroundTaskToken: Int?
        let backgroundExecutionLease: BackgroundExecutionLease?
        let backgroundExecutionOwnerToken: BackgroundWorkOwnerToken?
        let ranLockedEvaluation: Bool
        let candidateMovementBaseline: CandidateMovementBaseline?
        let protectedAction: CheckAction?
    }

    private struct AccuracyRetryEpisode: Codable, Equatable {
        let id: String
        let chave: String
        let activeProject: String
        var nextRetryEpochMs: Int64
        var notificationPosted: Bool
        var expectedActionRaw: String?

        var nextRetryAt: Date {
            Date(timeIntervalSince1970: Double(nextRetryEpochMs) / 1_000)
        }

        var expectedAction: CheckAction? {
            switch expectedActionRaw {
            case "checkin": return .checkIn
            case "checkout": return .checkOut
            default: return nil
            }
        }
    }

    private enum ScheduledPauseDeferralPhase: String, Codable, Equatable {
        case awaitingCheckout
        case activationScheduled
        case active
        case terminal
    }

    /// Estado durável de uma única ocorrência da pausa. A configuração do usuário nunca é reescrita:
    /// este registro apenas diz se aquela ocorrência aguarda checkout ou os 10 segundos de carência.
    private struct ScheduledPauseDeferral: Codable, Equatable {
        let id: String
        let chave: String
        let activeProject: String
        let settings: ScheduledPauseSettings
        let windowStartEpochMs: Int64
        let windowEndEpochMs: Int64
        var phase: ScheduledPauseDeferralPhase
        var activationEpochMs: Int64?

        var windowStart: Date {
            Date(timeIntervalSince1970: Double(windowStartEpochMs) / 1_000)
        }
        var windowEnd: Date {
            Date(timeIntervalSince1970: Double(windowEndEpochMs) / 1_000)
        }
        var activationAt: Date? {
            activationEpochMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
        }
    }

    private enum ScheduledPauseGateResult {
        case proceed(currentState: HistoryState?, usedFreshState: Bool)
        case stop(ScheduledPauseStopReason)
    }

    // Dependências
    private let appPrefs: any AppPreferencesReading
    private let checkRepository: any CheckRepository
    private let runAutomaticActivities: any RunningAutomaticActivities
    private let locationProvider: any LocationProvider
    private let clock: any Clock
    private let authSessionCoordinator: any AuthSessionCoordinating
    private let accidentRepository: any AccidentStateReading
    private let activityLogger: any ActivityLogging
    private let notifications: any AutoActivityNotifying
    private let evaluationJournal: any EvaluationJournaling
    private let automaticEvaluationPipeline: BackgroundAutomaticEvaluationPipeline
    private let applicationStateProvider: any EvaluationApplicationStateProviding
    private let makeEvaluationID: @Sendable () -> EvaluationID
    private let backgroundTaskGuard: any BackgroundTaskGuard
    private let backgroundExecutionLeasing: any BackgroundExecutionLeasing
    private let pauseAlarms: any PauseAlarmScheduling
    private let accuracyRetrySleeper: any Sleeping
    private let pauseActivationSleeper: any Sleeping
    private let pauseTransitionSleeper: any Sleeping
    private let appRefreshScheduler: any AppRefreshScheduling

    // Estado (isolado pelo actor — sem @Volatile)
    private var isRunning = false
    private var runningWork: CanonicalWork?
    private var drainDriverID: UUID?
    private var drainDriver: Task<Void, Never>?
    private var servedInDrainCycle: Set<DrainClass> = []
    private var drainCycleLastIrreversibleAction: CheckAction?
    private var pendingPauseTransitionWork: CanonicalEvaluationWork?
    private var pendingPauseActivationWork: CanonicalEvaluationWork?
    private var pendingForegroundWork: CanonicalEvaluationWork?
    private var pendingAccuracyRetryWork: CanonicalEvaluationWork?
    private var pendingNormalWake: CanonicalEvaluationWork?
    private var pendingAccidentWork: CanonicalAccidentWork?
    private var pauseReconciliationRequired = false
    private var automationContextGeneration: UInt64 = 0
    private var lastLat: Double?
    private var lastLon: Double?
    private var lastCaptureAccuracyMeters: Double?
    private var cachedState: HistoryState?
    private var cacheChave = ""
    private var cachedStateAt = Date(timeIntervalSince1970: 0)
    private var cachedOptions: LocationOptions?
    private var cachedOptionsAt = Date(timeIntervalSince1970: 0)
    private var lastReauthNotificationAt = Date(timeIntervalSince1970: 0)
    private var accuracyRetryEpisode: AccuracyRetryEpisode?
    private var accuracyRetryTask: Task<Void, Never>?
    private var didRestoreAccuracyRetryEpisode = false
    private var accuracyRetryGeneration: UInt64 = 0
    private var scheduledPauseDeferral: ScheduledPauseDeferral?
    private var pauseActivationTask: Task<Void, Never>?
    private var pauseTransitionTask: Task<Void, Never>?
    private var pauseTransitionEpochMs: Int64?
    private var didRestoreScheduledPauseDeferral = false
    private var scheduledPauseGeneration: UInt64 = 0
    private var automationContextInvalidationInProgress = false
    private var automationContextInvalidationCompletion: SharedAccidentCompletion?
    private var automationContextTransitionToken: AutomationContextTransitionToken?
    private var automationContextQuiescenceWait: AutomationQuiescenceWait?
    private var automaticOperationID: UUID?
    private var cancelAutomaticOperation: (@Sendable () -> Void)?
    private var activeEvaluationEffectValidity: AutomaticActivitiesEvaluationValidity?

    var isRunningForTest: Bool { isRunning }
    var hasAccuracyRetryEpisodeForTest: Bool { accuracyRetryEpisode != nil }
    var nextAccuracyRetryAtForTest: Date? { accuracyRetryEpisode?.nextRetryAt }
    var hasPendingAccuracyRetryForTest: Bool { pendingAccuracyRetryWork != nil }
    var hasPendingNormalWakeForTest: Bool { pendingNormalWake != nil }
    var hasScheduledPauseDeferralForTest: Bool { scheduledPauseDeferral != nil }
    var scheduledPauseActivationAtForTest: Date? { scheduledPauseDeferral?.activationAt }

    init(appPrefs: any AppPreferencesReading, checkRepository: any CheckRepository,
         runAutomaticActivities: any RunningAutomaticActivities, locationProvider: any LocationProvider,
         clock: any Clock, authSessionCoordinator: any AuthSessionCoordinating,
         accidentRepository: any AccidentStateReading, activityLogger: any ActivityLogging,
         notifications: any AutoActivityNotifying,
         automaticEvaluationPipeline: BackgroundAutomaticEvaluationPipeline = .legacy,
         applicationStateProvider: (any EvaluationApplicationStateProviding)? = nil,
         evaluationJournal: any EvaluationJournaling = NoopEvaluationJournal(),
         makeEvaluationID: @escaping @Sendable () -> EvaluationID = { EvaluationID() },
         backgroundTaskGuard: any BackgroundTaskGuard = NoopBackgroundTaskGuard(),
         backgroundExecutionLeasing: any BackgroundExecutionLeasing = NoopBackgroundExecutionLeasing(),
         pauseAlarms: any PauseAlarmScheduling = NoopPauseAlarmScheduling(),
         accuracyRetrySleeper: any Sleeping = TaskSleeper(),
         pauseActivationSleeper: any Sleeping = TaskSleeper(),
         pauseTransitionSleeper: any Sleeping = TaskSleeper(),
        appRefreshScheduler: any AppRefreshScheduling = NoopAppRefreshScheduler()) {
        self.appPrefs = appPrefs; self.checkRepository = checkRepository; self.runAutomaticActivities = runAutomaticActivities
        self.locationProvider = locationProvider; self.clock = clock
        self.authSessionCoordinator = authSessionCoordinator
        self.accidentRepository = accidentRepository
        self.activityLogger = activityLogger; self.notifications = notifications
        self.evaluationJournal = evaluationJournal
        self.automaticEvaluationPipeline = automaticEvaluationPipeline
        self.applicationStateProvider =
            applicationStateProvider ?? UnknownEvaluationApplicationStateProvider()
        self.makeEvaluationID = makeEvaluationID
        self.backgroundTaskGuard = backgroundTaskGuard
        self.backgroundExecutionLeasing = backgroundExecutionLeasing
        self.pauseAlarms = pauseAlarms
        self.accuracyRetrySleeper = accuracyRetrySleeper
        self.pauseActivationSleeper = pauseActivationSleeper
        self.pauseTransitionSleeper = pauseTransitionSleeper
        self.appRefreshScheduler = appRefreshScheduler
    }

    // MARK: - Entrada e coordenador serial

    @discardableResult
    func runOnce(_ trigger: OrchestratorTrigger) async -> EvaluationCompletion {
        await runOnce(trigger, seedCandidate: nil)
    }

    /// Compatibilidade dos callers atuais: a classificação de admissão fica no ticket, enquanto este
    /// wrapper só retorna depois do terminal da avaliação canônica.
    @discardableResult
    func runOnce(
        _ trigger: OrchestratorTrigger,
        seedCandidate: LocationSample?
    ) async -> EvaluationCompletion {
        let ticket = await evaluationTicket(
            trigger,
            seedCandidate: seedCandidate,
            forceForegroundReconciliation: false,
            ownerRegistration: nil
        )
        return await ticket.completion()
    }

    /// Seam aguardável para owners de lease/orçamento. O Prompt 14 ligará o BGTask a este ticket; nesta
    /// fase ele já garante que preencher ou mesclar o slot não é confundido com conclusão.
    func evaluationTicket(
        _ trigger: OrchestratorTrigger,
        seedCandidate: LocationSample? = nil,
        ownerRegistration: BackgroundWorkOwnerRegistration? = nil
    ) async -> EvaluationTicket {
        await evaluationTicket(
            trigger,
            seedCandidate: seedCandidate,
            forceForegroundReconciliation: false,
            ownerRegistration: ownerRegistration
        )
    }

    private func evaluationTicket(
        _ trigger: OrchestratorTrigger,
        seedCandidate: LocationSample?,
        forceForegroundReconciliation: Bool,
        ownerRegistration: BackgroundWorkOwnerRegistration?
    ) async -> EvaluationTicket {
        let receivedAt = clock.now()
        let evaluationID = makeEvaluationID()
        let generationAtReceipt = automationContextGeneration
        let arrivedDuringContextTransition = automationContextInvalidationInProgress
        guard !arrivedDuringContextTransition else {
            ownerRegistration?.release()
            return staleContextTicket(for: evaluationID)
        }
        await waitForAutomationContextInvalidationIfNeeded()
        guard !Task.isCancelled,
              generationAtReceipt == automationContextGeneration else {
            ownerRegistration?.release()
            return staleContextTicket(for: evaluationID)
        }

        let appStateAtReceipt: EvaluationApplicationState
        switch automaticEvaluationPipeline {
        case .legacy:
            // Equivalência do build legado: não consulta lifecycle e preserva o snapshot histórico.
            appStateAtReceipt = .unknown
        case .candidate:
            appStateAtReceipt =
                await applicationStateProvider.currentApplicationState()
            guard !Task.isCancelled,
                  generationAtReceipt == automationContextGeneration else {
                ownerRegistration?.release()
                return staleContextTicket(for: evaluationID)
            }
        }

        let admittedSeedCandidate = admittedSignificantLocationSeed(
            trigger: trigger,
            seedCandidate: seedCandidate,
            receivedAt: clock.now()
        )
        let request = EvaluationRequest(
            id: evaluationID,
            trigger: trigger,
            receivedAt: receivedAt,
            sample: admittedSeedCandidate,
            appStateAtReceipt: appStateAtReceipt
        )
        return await admitEvaluationRequest(
            request,
            forceForegroundReconciliation: forceForegroundReconciliation,
            ownerRegistration: ownerRegistration
        )
    }

    private func admitEvaluationRequest(
        _ request: EvaluationRequest,
        forceForegroundReconciliation: Bool,
        ownerRegistration: BackgroundWorkOwnerRegistration?
    ) async -> EvaluationTicket {
        if !isRunning {
            let work = makeEvaluationWork(
                request,
                forceFreshState: false,
                initialStage: .restore,
                isPauseReconciliation: forceForegroundReconciliation,
                ownerRegistration: ownerRegistration
            )
            startDrainDriver(with: .evaluation(work))
            return ticket(for: work, admission: .admitted)
        }

        switch request.trigger {
        case .timer, .geofence, .significantLocation:
            guard automaticEvaluationPipeline == .candidate else {
                ownerRegistration?.release()
                return legacyDroppedTicket(for: request.id)
            }
            return await admitPendingNormal(
                request,
                ownerRegistration: ownerRegistration
            )

        case .foreground:
            // O Prompt 11 mantém FOREGROUND fora do pending normal. Somente o ticket especial criado
            // pela reconciliação explícita de pausa pode sobreviver a uma avaliação em voo; um wake
            // foreground comum conserva o drop histórico nesta fase.
            guard forceForegroundReconciliation else {
                ownerRegistration?.release()
                return legacyDroppedTicket(for: request.id)
            }
            return await admitSpecialPending(
                request,
                drainClass: .foregroundReconciliation,
                isPauseReconciliation: forceForegroundReconciliation,
                ownerRegistration: ownerRegistration
            )

        case .accuracyRetry:
            return await admitSpecialPending(
                request,
                drainClass: .accuracyRetry,
                ownerRegistration: ownerRegistration
            )

        case .pauseActivation:
            return await admitSpecialPending(
                request,
                drainClass: .pauseActivation,
                ownerRegistration: ownerRegistration
            )

        case .pauseTransition:
            return await admitSpecialPending(
                request,
                drainClass: .pauseTransition,
                ownerRegistration: ownerRegistration
            )
        }
    }

    private func admitPendingNormal(
        _ request: EvaluationRequest,
        ownerRegistration: BackgroundWorkOwnerRegistration?
    ) async -> EvaluationTicket {
        if var pending = pendingNormalWake {
            if let merged = PendingWakeMerge.mergePendingWake(
                current: pending.request,
                new: request,
                now: clock.now()
            ) {
                pending.request = merged
                pendingNormalWake = pending
            }
            ownerRegistration?.attach(to: pending.ownership)
            await pending.journalAdmission.value
            await recordCoalescedWakes(for: pending)
            return ticket(for: pending, admission: .coalesced)
        }

        let pending = makeEvaluationWork(
            request,
            forceFreshState: true,
            initialStage: .admitted,
            wasDeferred: true,
            ownerRegistration: ownerRegistration
        )
        pendingNormalWake = pending
        return ticket(for: pending, admission: .deferred)
    }

    private func admitSpecialPending(
        _ request: EvaluationRequest,
        drainClass: DrainClass,
        isPauseReconciliation: Bool = false,
        ownerRegistration: BackgroundWorkOwnerRegistration?
    ) async -> EvaluationTicket {
        if var pending = pendingEvaluation(for: drainClass) {
            pending.request = mergeEquivalentSpecialRequest(
                canonical: pending.request,
                new: request
            )
            pending.isPauseReconciliation =
                pending.isPauseReconciliation || isPauseReconciliation
            setPendingEvaluation(pending, for: drainClass)
            ownerRegistration?.attach(to: pending.ownership)
            await pending.journalAdmission.value
            await recordCoalescedWakes(for: pending)
            return ticket(for: pending, admission: .coalesced)
        }

        let pending = makeEvaluationWork(
            request,
            forceFreshState: false,
            initialStage: .admitted,
            wasDeferred: true,
            isPauseReconciliation: isPauseReconciliation,
            ownerRegistration: ownerRegistration
        )
        setPendingEvaluation(pending, for: drainClass)
        return ticket(for: pending, admission: .deferred)
    }

    private func mergeEquivalentSpecialRequest(
        canonical: EvaluationRequest,
        new: EvaluationRequest
    ) -> EvaluationRequest {
        let latest = canonical.receivedAt >= new.receivedAt ? canonical : new
        return EvaluationRequest(
            id: canonical.id,
            trigger: canonical.trigger,
            receivedAt: max(canonical.receivedAt, new.receivedAt),
            sample: nil,
            appStateAtReceipt: latest.appStateAtReceipt,
            sourceMask: canonical.sourceMask.union(new.sourceMask),
            wakeCounts: canonical.wakeCounts.merging(new.wakeCounts)
        )
    }

    private func makeEvaluationWork(
        _ request: EvaluationRequest,
        forceFreshState: Bool,
        initialStage: EvaluationStage,
        wasDeferred: Bool = false,
        isPauseReconciliation: Bool = false,
        ownerRegistration: BackgroundWorkOwnerRegistration? = nil
    ) -> CanonicalEvaluationWork {
        let journal = evaluationJournal
        let ownership = BackgroundWorkOwnership()
        ownerRegistration?.attach(to: ownership)
        let start = EvaluationStart(
            id: request.id,
            trigger: request.trigger.evaluationTrigger,
            primaryWake: request.trigger.evaluationWake,
            stage: initialStage,
            appState: request.appStateAtReceipt
        )
        return CanonicalEvaluationWork(
            request: request,
            isPauseReconciliation: isPauseReconciliation,
            automationContextGeneration: automationContextGeneration,
            forceFreshState: forceFreshState,
            wasDeferred: wasDeferred,
            journalPrimaryWake: request.trigger.evaluationWake,
            journalAdmission: Task { await journal.begin(start) },
            ownership: ownership,
            completion: SharedEvaluationCompletion()
        )
    }

    private func ticket(
        for work: CanonicalEvaluationWork,
        admission: EvaluationAdmission
    ) -> EvaluationTicket {
        let journal = evaluationJournal
        let journalAdmission = work.journalAdmission
        let evaluationID = work.request.id
        return EvaluationTicket(
            evaluationID: evaluationID,
            admission: admission,
            completionTask: work.completion.task,
            ownerExpirationReporter: { owner, cancelledCanonicalWork in
                // A expiração pode chegar depois do terminal lógico, mas antes de o framework receber
                // `setTaskCompleted`. Esperar o begin evita perder o vínculo se a admissão ainda estava
                // em voo; o journal aceita o update também depois de `finish`.
                await journalAdmission.value
                await journal.recordOwnerExpiration(
                    evaluationID: evaluationID,
                    owner: owner,
                    cancelledCanonicalWork: cancelledCanonicalWork
                )
            }
        )
    }

    private func legacyDroppedTicket(for evaluationID: EvaluationID) -> EvaluationTicket {
        let completion = EvaluationCompletion(
            evaluationID: evaluationID,
            outcome: .notAdmitted,
            completedBeforeExpiration: true,
            admitted: false
        )
        return EvaluationTicket(
            evaluationID: evaluationID,
            admission: .legacyDropped,
            completionTask: Task { completion }
        )
    }

    private func staleContextTicket(for evaluationID: EvaluationID) -> EvaluationTicket {
        let completion = EvaluationCompletion(
            evaluationID: evaluationID,
            outcome: .staleContext,
            completedBeforeExpiration: true,
            admitted: false
        )
        return EvaluationTicket(
            evaluationID: evaluationID,
            admission: .staleContext,
            completionTask: Task { completion }
        )
    }

    private func startDrainDriver(with firstWork: CanonicalWork) {
        precondition(!isRunning && runningWork == nil && drainDriver == nil)
        let driverID = UUID()
        isRunning = true
        runningWork = firstWork
        drainDriverID = driverID
        servedInDrainCycle.removeAll()
        drainCycleLastIrreversibleAction = nil
        drainDriver = Task { [weak self] in
            await self?.drainLoop(driverID: driverID)
        }
    }

    private func drainLoop(driverID: UUID) async {
        while self.drainDriverID == driverID, let current = runningWork {
            switch current {
            case .evaluation(let work):
                let completion: EvaluationCompletion
                switch automaticEvaluationPipeline {
                case .legacy:
                    completion = await performCanonicalEvaluation(work)
                case .candidate:
                    // Cancela somente a avaliação corrente, nunca o driver serial que ainda precisa
                    // drenar tickets bounded. O handler também cobre expiração anterior à instalação.
                    let evaluationTask = Task {
                        await self.performCanonicalEvaluation(work)
                    }
                    _ = work.ownership.cancellationContext
                        .installCancellationHandler { _ in evaluationTask.cancel() }
                    completion = await evaluationTask.value
                }
                let next = finishCurrentAndTakeNext(driverID: driverID)
                await work.completion.resolve(completion)
                if next == nil { return }

            case .accident(let work):
                if work.automationContextGeneration == automationContextGeneration {
                    await runAccidentCheckLocked(
                        automationGeneration: work.automationContextGeneration
                    )
                }
                let next = finishCurrentAndTakeNext(driverID: driverID)
                await work.completion.resolve()
                if next == nil { return }
            }
        }
    }

    /// Atualiza todo o estado do coordenador antes de resolver o ticket, porque o waiter pode reentrar no
    /// actor imediatamente. Não há `await` entre retirar o slot e instalar o próximo running.
    private func finishCurrentAndTakeNext(driverID: UUID) -> CanonicalWork? {
        guard drainDriverID == driverID else { return nil }
        runningWork = nil
        ensurePauseReconciliationPendingIfNeeded()
        let next = takeNextPendingWithFairness()
        runningWork = next
        if next == nil {
            isRunning = false
            drainDriver = nil
            drainDriverID = nil
            servedInDrainCycle.removeAll()
            drainCycleLastIrreversibleAction = nil
        }
        return next
    }

    private func ensurePauseReconciliationPendingIfNeeded() {
        guard pauseReconciliationRequired else { return }
        if var existing = pendingForegroundWork {
            existing.isPauseReconciliation = true
            pendingForegroundWork = existing
            return
        }
        let request = EvaluationRequest(
            id: makeEvaluationID(),
            trigger: .foreground,
            receivedAt: clock.now(),
            sample: nil,
            appStateAtReceipt: .unknown
        )
        pendingForegroundWork = makeEvaluationWork(
            request,
            forceFreshState: false,
            initialStage: .admitted,
            wasDeferred: true,
            isPauseReconciliation: true
        )
    }

    private func takeNextPendingWithFairness() -> CanonicalWork? {
        while true {
            for drainClass in DrainClass.allCases
            where !servedInDrainCycle.contains(drainClass) {
                if let next = takePending(drainClass) {
                    servedInDrainCycle.insert(drainClass)
                    return next
                }
            }
            guard hasAnyPendingWork else { return nil }
            // Restam somente classes já servidas neste ciclo. Um novo ciclo conserva o limite 0/1 por
            // classe e impede que wakes normais contínuos passem repetidamente à frente do acidente.
            servedInDrainCycle.removeAll()
        }
    }

    private var hasAnyPendingWork: Bool {
        pendingPauseTransitionWork != nil
            || pendingPauseActivationWork != nil
            || pendingForegroundWork != nil
            || pendingAccuracyRetryWork != nil
            || pendingNormalWake != nil
            || pendingAccidentWork != nil
    }

    private func takePending(_ drainClass: DrainClass) -> CanonicalWork? {
        switch drainClass {
        case .pauseTransition:
            guard let work = pendingPauseTransitionWork else { return nil }
            pendingPauseTransitionWork = nil
            return .evaluation(work)
        case .pauseActivation:
            guard let work = pendingPauseActivationWork else { return nil }
            pendingPauseActivationWork = nil
            return .evaluation(work)
        case .foregroundReconciliation:
            guard let work = pendingForegroundWork else { return nil }
            pendingForegroundWork = nil
            return .evaluation(work)
        case .accuracyRetry:
            guard let work = pendingAccuracyRetryWork else { return nil }
            pendingAccuracyRetryWork = nil
            return .evaluation(work)
        case .normal:
            guard let work = pendingNormalWake else { return nil }
            pendingNormalWake = nil
            return .evaluation(work)
        case .accident:
            guard let work = pendingAccidentWork else { return nil }
            pendingAccidentWork = nil
            return .accident(work)
        }
    }

    private func pendingEvaluation(for drainClass: DrainClass) -> CanonicalEvaluationWork? {
        switch drainClass {
        case .pauseTransition: pendingPauseTransitionWork
        case .pauseActivation: pendingPauseActivationWork
        case .foregroundReconciliation: pendingForegroundWork
        case .accuracyRetry: pendingAccuracyRetryWork
        case .normal: pendingNormalWake
        case .accident: nil
        }
    }

    private func setPendingEvaluation(
        _ work: CanonicalEvaluationWork?,
        for drainClass: DrainClass
    ) {
        switch drainClass {
        case .pauseTransition: pendingPauseTransitionWork = work
        case .pauseActivation: pendingPauseActivationWork = work
        case .foregroundReconciliation: pendingForegroundWork = work
        case .accuracyRetry: pendingAccuracyRetryWork = work
        case .normal: pendingNormalWake = work
        case .accident: break
        }
    }

    private func performCanonicalEvaluation(
        _ work: CanonicalEvaluationWork
    ) async -> EvaluationCompletion {
        await work.journalAdmission.value

        // Um owner pode expirar enquanto este ticket ainda ocupa o slot pending. Não avance para
        // `.drained`, restauração ou qualquer estágio de aquisição nesse caso: a única obrigação que
        // resta é preservar coalescência/expiração e emitir o terminal canônico.
        let pendingCancellation = work.ownership.cancellationContext.reason
            ?? (Task.isCancelled ? .taskCancelled : nil)
        if let pendingCancellation {
            await recordCoalescedWakes(for: work)
            await recordOwnerExpirations(
                work.ownership.expirationSnapshot,
                evaluationID: work.request.id
            )
            let terminal = terminalForCancellation(pendingCancellation, stage: .admitted)
            await evaluationJournal.finish(id: work.request.id, terminal: terminal)
            _ = work.ownership.finish()
            return EvaluationCompletion(
                evaluationID: work.request.id,
                outcome: terminal.outcome,
                completedBeforeExpiration: terminal.outcome != .expired
            )
        }

        await recordCoalescedWakes(for: work)
        if work.wasDeferred {
            await evaluationJournal.advance(EvaluationProgress(
                evaluationID: work.request.id,
                stage: .drained,
                effectiveTrigger: work.request.trigger.evaluationTrigger
            ))
        }
        let snapshot = EvaluationContextSnapshot(
            automation: work.automationContextGeneration,
            accuracyRetry: accuracyRetryGeneration,
            scheduledPause: scheduledPauseGeneration
        )
        let evaluationStartedAt = clock.now()
        let seed = admittedSignificantLocationSeed(
            trigger: work.request.trigger,
            seedCandidate: work.request.sample,
            receivedAt: evaluationStartedAt
        )
        let suppressingDuplicateOf = work.forceFreshState
            ? drainCycleLastIrreversibleAction
            : nil
        var evaluation: AdmittedEvaluationResult
        if snapshot.automation != automationContextGeneration {
            evaluation = admittedResult(.staleContext, stage: .restore)
        } else {
            evaluation = await runAdmittedEvaluation(
                work.request.trigger,
                contextGeneration: snapshot.automation,
                generation: snapshot.accuracyRetry,
                pauseGeneration: snapshot.scheduledPause,
                significantLocationSeedCandidate: seed,
                seedReceivedAt: evaluationStartedAt,
                forceFreshState: work.forceFreshState,
                suppressingDuplicateOf: suppressingDuplicateOf,
                ownership: work.ownership
            )
        }

        // No candidato, encerrar a lease física define o fim lógico do trabalho antes da persistência
        // diagnóstica. O snapshot é então congelado: expiração posterior pertence somente à disputa do
        // owner do sistema e não pode reabrir/cancelar uma avaliação já terminal.
        if automaticEvaluationPipeline == .candidate {
            evaluation.backgroundExecutionLease?.end()
            if let ownerToken = evaluation.backgroundExecutionOwnerToken {
                _ = work.ownership.release(ownerToken)
            }
            _ = work.ownership.finish()
        }

        let cancellationReason = work.ownership.cancellationContext.reason
        if let cancellationReason {
            let replacement = terminalForCancellation(
                cancellationReason,
                stage: evaluation.terminal.stage ?? .restore
            )
            evaluation = AdmittedEvaluationResult(
                terminal: preferredTerminal(evaluation.terminal, over: replacement),
                legacyEntries: evaluation.legacyEntries,
                backgroundTaskToken: evaluation.backgroundTaskToken,
                backgroundExecutionLease: evaluation.backgroundExecutionLease,
                backgroundExecutionOwnerToken: evaluation.backgroundExecutionOwnerToken,
                ranLockedEvaluation: evaluation.ranLockedEvaluation,
                candidateMovementBaseline: evaluation.candidateMovementBaseline,
                protectedAction: evaluation.protectedAction
            )
        }

        if let baseline = evaluation.candidateMovementBaseline,
           snapshot.automation == automationContextGeneration,
           snapshot.accuracyRetry == accuracyRetryGeneration,
           snapshot.scheduledPause == scheduledPauseGeneration,
           shouldCommitCandidateMovementBaseline(for: evaluation.terminal.outcome) {
            lastLat = baseline.latitude
            lastLon = baseline.longitude
        }
        // Uma avaliação do contexto anterior pode concluir um efeito irreversível depois que a transição
        // já zerou a proteção do ciclo. Ela conserva seu próprio terminal, mas jamais pode reinstalar a
        // ação no ciclo que agora pertence à nova conta/projeto/configuração.
        if let protectedAction = evaluation.protectedAction,
           snapshot.automation == automationContextGeneration {
            drainCycleLastIrreversibleAction = protectedAction
        }

        await recordOwnerExpirations(
            work.ownership.expirationSnapshot,
            evaluationID: work.request.id
        )
        await evaluationJournal.finish(id: work.request.id, terminal: evaluation.terminal)
        for entry in evaluation.legacyEntries {
            EvaluationLog.shared.record(entry)
        }
        if let token = evaluation.backgroundTaskToken {
            backgroundTaskGuard.end(token)
        }
        if automaticEvaluationPipeline == .legacy {
            _ = work.ownership.finish()
        }
        if work.isPauseReconciliation,
           evaluation.ranLockedEvaluation,
           snapshot.automation == automationContextGeneration,
           snapshot.accuracyRetry == accuracyRetryGeneration,
           snapshot.scheduledPause == scheduledPauseGeneration {
            pauseReconciliationRequired = false
        }
        let completedBeforeExpiration: Bool
        switch cancellationReason {
        case .some(.bgTaskExpired), .some(.uiBackgroundTimeExpired):
            completedBeforeExpiration = false
        default:
            completedBeforeExpiration = evaluation.terminal.outcome != .expired
        }
        return EvaluationCompletion(
            evaluationID: work.request.id,
            outcome: evaluation.terminal.outcome,
            completedBeforeExpiration: completedBeforeExpiration
        )
    }

    private func recordOwnerExpirations(
        _ snapshot: BackgroundWorkExpirationSnapshot,
        evaluationID: EvaluationID
    ) async {
        for owner in snapshot.expiredOwners {
            let journalOwner: EvaluationJournalOwnerKind = switch owner {
            case .bgAppRefresh: .bgAppRefresh
            case .uiBackgroundTask: .uiBackgroundTask
            case .bgProcessing: .bgProcessing
            }
            await evaluationJournal.recordOwnerExpiration(
                evaluationID: evaluationID,
                owner: journalOwner,
                cancelledCanonicalWork: snapshot.cancellingOwner == owner
            )
        }
    }

    private func recordCoalescedWakes(for work: CanonicalEvaluationWork) async {
        for wake in EvaluationWakeKind.allCases {
            let total = Int(work.request.wakeCounts.count(for: wake))
            let primary = wake == work.journalPrimaryWake ? 1 : 0
            let additional = max(0, total - primary)
            guard additional > 0 else { continue }
            await evaluationJournal.coalesce(EvaluationCoalescence(
                evaluationID: work.request.id,
                wake: wake,
                stage: .admitted,
                count: additional,
                targetCount: total,
                effectiveTrigger: work.request.trigger.evaluationTrigger
            ))
        }
    }

    private func runAdmittedEvaluation(
        _ trigger: OrchestratorTrigger,
        contextGeneration: UInt64,
        generation: UInt64,
        pauseGeneration: UInt64,
        significantLocationSeedCandidate: LocationSample?,
        seedReceivedAt: Date,
        forceFreshState: Bool,
        suppressingDuplicateOf: CheckAction?,
        ownership: BackgroundWorkOwnership
    ) async -> AdmittedEvaluationResult {
        // A restauração também pertence ao single-flight; isso impede duas invocações de observarem
        // `didRestore...` no meio de uma leitura persistida e perderem um episódio de cold start.
        await restoreAccuracyRetryEpisodeIfNeeded(armProcessTask: trigger != .accuracyRetry)
        await restoreScheduledPauseDeferralIfNeeded()
        if Task.isCancelled {
            return admittedResult(.cancelled, stage: .restore)
        }
        guard contextGeneration == automationContextGeneration,
              generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration else {
            return admittedResult(.staleContext, stage: .restore)
        }
        if trigger == .accuracyRetry {
            guard let episode = accuracyRetryEpisode else {
                appRefreshScheduler.clearAccuracyRetryDeadlineAndScheduleRegular()
                return admittedResult(.staleContext, stage: .restore)
            }
            guard episode.nextRetryAt <= clock.now() else {
                if accuracyRetryTask == nil { armAccuracyRetry(episode) }
                return admittedResult(.staleContext, stage: .restore)
            }
        }
        if trigger == .pauseActivation {
            let phase = scheduledPauseDeferral?.phase
            let hasPendingActivation =
                scheduledPauseDeferral?.activationAt != nil
                    && (phase == .activationScheduled || phase == .awaitingCheckout)
            if !hasPendingActivation {
                appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
                return admittedResult(.staleContext, stage: .pause)
            }
        }
        let token: Int?
        let executionLease: BackgroundExecutionLease?
        let executionOwnerToken: BackgroundWorkOwnerToken?
        switch automaticEvaluationPipeline {
        case .legacy:
            token = await backgroundTaskGuard.begin()
            executionLease = nil
            executionOwnerToken = nil
        case .candidate:
            guard let ownerToken = ownership.acquire(.uiBackgroundTask) else {
                return admittedResult(
                    terminalForCancellation(
                        ownership.cancellationContext.reason ?? .taskCancelled,
                        stage: .restore
                    )
                )
            }
            executionOwnerToken = ownerToken
            token = nil
            executionLease = await backgroundExecutionLeasing.begin(
                name: "Checking candidate automatic evaluation",
                onExpiration: {
                    _ = ownership.expire(
                        ownerToken,
                        reason: .uiBackgroundTimeExpired
                    )
                }
            )
        }
        if Task.isCancelled {
            return admittedResult(
                terminalForCancellation(
                    ownership.cancellationContext.reason ?? .taskCancelled,
                    stage: .restore
                ),
                backgroundTaskToken: token,
                backgroundExecutionLease: executionLease,
                backgroundExecutionOwnerToken: executionOwnerToken
            )
        }
        let sessionGeneration = await authSessionCoordinator.useCurrentSession()
        guard !Task.isCancelled else {
            return admittedResult(
                terminalForCancellation(
                    ownership.cancellationContext.reason ?? .taskCancelled,
                    stage: .restore
                ),
                backgroundTaskToken: token,
                backgroundExecutionLease: executionLease,
                backgroundExecutionOwnerToken: executionOwnerToken
            )
        }
        guard contextGeneration == automationContextGeneration,
              generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration,
              await authSessionCoordinator.isCurrent(sessionGeneration) else {
            return admittedResult(
                .staleContext,
                stage: .restore,
                backgroundTaskToken: token,
                backgroundExecutionLease: executionLease,
                backgroundExecutionOwnerToken: executionOwnerToken
            )
        }
        let evaluationEffectValidity = AutomaticActivitiesEvaluationValidity()
        activeEvaluationEffectValidity = evaluationEffectValidity
        defer {
            evaluationEffectValidity.invalidate()
            if activeEvaluationEffectValidity === evaluationEffectValidity {
                activeEvaluationEffectValidity = nil
            }
        }
        let authRetryBudget = EvaluationAuthRetryBudget(
            sessionGeneration: sessionGeneration,
            evaluationEffectValidity: evaluationEffectValidity
        )
        let first = await runOnceLocked(
            trigger,
            contextGeneration: contextGeneration,
            generation: generation,
            pauseGeneration: pauseGeneration,
            authRetryBudget: authRetryBudget,
            significantLocationSeedCandidate: significantLocationSeedCandidate,
            seedReceivedAt: seedReceivedAt,
            forceFreshState: forceFreshState,
            suppressingDuplicateOf: suppressingDuplicateOf)
        // Se o refresh compartilhado acordou para o retry, mas uma dependência anterior à captura
        // (por exemplo, opções de localização) falhou, não deixa o prazo consumido sem novo backstop.
        if trigger == .accuracyRetry, let episode = accuracyRetryEpisode,
           episode.nextRetryAt <= clock.now(), accuracyRetryTask == nil {
            await advanceAccuracyRetry(
                episode,
                sessionGeneration: authRetryBudget.sessionGeneration
            )
        }
        return AdmittedEvaluationResult(
            terminal: first.terminal,
            legacyEntries: first.legacyEntry.map { [$0] } ?? [],
            backgroundTaskToken: token,
            backgroundExecutionLease: executionLease,
            backgroundExecutionOwnerToken: executionOwnerToken,
            ranLockedEvaluation: true,
            candidateMovementBaseline: first.candidateMovementBaseline,
            protectedAction: first.protectedActionAfterIrreversibleEffect)
    }

    /// Acidente em background, independente do auto (§8/§10). Mesmo single-flight que `runOnce`.
    func runAccidentCheck() async {
        let generationAtReceipt = automationContextGeneration
        let arrivedDuringContextTransition = automationContextInvalidationInProgress
        guard !arrivedDuringContextTransition else { return }
        await waitForAutomationContextInvalidationIfNeeded()
        guard generationAtReceipt == automationContextGeneration else { return }
        let completion: SharedAccidentCompletion
        if isRunning {
            if let pending = pendingAccidentWork {
                completion = pending.completion
            } else {
                completion = SharedAccidentCompletion()
                pendingAccidentWork = CanonicalAccidentWork(
                    automationContextGeneration: automationContextGeneration,
                    completion: completion
                )
            }
        } else {
            completion = SharedAccidentCompletion()
            startDrainDriver(with: .accident(CanonicalAccidentWork(
                automationContextGeneration: automationContextGeneration,
                completion: completion
            )))
        }
        await completion.task.value
    }

    private func runAccidentCheckLocked(automationGeneration: UInt64) async {
        guard automationGeneration == automationContextGeneration else { return }
        let chave = await appPrefs.chave()
        guard automationGeneration == automationContextGeneration,
              !chave.isEmpty else { return }
        let lang = resolveEffectiveLanguageCode(await appPrefs.language())
        guard automationGeneration == automationContextGeneration else { return }
        let userSettings = await loadUserSettings(chave)
        guard automationGeneration == automationContextGeneration,
              userSettings.notifyAccident else { return }   // antes de QUALQUER query
        let sessionGeneration = await authSessionCoordinator.useCurrentSession()
        guard automationGeneration == automationContextGeneration,
              await authSessionCoordinator.isCurrent(sessionGeneration) else { return }
        let authRetryBudget = EvaluationAuthRetryBudget(
            sessionGeneration: sessionGeneration,
            evaluationEffectValidity: AutomaticActivitiesEvaluationValidity()
        )
        let wasUnauthorized = await maybeNotifyAccident(
            chave,
            notifyAccident: true,
            lang: lang,
            automationGeneration: automationGeneration,
            sessionGeneration: authRetryBudget.sessionGeneration
        )
        if wasUnauthorized,
           await terminalPreventingUnauthorizedRetry(
               stage: .settings,
               chave: chave,
               lang: lang,
               authRetryBudget: authRetryBudget,
               contextGeneration: automationGeneration,
               generation: accuracyRetryGeneration,
               pauseGeneration: scheduledPauseGeneration
           ) == nil {
            _ = await maybeNotifyAccident(
                chave,
                notifyAccident: true,
                lang: lang,
                automationGeneration: automationGeneration,
                sessionGeneration: authRetryBudget.sessionGeneration
            )
        }
    }

    // MARK: - Fluxo de 7 passos

    private func runOnceLocked(
        _ trigger: OrchestratorTrigger,
        contextGeneration: UInt64,
        generation: UInt64,
        pauseGeneration: UInt64,
        authRetryBudget: EvaluationAuthRetryBudget,
        significantLocationSeedCandidate: LocationSample?,
        seedReceivedAt: Date,
        forceFreshState: Bool,
        suppressingDuplicateOf: CheckAction?
    ) async -> LockedEvaluationResult {
        let effectGuard = Self.automaticActivitiesEffectGuard(
            for: authRetryBudget
        )
        guard contextGeneration == automationContextGeneration,
              generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration else {
            return lockedResult(.staleContext, stage: .restore)
        }
        guard !Task.isCancelled else {
            return lockedResult(.cancelled, stage: .restore)
        }
        // 1 — Auth
        let chave = await appPrefs.chave()
        guard !Task.isCancelled else {
            return lockedResult(.cancelled, stage: .settings)
        }
        guard contextGeneration == automationContextGeneration,
              generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration else {
            return lockedResult(.staleContext, stage: .settings)
        }
        if chave.isEmpty {
            await cancelAccuracyRetryEpisode()
            await cancelScheduledPauseRuntime(clearActiveFlag: true, lang: "pt")
            return lockedResult(.noKey, stage: .settings)
        }
        let lang = resolveEffectiveLanguageCode(await appPrefs.language())
        guard contextGeneration == automationContextGeneration,
              generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration else {
            return lockedResult(.staleContext, stage: .settings)
        }
        activityLogger.logTrigger(trigger.name)

        // 2 — Settings, acidente ANTES do gate, toggle, pausa
        let userSettings = await loadUserSettings(chave)
        guard !Task.isCancelled else {
            return lockedResult(.cancelled, stage: .settings)
        }
        guard contextGeneration == automationContextGeneration,
              generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration else {
            return lockedResult(.staleContext, stage: .settings)
        }
        if let episode = accuracyRetryEpisode,
           episode.chave != chave || episode.activeProject != userSettings.activeProject
                || userSettings.activeProject.isEmpty {
            await cancelAccuracyRetryEpisode()
        }
        // Um pedido BG já cancelado pode, em corrida, alcançar seu handler. Sem o episódio correspondente
        // ele é inócuo e não abre outro episódio por conta própria.
        if trigger == .accuracyRetry, accuracyRetryEpisode == nil {
            return lockedResult(.staleContext, stage: .settings)
        }
        let embeddedAccidentWasUnauthorized = await maybeNotifyAccident(
            chave,
            notifyAccident: userSettings.notifyAccident,
            lang: lang,
            automationGeneration: contextGeneration,
            sessionGeneration: authRetryBudget.sessionGeneration
        )
        if embeddedAccidentWasUnauthorized,
           await terminalPreventingUnauthorizedRetry(
               stage: .settings,
               chave: chave,
               lang: lang,
               authRetryBudget: authRetryBudget,
               contextGeneration: contextGeneration,
               generation: generation,
               pauseGeneration: pauseGeneration
           ) == nil {
            // Acidente é uma consulta auxiliar: repete somente essa dependência e nunca reinicia a
            // avaliação automática. Um segundo unauthorized permanece diagnosticável, mas não bloqueia
            // toggle/opções/matriz; o orçamento compartilhado impede qualquer loop de autenticação.
            let retryWasUnauthorized = await maybeNotifyAccident(
                chave,
                notifyAccident: userSettings.notifyAccident,
                lang: lang,
                automationGeneration: contextGeneration,
                sessionGeneration: authRetryBudget.sessionGeneration
            )
            guard authRetryBudget.sessionGeneration.isCurrentNow else {
                return lockedResult(.staleContext, stage: .settings)
            }
            if retryWasUnauthorized {
                postReauthNotificationCoalesced(lang)
                activityLogger.logError("Re-authentication required.")
            }
        }
        guard authRetryBudget.sessionGeneration.isCurrentNow else {
            return lockedResult(.staleContext, stage: .settings)
        }
        guard !Task.isCancelled else {
            return lockedResult(.cancelled, stage: .settings)
        }
        guard contextGeneration == automationContextGeneration,
              generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration else {
            return lockedResult(.staleContext, stage: .settings)
        }
        if automaticEvaluationPipeline == .candidate {
            let consentAt = await appPrefs.backgroundLocationConsentAt()
            guard contextGeneration == automationContextGeneration,
                  generation == accuracyRetryGeneration,
                  pauseGeneration == scheduledPauseGeneration else {
                return lockedResult(.staleContext, stage: .settings)
            }
            guard !consentAt.isEmpty else {
                return lockedResult(.notConfigured, stage: .settings)
            }
        }

        if !userSettings.automaticActivitiesEnabled {
            await cancelAccuracyRetryEpisode()
            await cancelScheduledPauseRuntime(clearActiveFlag: true, lang: lang)
            appRefreshScheduler.clearPauseTransitionDeadlineAndScheduleRegular()
            let legacyEntry = EvaluationEntry(
                at: clock.now(),
                trigger: trigger,
                accuracyMeters: nil,
                resolvedLocal: nil,
                decidedAction: nil,
                outcome: .toggleOff)
            activityLogger.logSystem("Automatic activities are OFF.", .warning)
            return lockedResult(.toggleOff, stage: .settings, legacyEntry: legacyEntry)
        }

        let pauseSettings = ScheduledPauseSettings(
            scheduledPauseEnabled: userSettings.scheduledPauseEnabled, scheduledPauseFrom: userSettings.scheduledPauseFrom,
            scheduledPauseTo: userSettings.scheduledPauseTo, suspendSaturdays: userSettings.suspendSaturdays,
            suspendSundays: userSettings.suspendSundays)
        let calendar = Calendar.current            // fuso do APARELHO para a pausa (§7)
        let now = clock.now()
        let pauseGate = await reconcileScheduledPauseGate(
            trigger: trigger,
            chave: chave,
            userSettings: userSettings,
            pauseSettings: pauseSettings,
            calendar: calendar,
            now: now,
            generation: pauseGeneration,
            automationGeneration: contextGeneration,
            accuracyGeneration: generation,
            authRetryBudget: authRetryBudget,
            lang: lang)
        guard !Task.isCancelled else {
            return lockedResult(.cancelled, stage: .pause)
        }
        guard contextGeneration == automationContextGeneration,
              generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration else {
            return lockedResult(.staleContext, stage: .pause)
        }
        let stateFromPauseGate: HistoryState?
        let usedFreshState: Bool
        switch pauseGate {
        case .stop(let reason):
            let legacyOutcome: EvaluationOutcome
            let terminal: EvaluationTerminal
            switch reason {
            case .paused:
                legacyOutcome = .paused
                terminal = makeTerminal(outcome: .paused, stage: .pause)
            case .noAction:
                legacyOutcome = .noAction
                terminal = makeTerminal(outcome: .noAction, stage: .pause)
            case .failure(let error):
                legacyOutcome = .networkError
                terminal = terminalForAPIError(error, stage: .state)
            case .terminal(let typedTerminal):
                legacyOutcome = .networkError
                terminal = typedTerminal
            }
            let legacyEntry = EvaluationEntry(
                at: clock.now(),
                trigger: trigger,
                accuracyMeters: nil,
                resolvedLocal: nil,
                decidedAction: nil,
                outcome: legacyOutcome)
            return LockedEvaluationResult(terminal: terminal, legacyEntry: legacyEntry)
        case .proceed(let currentState, let fresh):
            stateFromPauseGate = currentState
            usedFreshState = fresh
        }

        // 3 — Opções (TTL 15min + fallback offline)
        let authenticatedOptions = await getLocationOptionsWithAuthRetry(
            chave: chave,
            lang: lang,
            authRetryBudget: authRetryBudget,
            contextGeneration: contextGeneration,
            generation: generation,
            pauseGeneration: pauseGeneration
        )
        guard authRetryBudget.sessionGeneration.isCurrentNow else {
            return lockedResult(.staleContext, stage: .options)
        }
        guard !Task.isCancelled else {
            return lockedResult(.cancelled, stage: .options)
        }
        guard contextGeneration == automationContextGeneration,
              generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration else {
            return lockedResult(.staleContext, stage: .options)
        }
        let optionsResolution: BackgroundInputResolution<LocationOptions>
        switch authenticatedOptions {
        case .resolution(let resolution):
            optionsResolution = resolution
        case .terminal(let terminal):
            return LockedEvaluationResult(terminal: terminal, legacyEntry: nil)
        }
        guard let options = optionsResolution.value else {
            if let error = optionsResolution.failure {
                return LockedEvaluationResult(
                    terminal: terminalForAPIError(error, stage: .options),
                    legacyEntry: nil)
            }
            return lockedResult(.internalFailure, stage: .options)
        }

        let userProjects = UserProjects(projects: userSettings.projects, activeProject: userSettings.activeProject)
        let execution: AutomaticActivitiesExecution
        var candidateMovementBaseline: CandidateMovementBaseline?

        if automaticEvaluationPipeline == .candidate,
           trigger == .timer {
            guard authRetryBudget.sessionGeneration.isCurrentNow else {
                return lockedResult(.staleContext, stage: .acquisition)
            }
            // Candidate TIMER:
            // gates/projeto/opções/pausa → captura → movimento → match → state → matriz → submit/fila.
            // `finalSample` fecha o orçamento da avaliação: nenhuma continuação abaixo pode recapturar.
            switch await evaluateCandidateTimer(
                chave: chave,
                userProjects: userProjects,
                options: options,
                stateFromPauseGate: stateFromPauseGate,
                usedFreshState: usedFreshState,
                contextGeneration: contextGeneration,
                generation: generation,
                pauseGeneration: pauseGeneration,
                authRetryBudget: authRetryBudget,
                lang: lang,
                appliesMovementGate: accuracyRetryEpisode == nil,
                forceFreshState: forceFreshState,
                suppressingDuplicateOf: suppressingDuplicateOf,
                effectGuard: effectGuard
            ) {
            case .terminal(let terminal):
                return terminal
            case .execution(
                let candidateExecution,
                _,
                _,
                let movementBaseline
            ):
                execution = candidateExecution
                candidateMovementBaseline = movementBaseline
            }
        } else {
            // 4 — Skip-if-unchanged legado (só TIMER).
            // NB (fiel ao Kotlin): `lastCaptureAccuracyMeters` só é resetado aqui, no bloco TIMER. Uma run
            // .geofence/.significantLocation/.foreground registra o valor da última run TIMER (ou nil) —
            // mesmo comportamento do Android para todos os gatilhos orientados por evento.
            if trigger == .timer, accuracyRetryEpisode == nil {
                lastCaptureAccuracyMeters = nil
                let skipDecision = await shouldSkip(
                    options.accuracyThresholdMeters,
                    contextGeneration: contextGeneration,
                    generation: generation,
                    pauseGeneration: pauseGeneration,
                    sessionGeneration: authRetryBudget.sessionGeneration
                )
                guard contextGeneration == automationContextGeneration,
                      generation == accuracyRetryGeneration,
                      pauseGeneration == scheduledPauseGeneration,
                      authRetryBudget.sessionGeneration.isCurrentNow else {
                    return lockedResult(.staleContext, stage: .movement)
                }
                if Task.isCancelled {
                    return lockedResult(.cancelled, stage: .movement)
                }
                switch skipDecision {
                case .skip:
                    let legacyEntry = EvaluationEntry(
                        at: clock.now(),
                        trigger: trigger,
                        accuracyMeters: lastCaptureAccuracyMeters,
                        resolvedLocal: nil,
                        decidedAction: nil,
                        outcome: .skip)
                    activityLogger.logSystem("Auto-check skipped (no movement).", .info)
                    return lockedResult(
                        .skippedNoMovement,
                        stage: .movement,
                        legacyEntry: legacyEntry)
                case .cancelled:
                    return lockedResult(.cancelled, stage: .movement)
                case .run, .noFix:
                    break
                }
            }

            // 5–6 — Estado, projetos, motor, cache. Todos os triggers legados preservam a ordem anterior.
            let currentState: HistoryState?
            let forcedFreshStateFailure: ApiError?
            if usedFreshState {
                currentState = stateFromPauseGate
                forcedFreshStateFailure = nil
            } else {
                let authenticatedState = await getRemoteStateWithAuthRetry(
                    chave,
                    forceFresh: forceFreshState,
                    lang: lang,
                    authRetryBudget: authRetryBudget,
                    contextGeneration: contextGeneration,
                    generation: generation,
                    pauseGeneration: pauseGeneration
                )
                switch authenticatedState {
                case .terminal(let terminal):
                    return LockedEvaluationResult(terminal: terminal, legacyEntry: nil)
                case .resolution(let resolution):
                    currentState = resolution.value
                    forcedFreshStateFailure = forceFreshState
                        ? resolution.failure
                        : nil
                }
            }
            guard authRetryBudget.sessionGeneration.isCurrentNow else {
                return lockedResult(.staleContext, stage: .state)
            }
            guard !Task.isCancelled else {
                return lockedResult(.cancelled, stage: .state)
            }
            // Não deixa uma invalidação ocorrida durante auth/settings/state transformar esta run antiga em
            // uma avaliação nova. Uma invalidação durante o próprio use-case é filtrada abaixo.
            guard contextGeneration == automationContextGeneration,
                  generation == accuracyRetryGeneration,
                  pauseGeneration == scheduledPauseGeneration else {
                return lockedResult(.staleContext, stage: .state)
            }
            if let forcedFreshStateFailure {
                return LockedEvaluationResult(
                    terminal: terminalForAPIError(
                        forcedFreshStateFailure,
                        stage: .state
                    ),
                    legacyEntry: nil
                )
            }
            let locationAttempt = locationAttempt(
                for: trigger,
                seedCandidate: significantLocationSeedCandidate,
                receivedAt: seedReceivedAt,
                accuracyThresholdMeters: options.accuracyThresholdMeters
            )
            // O perfil escolhe um único pipeline, mas ambos precisam responder à invalidação explícita de
            // conta/projeto/OFF. O use-case preserva seus guards antes de match, fila e submit.
            if automaticEvaluationPipeline == .candidate,
               let phased = runAutomaticActivities
                    as? any PhasedRunningAutomaticActivities {
                let authenticatedExecution = await executeCandidateActivities(
                    phased,
                    chave: chave,
                    userProjects: userProjects,
                    currentState: currentState,
                    mixedZoneIntervalMinutes: options.mixedZoneIntervalMinutes,
                    accuracyThresholdMeters: options.accuracyThresholdMeters,
                    locationAttempt: locationAttempt,
                    suppressingDuplicateOf: suppressingDuplicateOf,
                    lang: lang,
                    authRetryBudget: authRetryBudget,
                    contextGeneration: contextGeneration,
                    generation: generation,
                    pauseGeneration: pauseGeneration,
                    effectGuard: effectGuard
                )
                switch authenticatedExecution {
                case .execution(let value): execution = value
                case .terminal(let terminal):
                    return LockedEvaluationResult(terminal: terminal, legacyEntry: nil)
                }
            } else {
                let initialExecution = await runCancellableAutomaticOperation {
                    await self.runAutomaticActivities.execute(
                        chave: chave,
                        userProjects: userProjects,
                        currentState: currentState,
                        mixedZoneIntervalMinutes: options.mixedZoneIntervalMinutes,
                        accuracyThresholdMeters: options.accuracyThresholdMeters,
                        locationAttempt: locationAttempt,
                        effectGuard: effectGuard
                    )
                }
                if let phased = runAutomaticActivities
                    as? any PhasedRunningAutomaticActivities {
                    let authenticatedExecution = await retryUnauthorizedMatchIfNeeded(
                        initialExecution,
                        phased: phased,
                        currentState: currentState,
                        suppressingDuplicateOf: suppressingDuplicateOf,
                        chave: chave,
                        lang: lang,
                        authRetryBudget: authRetryBudget,
                        contextGeneration: contextGeneration,
                        generation: generation,
                        pauseGeneration: pauseGeneration,
                        effectGuard: effectGuard
                    )
                    switch authenticatedExecution {
                    case .execution(let value): execution = value
                    case .terminal(let terminal):
                        return LockedEvaluationResult(terminal: terminal, legacyEntry: nil)
                    }
                } else {
                    execution = initialExecution
                }
            }
        }
        let result = execution.result
        let executionTerminal = terminalForExecution(execution)
        let executionLegacyEntry = legacyEntry(for: result, trigger: trigger)
        let executionLockedResult = LockedEvaluationResult(
            terminal: executionTerminal,
            legacyEntry: executionLegacyEntry,
            protectedAction: execution.submissionContext?.action)
        let sessionStillCurrent = await authSessionCoordinator.isCurrent(
            authRetryBudget.sessionGeneration
        )
        if !authRetryBudget.sessionGeneration.isCurrentNow || !sessionStillCurrent {
            return interruptedResult(
                preserving: executionLockedResult,
                replacement: makeTerminal(
                    outcome: .staleContext,
                    stage: executionTerminal.stage ?? .decision))
        }
        if contextGeneration != automationContextGeneration
            || generation != accuracyRetryGeneration
            || pauseGeneration != scheduledPauseGeneration {
            return interruptedResult(
                preserving: executionLockedResult,
                replacement: makeTerminal(
                    outcome: .staleContext,
                    stage: executionTerminal.stage ?? .decision))
        }
        if Task.isCancelled {
            return interruptedResult(
                preserving: executionLockedResult,
                replacement: makeTerminal(
                    outcome: .cancelled,
                    stage: executionTerminal.stage ?? .decision))
        }
        if case .submitted(_, _, let newState) = result {
            let acceptedAt = clock.now()
            guard authRetryBudget.sessionGeneration.isCurrentNow else {
                return interruptedResult(
                    preserving: executionLockedResult,
                    replacement: makeTerminal(
                        outcome: .staleContext,
                        stage: executionTerminal.stage ?? .decision))
            }
            cachedState = newState
            cacheChave = chave
            cachedStateAt = acceptedAt
        }
        guard authRetryBudget.sessionGeneration.isCurrentNow else {
            return interruptedResult(
                preserving: executionLockedResult,
                replacement: makeTerminal(
                    outcome: .staleContext,
                    stage: executionTerminal.stage ?? .decision))
        }
        await reconcileAccuracyRetryEpisode(
            after: result,
            trigger: trigger,
            chave: chave,
            activeProject: userSettings.activeProject,
            lang: lang,
            generation: generation,
            sessionGeneration: authRetryBudget.sessionGeneration)
        if !authRetryBudget.sessionGeneration.isCurrentNow
            || contextGeneration != automationContextGeneration
            || generation != accuracyRetryGeneration
            || pauseGeneration != scheduledPauseGeneration {
            return interruptedResult(
                preserving: executionLockedResult,
                replacement: makeTerminal(
                    outcome: .staleContext,
                    stage: executionTerminal.stage ?? .decision))
        }
        if Task.isCancelled {
            return interruptedResult(
                preserving: executionLockedResult,
                replacement: makeTerminal(
                    outcome: .cancelled,
                    stage: executionTerminal.stage ?? .decision))
        }
        if case .submitted(let action, _, let newState) = result {
            guard authRetryBudget.sessionGeneration.isCurrentNow else {
                return interruptedResult(
                    preserving: executionLockedResult,
                    replacement: makeTerminal(
                        outcome: .staleContext,
                        stage: executionTerminal.stage ?? .decision))
            }
            await reconcileAcceptedCheckForScheduledPause(
                chave: chave,
                project: userSettings.activeProject,
                action: action,
                newState: newState,
                expectedPauseGeneration: pauseGeneration,
                lang: lang,
                sessionGeneration: authRetryBudget.sessionGeneration)
        }
        if !authRetryBudget.sessionGeneration.isCurrentNow
            || contextGeneration != automationContextGeneration
            || generation != accuracyRetryGeneration
            || pauseGeneration != scheduledPauseGeneration {
            return interruptedResult(
                preserving: executionLockedResult,
                replacement: makeTerminal(
                    outcome: .staleContext,
                    stage: executionTerminal.stage ?? .decision))
        }
        if Task.isCancelled {
            return interruptedResult(
                preserving: executionLockedResult,
                replacement: makeTerminal(
                    outcome: .cancelled,
                    stage: executionTerminal.stage ?? .decision))
        }
        if case .noAction = result {
            activityLogger.logSystem("No action needed (already checked in/out).", .info)
        }

        // 7 — Notificação de atividade
        var finalTerminal = executionTerminal
        if !authRetryBudget.sessionGeneration.isCurrentNow
            || contextGeneration != automationContextGeneration {
            return interruptedResult(
                preserving: executionLockedResult,
                replacement: makeTerminal(
                    outcome: .staleContext,
                    stage: executionTerminal.stage ?? .notification
                )
            )
        }
        if case .submitted(let action, let local, _) = result,
           userSettings.notifyActivities {
            let shouldPostActivityNotification: Bool
            switch automaticEvaluationPipeline {
            case .legacy:
                // Contrato byte-equivalent do perfil publicado: somente o trigger decide foreground.
                shouldPostActivityNotification = trigger != .foreground
            case .candidate:
                let currentApplicationState =
                    await applicationStateProvider.currentApplicationState()
                guard contextGeneration == automationContextGeneration,
                      generation == accuracyRetryGeneration,
                      pauseGeneration == scheduledPauseGeneration,
                      authRetryBudget.sessionGeneration.isCurrentNow else {
                    return interruptedResult(
                        preserving: executionLockedResult,
                        replacement: makeTerminal(
                            outcome: .staleContext,
                            stage: executionTerminal.stage ?? .notification
                        )
                    )
                }
                guard !Task.isCancelled else {
                    return interruptedResult(
                        preserving: executionLockedResult,
                        replacement: makeTerminal(
                            outcome: .cancelled,
                            stage: executionTerminal.stage ?? .notification
                        )
                    )
                }
                // No candidato, o estado real no instante do submit é autoritativo. `unknown`,
                // inactive e background mantêm o comportamento conservador; apenas evidência positiva
                // de cena ativa suprime a notificação, independentemente do wake que iniciou o trabalho.
                shouldPostActivityNotification = currentApplicationState != .active
            }

            if shouldPostActivityNotification {
                guard authRetryBudget.sessionGeneration.isCurrentNow else {
                    return interruptedResult(
                        preserving: executionLockedResult,
                        replacement: makeTerminal(
                            outcome: .staleContext,
                            stage: executionTerminal.stage ?? .notification
                        )
                    )
                }
                notifications.postActivityNotification(
                    action: action,
                    local: local,
                    lang: lang
                )
                // O seam histórico é fire-and-forget e não confirma `UNUserNotificationCenter.add`. A
                // etapa registra a tentativa, mas o campo de confirmação permanece desconhecido.
                finalTerminal = replacing(
                    executionTerminal,
                    stage: .notification,
                    notificationScheduled: nil)
            } else {
                finalTerminal = replacing(
                    executionTerminal,
                    stage: executionTerminal.stage,
                    notificationScheduled: false)
            }
        } else if case .submitted = result {
            finalTerminal = replacing(
                executionTerminal,
                stage: executionTerminal.stage,
                notificationScheduled: false)
        }
        return LockedEvaluationResult(
            terminal: finalTerminal,
            legacyEntry: executionLegacyEntry,
            candidateMovementBaseline: candidateMovementBaseline,
            protectedAction: execution.submissionContext?.action)
    }

    // MARK: - Helpers

    private func admittedSignificantLocationSeed(
        trigger: OrchestratorTrigger,
        seedCandidate: LocationSample?,
        receivedAt: Date
    ) -> LocationSample? {
        guard automaticEvaluationPipeline == .candidate,
              trigger == .significantLocation,
              let seedCandidate else {
            return nil
        }

        // O threshold remoto ainda não foi resolvido. O piso zero usa a policy apenas para integridade e
        // frescor: tanto `.usable` quanto `.freshButTooInaccurate` são admissíveis e serão reclassificados
        // depois com o threshold real.
        switch LocationSamplePolicy.candidateTrial.validity(
            of: seedCandidate,
            now: receivedAt,
            requiredAccuracyMeters: Self.seedAdmissionAccuracyFloorMeters
        ) {
        case .usable, .freshButTooInaccurate:
            return seedCandidate
        case .stale, .invalid, .fromFuture:
            return nil
        }
    }

    private func locationAttempt(
        for trigger: OrchestratorTrigger,
        seedCandidate: LocationSample?,
        receivedAt: Date,
        accuracyThresholdMeters: Int
    ) -> LocationAttemptInput {
        guard automaticEvaluationPipeline == .candidate,
              trigger == .significantLocation,
              let seedCandidate else {
            return .acquire
        }

        // Primeira revalidação usa o instante que o ator carimbou na entrada. O use-case e o provider
        // voltam a validar com o clock vivo, inclusive imediatamente antes do matcher.
        switch LocationSamplePolicy.candidateTrial.validity(
            of: seedCandidate,
            now: receivedAt,
            requiredAccuracyMeters: accuracyThresholdMeters
        ) {
        case .usable, .freshButTooInaccurate:
            return .seedCandidate(seedCandidate)
        case .stale, .invalid, .fromFuture:
            return .acquire
        }
    }

    private func executeCandidateActivities(
        _ phased: any PhasedRunningAutomaticActivities,
        chave: String,
        userProjects: UserProjects,
        currentState: HistoryState?,
        mixedZoneIntervalMinutes: Int,
        accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput,
        suppressingDuplicateOf: CheckAction?,
        lang: String,
        authRetryBudget: EvaluationAuthRetryBudget,
        contextGeneration: UInt64,
        generation: UInt64,
        pauseGeneration: UInt64,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> AuthenticatedActivitiesExecution {
        switch phased.preflight(
            chave: chave,
            userProjects: userProjects,
            mixedZoneIntervalMinutes: mixedZoneIntervalMinutes
        ) {
        case .terminal(let execution):
            return .execution(execution)
        case .ready(let configuration):
            let preparation = await runCancellableAutomaticOperation {
                await phased.prepare(
                    configuration,
                    accuracyThresholdMeters: accuracyThresholdMeters,
                    locationAttempt: locationAttempt,
                    effectGuard: effectGuard
                )
            }
            return await completeAfterOptionalMatchAuthRetry(
                preparation,
                phased: phased,
                currentState: currentState,
                suppressingDuplicateOf: suppressingDuplicateOf,
                chave: chave,
                lang: lang,
                authRetryBudget: authRetryBudget,
                contextGeneration: contextGeneration,
                generation: generation,
                pauseGeneration: pauseGeneration,
                effectGuard: effectGuard
            )
        }
    }

    private func retryUnauthorizedMatchIfNeeded(
        _ execution: AutomaticActivitiesExecution,
        phased: any PhasedRunningAutomaticActivities,
        currentState: HistoryState?,
        suppressingDuplicateOf: CheckAction?,
        chave: String,
        lang: String,
        authRetryBudget: EvaluationAuthRetryBudget,
        contextGeneration: UInt64,
        generation: UInt64,
        pauseGeneration: UInt64,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> AuthenticatedActivitiesExecution {
        await completeAfterOptionalMatchAuthRetry(
            .terminal(execution),
            phased: phased,
            currentState: currentState,
            suppressingDuplicateOf: suppressingDuplicateOf,
            chave: chave,
            lang: lang,
            authRetryBudget: authRetryBudget,
            contextGeneration: contextGeneration,
            generation: generation,
            pauseGeneration: pauseGeneration,
            effectGuard: effectGuard
        )
    }

    private func completeAfterOptionalMatchAuthRetry(
        _ initialPreparation: AutomaticActivitiesPreparation,
        phased: any PhasedRunningAutomaticActivities,
        currentState: HistoryState?,
        suppressingDuplicateOf: CheckAction?,
        chave: String,
        lang: String,
        authRetryBudget: EvaluationAuthRetryBudget,
        contextGeneration: UInt64,
        generation: UInt64,
        pauseGeneration: UInt64,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> AuthenticatedActivitiesExecution {
        var preparation = initialPreparation
        if let retryContext = preparation.matchRetryContext {
            if let terminal = await terminalPreventingUnauthorizedRetry(
                stage: .match,
                chave: chave,
                lang: lang,
                authRetryBudget: authRetryBudget,
                contextGeneration: contextGeneration,
                generation: generation,
                pauseGeneration: pauseGeneration
            ) {
                return .terminal(terminal)
            }
            preparation = await runCancellableAutomaticOperation {
                await phased.prepare(
                    retryContext.configuration,
                    accuracyThresholdMeters: retryContext.accuracyThresholdMeters,
                    locationAttempt: retryContext.locationAttempt,
                    effectGuard: effectGuard
                )
            }
        }

        switch preparation {
        case .terminal(let execution):
            // `prepare` pode já ter observado uma captura/match cancelado. Não o reclassifique como
            // `.decision` só porque não há `PreparedAutomaticActivitiesMatch`: a expiração precisa
            // preservar o estágio mais avançado que realmente começou, e nenhum `complete`/submit pode
            // ser iniciado para um terminal de preparação.
            if let invalid = await invalidEvaluationContextTerminal(
                stage: evaluationStage(execution.trace.maximumStage, result: execution.result),
                authRetryBudget: authRetryBudget,
                contextGeneration: contextGeneration,
                generation: generation,
                pauseGeneration: pauseGeneration
            ) {
                return .terminal(invalid)
            }
            return .execution(execution)
        case .ready(let prepared):
            if let invalid = await invalidEvaluationContextTerminal(
                stage: prepared.requiresCurrentState ? .match : .decision,
                authRetryBudget: authRetryBudget,
                contextGeneration: contextGeneration,
                generation: generation,
                pauseGeneration: pauseGeneration
            ) {
                return .terminal(invalid)
            }
            let completed = await runCancellableAutomaticOperation {
                await phased.complete(
                    prepared,
                    currentState: currentState,
                    suppressingDuplicateOf: suppressingDuplicateOf,
                    effectGuard: effectGuard
                )
            }
            return .execution(completed)
        }
    }

    private func loadUserSettings(_ chave: String) async -> UserSettings {
        let rawJson = await appPrefs.userSettingsJson()
        let map = try? JSONCoding.decoder.decode([String: UserSettings].self, from: Data(rawJson.utf8))   // erro → nil
        return resolvePersistedUserSettings(map, chave)
    }

    // MARK: - Terminal durável

    private func admittedResult(
        _ outcome: EvaluationTerminalOutcome,
        stage: EvaluationStage,
        backgroundTaskToken: Int? = nil,
        backgroundExecutionLease: BackgroundExecutionLease? = nil,
        backgroundExecutionOwnerToken: BackgroundWorkOwnerToken? = nil
    ) -> AdmittedEvaluationResult {
        admittedResult(
            makeTerminal(outcome: outcome, stage: stage),
            backgroundTaskToken: backgroundTaskToken,
            backgroundExecutionLease: backgroundExecutionLease,
            backgroundExecutionOwnerToken: backgroundExecutionOwnerToken
        )
    }

    private func admittedResult(
        _ terminal: EvaluationTerminal,
        backgroundTaskToken: Int? = nil,
        backgroundExecutionLease: BackgroundExecutionLease? = nil,
        backgroundExecutionOwnerToken: BackgroundWorkOwnerToken? = nil
    ) -> AdmittedEvaluationResult {
        AdmittedEvaluationResult(
            terminal: terminal,
            legacyEntries: [],
            backgroundTaskToken: backgroundTaskToken,
            backgroundExecutionLease: backgroundExecutionLease,
            backgroundExecutionOwnerToken: backgroundExecutionOwnerToken,
            ranLockedEvaluation: false,
            candidateMovementBaseline: nil,
            protectedAction: nil)
    }

    private func lockedResult(
        _ outcome: EvaluationTerminalOutcome,
        stage: EvaluationStage,
        legacyEntry: EvaluationEntry? = nil
    ) -> LockedEvaluationResult {
        LockedEvaluationResult(
            terminal: makeTerminal(outcome: outcome, stage: stage),
            legacyEntry: legacyEntry)
    }

    private func makeTerminal(
        outcome: EvaluationTerminalOutcome,
        stage: EvaluationStage?,
        http: EvaluationHTTPDiagnostic? = nil
    ) -> EvaluationTerminal {
        EvaluationTerminal(
            outcome: outcome,
            stage: stage,
            durationBucket: .unknown,
            http: http)
    }

    private func replacing(
        _ terminal: EvaluationTerminal,
        stage: EvaluationStage?,
        notificationScheduled: Bool?
    ) -> EvaluationTerminal {
        EvaluationTerminal(
            outcome: terminal.outcome,
            stage: stage,
            durationBucket: terminal.durationBucket,
            locationSource: terminal.locationSource,
            captureReused: terminal.captureReused,
            accuracyBucket: terminal.accuracyBucket,
            ageBucket: terminal.ageBucket,
            coreLocationError: terminal.coreLocationError,
            http: terminal.http,
            notificationScheduled: notificationScheduled)
    }

    private func preferredTerminal(
        _ current: EvaluationTerminal,
        over candidate: EvaluationTerminal
    ) -> EvaluationTerminal {
        let currentPriority = terminalSelectionPriority(current.outcome)
        let candidatePriority = terminalSelectionPriority(candidate.outcome)
        let selected: EvaluationTerminal
        if currentPriority == candidatePriority {
            // Para duas evidências protegidas equivalentes (efeito confirmado ou cancelamento tipado), a
            // primeira é a mais conservadora. Para resultados comuns, a tentativa mais recente descreve
            // o desfecho final.
            selected = currentPriority > 0 ? current : candidate
        } else {
            selected = currentPriority > candidatePriority ? current : candidate
        }
        let stage = furthestStage(current.stage, candidate.stage)
        return EvaluationTerminal(
            outcome: selected.outcome,
            stage: stage,
            durationBucket: selected.durationBucket,
            locationSource: selected.locationSource
                ?? current.locationSource
                ?? candidate.locationSource,
            captureReused: selected.captureReused
                ?? current.captureReused
                ?? candidate.captureReused,
            accuracyBucket: selected.accuracyBucket
                ?? current.accuracyBucket
                ?? candidate.accuracyBucket,
            ageBucket: selected.ageBucket
                ?? current.ageBucket
                ?? candidate.ageBucket,
            coreLocationError: selected.coreLocationError
                ?? current.coreLocationError
                ?? candidate.coreLocationError,
            // HTTP pertence ao terminal escolhido; nunca misture status de uma tentativa anterior.
            http: selected.http,
            notificationScheduled: selected.notificationScheduled
        )
    }

    private func terminalSelectionPriority(_ outcome: EvaluationTerminalOutcome) -> Int {
        switch outcome {
        case .submittedCheckIn, .submittedCheckOut:
            return 6
        case .queuedOfflineRaw, .queuedOfflineDecided:
            return 5
        case .submissionOutcomeUnknown:
            return 4
        case .expired:
            return 3
        case .staleContext:
            return 2
        case .cancelled:
            return 1
        default:
            return 0
        }
    }

    private func furthestStage(
        _ lhs: EvaluationStage?,
        _ rhs: EvaluationStage?
    ) -> EvaluationStage? {
        switch (lhs, rhs) {
        case (let lhs?, let rhs?): .furthest(lhs, rhs)
        case (let lhs?, nil): lhs
        case (nil, let rhs?): rhs
        case (nil, nil): nil
        }
    }

    private func interruptedResult(
        preserving execution: LockedEvaluationResult,
        replacement: EvaluationTerminal
    ) -> LockedEvaluationResult {
        let terminal = preferredTerminal(execution.terminal, over: replacement)
        return LockedEvaluationResult(
            terminal: terminal,
            legacyEntry: execution.hasIrreversibleEffect ? execution.legacyEntry : nil,
            candidateMovementBaseline: execution.candidateMovementBaseline,
            protectedAction: execution.protectedActionAfterIrreversibleEffect)
    }

    private func shouldCommitCandidateMovementBaseline(
        for outcome: EvaluationTerminalOutcome
    ) -> Bool {
        switch outcome {
        case .cancelled, .expired, .staleContext, .abandoned:
            false
        default:
            true
        }
    }

    private func terminalForAPIError(
        _ error: ApiError,
        stage: EvaluationStage
    ) -> EvaluationTerminal {
        switch error {
        case .network:
            return makeTerminal(outcome: .networkFailure, stage: stage)
        case .unauthorized:
            return makeTerminal(outcome: .unauthorized, stage: stage)
        case .http:
            return makeTerminal(
                outcome: .httpRejected,
                stage: stage,
                http: EvaluationHTTPDiagnostic.sanitized(from: error))
        case .conflict:
            return makeTerminal(
                outcome: .conflict,
                stage: stage,
                http: EvaluationHTTPDiagnostic.sanitized(from: error))
        case .unknown:
            return makeTerminal(outcome: .internalFailure, stage: stage)
        }
    }

    private func terminalForExecution(
        _ execution: AutomaticActivitiesExecution
    ) -> EvaluationTerminal {
        let trace = execution.trace
        let maximumStage = evaluationStage(
            trace.maximumStage,
            result: execution.result)
        let terminal: EvaluationTerminal

        if automaticEvaluationPipeline == .candidate,
           execution.submissionContext != nil,
           trace.maximumStage == .submitStarted,
           case .some(.cancelled) = trace.failure {
            // O request foi despachado, mas o cancelamento venceu antes de uma resposta adotável. Sem
            // contrato server-side de idempotência comprovado, não há retry nem enqueue automático.
            terminal = makeTerminal(
                outcome: .submissionOutcomeUnknown,
                stage: .submit
            )
        } else if let offlineDisposition = trace.offlineDisposition {
            terminal = makeTerminal(
                outcome: offlineDisposition == .queuedRaw
                    ? .queuedOfflineRaw
                    : .queuedOfflineDecided,
                stage: offlineDisposition == .queuedRaw ? .match : .submit)
        } else if let failure = trace.failure?.sanitized {
            terminal = terminalForExecutionFailure(failure, fallbackStage: maximumStage)
        } else {
            terminal = terminalForLegacyResult(execution.result, stage: maximumStage)
        }
        return addingCaptureDiagnostics(terminal, capture: trace.capture)
    }

    private func terminalForExecutionFailure(
        _ failure: SanitizedAutomaticActivitiesFailure,
        fallbackStage: EvaluationStage
    ) -> EvaluationTerminal {
        switch failure {
        case .acquisition(let failure):
            switch failure {
            case .timeout:
                return makeTerminal(outcome: .locationTimeout, stage: .acquisition)
            case .unavailable:
                return makeTerminal(outcome: .unavailable, stage: .acquisition)
            case .permissionDenied:
                return makeTerminal(outcome: .permissionDenied, stage: .acquisition)
            case .cancelled(let reason):
                return terminalForCancellation(reason, stage: .acquisition)
            }
        case .sampleRejected(let validity):
            switch validity {
            case .usable:
                return makeTerminal(outcome: .internalFailure, stage: fallbackStage)
            case .freshButTooInaccurate:
                return makeTerminal(outcome: .accuracyTooLow, stage: .acquisition)
            case .stale:
                return makeTerminal(outcome: .staleContext, stage: .acquisition)
            case .invalid, .fromFuture:
                return makeTerminal(outcome: .unavailable, stage: .acquisition)
            }
        case .match(let failure):
            return terminalForSanitizedAPIError(failure, stage: .match)
        case .submit(let failure):
            return terminalForSanitizedAPIError(failure, stage: .submit)
        case .cancelled(let reason):
            return terminalForCancellation(reason, stage: fallbackStage)
        }
    }

    private func terminalForSanitizedAPIError(
        _ failure: SanitizedAutomaticApiFailure,
        stage: EvaluationStage
    ) -> EvaluationTerminal {
        switch failure.kind {
        case .network:
            return makeTerminal(outcome: .networkFailure, stage: stage)
        case .unauthorized:
            return makeTerminal(outcome: .unauthorized, stage: stage)
        case .http:
            return makeTerminal(
                outcome: .httpRejected,
                stage: stage,
                http: EvaluationHTTPDiagnostic(status: failure.httpStatus))
        case .conflict:
            return makeTerminal(
                outcome: .conflict,
                stage: stage,
                http: EvaluationHTTPDiagnostic(status: failure.httpStatus))
        case .unknown:
            return makeTerminal(outcome: .internalFailure, stage: stage)
        }
    }

    private func terminalForCancellation(
        _ reason: EvaluationCancellationReason,
        stage: EvaluationStage
    ) -> EvaluationTerminal {
        let outcome: EvaluationTerminalOutcome
        switch reason {
        case .bgTaskExpired, .uiBackgroundTimeExpired:
            outcome = .expired
        case .contextInvalidated:
            outcome = .staleContext
        case .taskCancelled:
            outcome = .cancelled
        }
        return makeTerminal(outcome: outcome, stage: stage)
    }

    private func terminalForLegacyResult(
        _ result: AutoActivitiesResult,
        stage: EvaluationStage
    ) -> EvaluationTerminal {
        switch result {
        case .submitted(let action, _, _):
            return makeTerminal(
                outcome: action == .checkIn ? .submittedCheckIn : .submittedCheckOut,
                stage: .submit)
        case .accuracyTooLow:
            return makeTerminal(outcome: .accuracyTooLow, stage: .match)
        case .locationTimeout:
            return makeTerminal(outcome: .locationTimeout, stage: stage)
        case .noPermission:
            // A fachada legada não distingue permissionDenied de unavailable; sem falha tipada, não
            // inventamos que o usuário negou a permissão.
            return makeTerminal(outcome: .unavailable, stage: stage)
        case .noAction:
            return makeTerminal(outcome: .noAction, stage: .decision)
        case .networkError:
            return makeTerminal(outcome: .networkFailure, stage: stage)
        case .notConfigured:
            return makeTerminal(outcome: .notConfigured, stage: .settings)
        }
    }

    private func evaluationStage(
        _ stage: AutomaticActivitiesStage,
        result: AutoActivitiesResult
    ) -> EvaluationStage {
        if case .notConfigured = result {
            return .settings
        }
        switch stage {
        case .started, .admitted, .captureStarted, .captured:
            return .acquisition
        case .matched:
            return .match
        case .decisionCompleted:
            return .decision
        case .submitStarted, .submitted:
            return .submit
        }
    }

    private func addingCaptureDiagnostics(
        _ terminal: EvaluationTerminal,
        capture: AutomaticCaptureTrace?
    ) -> EvaluationTerminal {
        guard let capture else { return terminal }
        let locationSource: EvaluationLocationSource
        switch capture.source {
        case .freshCapture:
            locationSource = .freshCapture
        case .seed:
            locationSource = .seed
        case .bestPartial:
            locationSource = .bestPartial
        }
        let accuracyBucket: EvaluationAccuracyBucket
        switch capture.accuracyBucket {
        case .zeroTo10Meters:
            accuracyBucket = .zeroTo10Meters
        case .elevenTo25Meters:
            accuracyBucket = .elevenTo25Meters
        case .twentySixTo50Meters:
            accuracyBucket = .twentySixTo50Meters
        case .fiftyOneTo100Meters:
            accuracyBucket = .fiftyOneTo100Meters
        case .over100Meters:
            accuracyBucket = .over100Meters
        case .unknown:
            accuracyBucket = .unknown
        }
        let ageBucket: EvaluationAgeBucket
        switch capture.ageBucket {
        case .under1Second:
            ageBucket = .under1Second
        case .oneTo5Seconds:
            ageBucket = .oneTo5Seconds
        case .sixTo15Seconds:
            ageBucket = .sixTo15Seconds
        case .over15Seconds:
            ageBucket = .over15Seconds
        case .unknown:
            ageBucket = .unknown
        }
        return EvaluationTerminal(
            outcome: terminal.outcome,
            stage: terminal.stage,
            durationBucket: terminal.durationBucket,
            locationSource: locationSource,
            captureReused: capture.reused,
            accuracyBucket: accuracyBucket,
            ageBucket: ageBucket,
            coreLocationError: terminal.coreLocationError,
            http: terminal.http,
            notificationScheduled: terminal.notificationScheduled)
    }

    private func legacyEntry(
        for result: AutoActivitiesResult,
        trigger: OrchestratorTrigger
    ) -> EvaluationEntry {
        EvaluationEntry(
            at: clock.now(),
            trigger: trigger,
            accuracyMeters: lastCaptureAccuracyMeters,
            resolvedLocal: submittedLocal(result),
            decidedAction: submittedActionName(result),
            outcome: outcome(of: result))
    }

    // MARK: - Exceção da Pausa Programada

    private func reconcileScheduledPauseGate(
        trigger: OrchestratorTrigger,
        chave: String,
        userSettings: UserSettings,
        pauseSettings: ScheduledPauseSettings,
        calendar: Calendar,
        now: Date,
        generation: UInt64,
        automationGeneration: UInt64,
        accuracyGeneration: UInt64,
        authRetryBudget: EvaluationAuthRetryBudget,
        lang: String
    ) async -> ScheduledPauseGateResult {
        let sessionGeneration = authRetryBudget.sessionGeneration
        guard generation == scheduledPauseGeneration,
              sessionGeneration.isCurrentNow else {
            return .stop(.terminal(makeTerminal(outcome: .staleContext, stage: .pause)))
        }

        let persistedFlag = await appPrefs.getFlag(Self.flagPauseActive)
        guard generation == scheduledPauseGeneration,
              sessionGeneration.isCurrentNow else {
            return .stop(.terminal(makeTerminal(outcome: .staleContext, stage: .pause)))
        }

        guard let window = currentScheduledPauseWindow(now, calendar, pauseSettings) else {
            let endedRuntime = scheduledPauseDeferral
            let hasPauseStateToCleanUp = endedRuntime != nil || persistedFlag
            let shouldNotifyEnd = persistedFlag
                && endedRuntime?.phase == .active
                && endedRuntime?.chave == chave
                && endedRuntime?.activeProject == userSettings.activeProject
            var preserveConsumedResumeNotification = false
            if shouldNotifyEnd {
                let alreadyScheduled = await pauseAlarms.consumeScheduledTransition(
                    started: false,
                    dueAtOrBefore: now)
                guard generation == scheduledPauseGeneration,
                      sessionGeneration.isCurrentNow else {
                    return .stop(.terminal(
                        makeTerminal(outcome: .staleContext, stage: .pause)))
                }
                preserveConsumedResumeNotification =
                    alreadyScheduled && userSettings.notifyScheduledPause
                if userSettings.notifyScheduledPause && !alreadyScheduled {
                    guard sessionGeneration.isCurrentNow else {
                        return .stop(.terminal(
                            makeTerminal(outcome: .staleContext, stage: .pause)))
                    }
                    notifications.postScheduledPauseTransition(started: false, lang: lang)
                }
                activityLogger.logActive("Scheduled pause ended.")
            }
            if hasPauseStateToCleanUp {
                await cancelScheduledPauseRuntime(
                    clearActiveFlag: true,
                    lang: lang,
                    preserveResumeNotification: preserveConsumedResumeNotification,
                    sessionGeneration: sessionGeneration)
            }
            guard generation == scheduledPauseGeneration,
                  sessionGeneration.isCurrentNow else {
                return .stop(.terminal(makeTerminal(outcome: .staleContext, stage: .pause)))
            }
            if let nextStart = nextPauseStartInstant(now, calendar, pauseSettings) {
                armScheduledPauseTransition(at: nextStart)
            } else {
                pauseTransitionTask?.cancel()
                pauseTransitionTask = nil
                pauseTransitionEpochMs = nil
                appRefreshScheduler.clearPauseTransitionDeadlineAndScheduleRegular()
            }
            // Não agenda notificação local de início: ela poderia afirmar uma pausa que será adiada.
            await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
            guard sessionGeneration.isCurrentNow else {
                return .stop(.terminal(makeTerminal(outcome: .staleContext, stage: .pause)))
            }
            if hasPauseStateToCleanUp && !preserveConsumedResumeNotification {
                await pauseAlarms.scheduleResume(at: nil, notify: false, lang: lang)
            }
            guard sessionGeneration.isCurrentNow else {
                return .stop(.terminal(makeTerminal(outcome: .staleContext, stage: .pause)))
            }
            return .proceed(currentState: nil, usedFreshState: false)
        }

        guard sessionGeneration.isCurrentNow else {
            return .stop(.terminal(makeTerminal(outcome: .staleContext, stage: .pause)))
        }
        armScheduledPauseTransition(at: window.end)
        if let runtime = scheduledPauseDeferral,
           !scheduledPauseRuntime(
               runtime,
               matchesChave: chave,
               activeProject: userSettings.activeProject,
               settings: pauseSettings,
               window: window) {
            await cancelScheduledPauseRuntime(
                clearActiveFlag: true,
                lang: lang,
                sessionGeneration: sessionGeneration)
        } else if scheduledPauseDeferral == nil, persistedFlag {
            // O bool legado/global não é identidade suficiente para outra conta/projeto/ocorrência.
            await appPrefs.setFlag(Self.flagPauseActive, false)
            guard sessionGeneration.isCurrentNow else {
                return .stop(.terminal(makeTerminal(outcome: .staleContext, stage: .pause)))
            }
            await pauseAlarms.scheduleResume(at: nil, notify: false, lang: lang)
        }
        guard generation == scheduledPauseGeneration,
              sessionGeneration.isCurrentNow else {
            return .stop(.terminal(makeTerminal(outcome: .staleContext, stage: .pause)))
        }

        switch scheduledPauseDeferral?.phase {
        case .active:
            await maintainActiveScheduledPause(
                window: window,
                userSettings: userSettings,
                generation: generation,
                lang: lang,
                sessionGeneration: sessionGeneration)
            guard sessionGeneration.isCurrentNow else {
                return .stop(.terminal(makeTerminal(outcome: .staleContext, stage: .pause)))
            }
            return .stop(.paused)

        case .terminal:
            await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
            guard sessionGeneration.isCurrentNow else {
                return .stop(.terminal(makeTerminal(outcome: .staleContext, stage: .pause)))
            }
            await pauseAlarms.scheduleResume(at: nil, notify: false, lang: lang)
            guard sessionGeneration.isCurrentNow else {
                return .stop(.terminal(makeTerminal(outcome: .staleContext, stage: .pause)))
            }
            appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
            guard sessionGeneration.isCurrentNow else {
                return .stop(.terminal(makeTerminal(outcome: .staleContext, stage: .pause)))
            }
            await cancelAccuracyRetryEpisode()
            guard sessionGeneration.isCurrentNow else {
                return .stop(.terminal(makeTerminal(outcome: .staleContext, stage: .pause)))
            }
            return .stop(.noAction)

        case .activationScheduled:
            guard let runtime = scheduledPauseDeferral,
                  let dueAt = runtime.activationAt else {
                await transitionScheduledPauseToAwaiting(
                    chave: chave,
                    activeProject: userSettings.activeProject,
                    settings: pauseSettings,
                    window: window,
                    generation: generation,
                    lang: lang,
                    sessionGeneration: sessionGeneration)
                guard sessionGeneration.isCurrentNow else {
                    return .stop(.terminal(
                        makeTerminal(outcome: .staleContext, stage: .pause)))
                }
                return .proceed(currentState: nil, usedFreshState: false)
            }
            if dueAt >= window.end {
                await transitionScheduledPauseToTerminal(
                    runtime,
                    generation: generation,
                    lang: lang,
                    sessionGeneration: sessionGeneration)
                guard sessionGeneration.isCurrentNow else {
                    return .stop(.terminal(
                        makeTerminal(outcome: .staleContext, stage: .pause)))
                }
                await cancelAccuracyRetryEpisode()
                guard sessionGeneration.isCurrentNow else {
                    return .stop(.terminal(
                        makeTerminal(outcome: .staleContext, stage: .pause)))
                }
                return .stop(.noAction)
            }
            if dueAt > now {
                guard sessionGeneration.isCurrentNow else {
                    return .stop(.terminal(
                        makeTerminal(outcome: .staleContext, stage: .pause)))
                }
                await cancelAccuracyRetryEpisode()
                guard sessionGeneration.isCurrentNow else {
                    return .stop(.terminal(
                        makeTerminal(outcome: .staleContext, stage: .pause)))
                }
                await armScheduledPauseActivation(
                    runtime,
                    userSettings: userSettings,
                    generation: generation,
                    lang: lang,
                    sessionGeneration: sessionGeneration)
                guard sessionGeneration.isCurrentNow else {
                    return .stop(.terminal(
                        makeTerminal(outcome: .staleContext, stage: .pause)))
                }
                return .stop(.noAction)
            }

            switch await getRemoteStateWithAuthRetry(
                chave,
                forceFresh: true,
                lang: lang,
                authRetryBudget: authRetryBudget,
                contextGeneration: automationGeneration,
                generation: accuracyGeneration,
                pauseGeneration: generation
            ) {
            case .resolution(.resolved(let state, _, _)):
                guard generation == scheduledPauseGeneration,
                      sessionGeneration.isCurrentNow else {
                    return .stop(.terminal(
                        makeTerminal(outcome: .staleContext, stage: .pause)))
                }
                switch resolveLastRecordedAction(state) {
                case .checkIn:
                    await transitionScheduledPauseToAwaiting(
                        chave: chave,
                        activeProject: userSettings.activeProject,
                        settings: pauseSettings,
                        window: window,
                        generation: generation,
                        lang: lang,
                        sessionGeneration: sessionGeneration)
                    guard sessionGeneration.isCurrentNow else {
                        return .stop(.terminal(
                            makeTerminal(outcome: .staleContext, stage: .pause)))
                    }
                    return .proceed(currentState: state, usedFreshState: true)

                case .checkOut:
                    // O estado fresco pode conter um checkout mais novo que aquele que originou o
                    // deadline (inclusive vindo de outro cliente). Reancora sempre pelos dados da API
                    // para preservar os dez segundos completos antes de ativar a pausa.
                    let result = await scheduleOrActivateAfterConfirmedCheckout(
                        state: state,
                        chave: chave,
                        activeProject: userSettings.activeProject,
                        settings: pauseSettings,
                        window: window,
                        userSettings: userSettings,
                        generation: generation,
                        now: now,
                        lang: lang,
                        sessionGeneration: sessionGeneration)
                    guard sessionGeneration.isCurrentNow else {
                        return .stop(.terminal(
                            makeTerminal(outcome: .staleContext, stage: .pause)))
                    }
                    return result

                case nil:
                    await activateScheduledPause(
                        runtime,
                        userSettings: userSettings,
                        generation: generation,
                        now: now,
                        lang: lang,
                        sessionGeneration: sessionGeneration)
                    guard sessionGeneration.isCurrentNow else {
                        return .stop(.terminal(
                            makeTerminal(outcome: .staleContext, stage: .pause)))
                    }
                    return .stop(.paused)
                }

            case .resolution(.failed(let error)):
                // Sem confirmação não converte grace em ACTIVE. Voltar a AWAITING conserva a
                // possibilidade de um estado confirmado/foreground resolver antes do próximo wake.
                await transitionScheduledPauseToAwaiting(
                    chave: chave,
                    activeProject: userSettings.activeProject,
                    settings: pauseSettings,
                    window: window,
                    generation: generation,
                    lang: lang,
                    sessionGeneration: sessionGeneration)
                guard sessionGeneration.isCurrentNow else {
                    return .stop(.terminal(
                        makeTerminal(outcome: .staleContext, stage: .pause)))
                }
                guard generation == scheduledPauseGeneration,
                      let awaitingRuntime = scheduledPauseDeferral else {
                    return .stop(.failure(error))
                }
                if shouldRetryScheduledPauseConfirmation(error) {
                    await scheduleScheduledPauseConfirmationRetry(
                        awaitingRuntime,
                        retryAt: now.addingTimeInterval(Self.scheduledPauseActivationDelay),
                        userSettings: userSettings,
                        generation: generation,
                        lang: lang,
                        sessionGeneration: sessionGeneration)
                    guard sessionGeneration.isCurrentNow else {
                        return .stop(.terminal(
                            makeTerminal(outcome: .staleContext, stage: .pause)))
                    }
                }
                return .stop(.failure(error))
            case .terminal(let terminal):
                // Unauthorized/relogin failure is still an unconfirmed remote state. Preserve the
                // conservative awaiting phase and remove the elapsed activation deadline, exactly as the
                // typed `.resolution(.failed)` path did before stage-scoped authentication was introduced.
                await transitionScheduledPauseToAwaiting(
                    chave: chave,
                    activeProject: userSettings.activeProject,
                    settings: pauseSettings,
                    window: window,
                    generation: generation,
                    lang: lang,
                    sessionGeneration: authRetryBudget.sessionGeneration)
                guard sessionGeneration.isCurrentNow else {
                    return .stop(.terminal(
                        makeTerminal(outcome: .staleContext, stage: .pause)))
                }
                return .stop(.terminal(terminal))
            }

        case .awaitingCheckout, nil:
            switch await getRemoteStateWithAuthRetry(
                chave,
                forceFresh: true,
                lang: lang,
                authRetryBudget: authRetryBudget,
                contextGeneration: automationGeneration,
                generation: accuracyGeneration,
                pauseGeneration: generation
            ) {
            case .resolution(.failed(let error)):
                let previousRetryAt =
                    scheduledPauseDeferral?.phase == .awaitingCheckout
                        ? scheduledPauseDeferral?.activationAt
                        : nil
                await transitionScheduledPauseToAwaiting(
                    chave: chave,
                    activeProject: userSettings.activeProject,
                    settings: pauseSettings,
                    window: window,
                    generation: generation,
                    lang: lang,
                    sessionGeneration: sessionGeneration)
                guard sessionGeneration.isCurrentNow else {
                    return .stop(.terminal(
                        makeTerminal(outcome: .staleContext, stage: .pause)))
                }
                guard generation == scheduledPauseGeneration,
                      let runtime = scheduledPauseDeferral else {
                    return .stop(.failure(error))
                }
                if shouldRetryScheduledPauseConfirmation(error) {
                    let retryAt: Date
                    if let previousRetryAt, previousRetryAt > now {
                        retryAt = previousRetryAt
                    } else {
                        retryAt = now.addingTimeInterval(
                            previousRetryAt == nil
                                ? Self.scheduledPauseActivationDelay
                                : Self.scheduledPauseConfirmationBackoff)
                    }
                    // A confirmação remota é conservadora: uma falha nunca equivale a "sem check-in".
                    // O primeiro retry transitório é rápido; falhas consecutivas recuam para três minutos
                    // para não consultar a API seis vezes por minuto durante uma indisponibilidade longa.
                    await scheduleScheduledPauseConfirmationRetry(
                        runtime,
                        retryAt: retryAt,
                        userSettings: userSettings,
                        generation: generation,
                        lang: lang,
                        sessionGeneration: sessionGeneration)
                    guard sessionGeneration.isCurrentNow else {
                        return .stop(.terminal(
                            makeTerminal(outcome: .staleContext, stage: .pause)))
                    }
                }
                // Falha não equivale a "sem histórico". Sem estado confirmado, o motor poderia interpretar
                // nil como primeiro uso e criar um CHECKIN; aguarda a confirmação conservadoramente.
                return .stop(.failure(error))

            case .resolution(.resolved(let state, _, _)):
                guard generation == scheduledPauseGeneration,
                      sessionGeneration.isCurrentNow else {
                    return .stop(.terminal(
                        makeTerminal(outcome: .staleContext, stage: .pause)))
                }
                switch resolveLastRecordedAction(state) {
                case .checkIn:
                    await transitionScheduledPauseToAwaiting(
                        chave: chave,
                        activeProject: userSettings.activeProject,
                        settings: pauseSettings,
                        window: window,
                        generation: generation,
                        lang: lang,
                        sessionGeneration: sessionGeneration)
                    guard sessionGeneration.isCurrentNow else {
                        return .stop(.terminal(
                            makeTerminal(outcome: .staleContext, stage: .pause)))
                    }
                    return .proceed(currentState: state, usedFreshState: true)

                case .checkOut:
                    if scheduledPauseDeferral?.phase == .awaitingCheckout
                        || checkoutOccurredInsideWindow(state, window) {
                        let result = await scheduleOrActivateAfterConfirmedCheckout(
                            state: state,
                            chave: chave,
                            activeProject: userSettings.activeProject,
                            settings: pauseSettings,
                            window: window,
                            userSettings: userSettings,
                            generation: generation,
                            now: now,
                            lang: lang,
                            sessionGeneration: sessionGeneration)
                        guard sessionGeneration.isCurrentNow else {
                            return .stop(.terminal(
                                makeTerminal(outcome: .staleContext, stage: .pause)))
                        }
                        return result
                    }
                    let runtime = makeScheduledPauseRuntime(
                        chave: chave,
                        activeProject: userSettings.activeProject,
                        settings: pauseSettings,
                        window: window,
                        phase: .active)
                    await activateScheduledPause(
                        runtime,
                        userSettings: userSettings,
                        generation: generation,
                        now: now,
                        lang: lang,
                        sessionGeneration: sessionGeneration)
                    guard sessionGeneration.isCurrentNow else {
                        return .stop(.terminal(
                            makeTerminal(outcome: .staleContext, stage: .pause)))
                    }
                    return .stop(.paused)

                case nil:
                    // GET bem-sucedido sem atividade é diferente de falha: não há check-in aberto.
                    let runtime = makeScheduledPauseRuntime(
                        chave: chave,
                        activeProject: userSettings.activeProject,
                        settings: pauseSettings,
                        window: window,
                        phase: .active)
                    await activateScheduledPause(
                        runtime,
                        userSettings: userSettings,
                        generation: generation,
                        now: now,
                        lang: lang,
                        sessionGeneration: sessionGeneration)
                    guard sessionGeneration.isCurrentNow else {
                        return .stop(.terminal(
                            makeTerminal(outcome: .staleContext, stage: .pause)))
                    }
                    return .stop(.paused)
                }
            case .terminal(let terminal):
                await transitionScheduledPauseToAwaiting(
                    chave: chave,
                    activeProject: userSettings.activeProject,
                    settings: pauseSettings,
                    window: window,
                    generation: generation,
                    lang: lang,
                    sessionGeneration: authRetryBudget.sessionGeneration)
                guard sessionGeneration.isCurrentNow else {
                    return .stop(.terminal(
                        makeTerminal(outcome: .staleContext, stage: .pause)))
                }
                return .stop(.terminal(terminal))
            }
        }
    }

    private func scheduleOrActivateAfterConfirmedCheckout(
        state: HistoryState,
        chave: String,
        activeProject: String,
        settings: ScheduledPauseSettings,
        window: ScheduledPauseWindow,
        userSettings: UserSettings,
        generation: UInt64,
        now: Date,
        lang: String,
        sessionGeneration: AuthSessionGeneration? = nil
    ) async -> ScheduledPauseGateResult {
        guard sessionGeneration?.isCurrentNow ?? true else {
            return .stop(.noAction)
        }
        let dueAt = state.lastCheckoutAt
            .map { $0.addingTimeInterval(Self.scheduledPauseActivationDelay) }
            ?? now.addingTimeInterval(Self.scheduledPauseActivationDelay)
        var runtime = scheduledPauseDeferral
            ?? makeScheduledPauseRuntime(
                chave: chave,
                activeProject: activeProject,
                settings: settings,
                window: window,
                phase: .awaitingCheckout)
        if dueAt >= window.end {
            await transitionScheduledPauseToTerminal(
                runtime,
                generation: generation,
                lang: lang,
                sessionGeneration: sessionGeneration
            )
            guard sessionGeneration?.isCurrentNow ?? true else {
                return .stop(.noAction)
            }
            await cancelAccuracyRetryEpisode()
            return .stop(.noAction)
        }
        if dueAt <= now {
            runtime.phase = .active
            runtime.activationEpochMs = nil
            await activateScheduledPause(
                runtime,
                userSettings: userSettings,
                generation: generation,
                now: now,
                lang: lang,
                sessionGeneration: sessionGeneration)
            return .stop(.paused)
        }
        runtime.phase = .activationScheduled
        runtime.activationEpochMs = epochMs(dueAt)
        guard sessionGeneration?.isCurrentNow ?? true else {
            return .stop(.noAction)
        }
        await persistScheduledPauseRuntime(runtime)
        guard generation == scheduledPauseGeneration else {
            return .stop(.noAction)
        }
        guard sessionGeneration?.isCurrentNow ?? true else {
            return .stop(.noAction)
        }
        await cancelAccuracyRetryEpisode()
        await armScheduledPauseActivation(
            runtime,
            userSettings: userSettings,
            generation: generation,
            lang: lang,
            sessionGeneration: sessionGeneration)
        return .stop(.noAction)
    }

    private func checkoutOccurredInsideWindow(
        _ state: HistoryState,
        _ window: ScheduledPauseWindow
    ) -> Bool {
        guard let at = state.lastCheckoutAt else { return false }
        return at >= window.start && at < window.end
    }

    private func makeScheduledPauseRuntime(
        chave: String,
        activeProject: String,
        settings: ScheduledPauseSettings,
        window: ScheduledPauseWindow,
        phase: ScheduledPauseDeferralPhase
    ) -> ScheduledPauseDeferral {
        ScheduledPauseDeferral(
            id: UUID().uuidString,
            chave: chave,
            activeProject: activeProject,
            settings: settings,
            windowStartEpochMs: epochMs(window.start),
            windowEndEpochMs: epochMs(window.end),
            phase: phase,
            activationEpochMs: nil)
    }

    private func scheduledPauseRuntime(
        _ runtime: ScheduledPauseDeferral,
        matchesChave chave: String,
        activeProject: String,
        settings: ScheduledPauseSettings,
        window: ScheduledPauseWindow
    ) -> Bool {
        runtime.chave == chave
            && runtime.activeProject == activeProject
            && runtime.settings == settings
            && runtime.windowStartEpochMs == epochMs(window.start)
            && runtime.windowEndEpochMs == epochMs(window.end)
    }

    private func transitionScheduledPauseToAwaiting(
        chave: String,
        activeProject: String,
        settings: ScheduledPauseSettings,
        window: ScheduledPauseWindow,
        generation: UInt64,
        lang: String,
        sessionGeneration: AuthSessionGeneration? = nil
    ) async {
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true else { return }
        var runtime = scheduledPauseDeferral
            ?? makeScheduledPauseRuntime(
                chave: chave,
                activeProject: activeProject,
                settings: settings,
                window: window,
                phase: .awaitingCheckout)
        runtime.phase = .awaitingCheckout
        runtime.activationEpochMs = nil
        pauseActivationTask?.cancel()
        pauseActivationTask = nil
        scheduledPauseDeferral = runtime
        await persistScheduledPauseRuntime(runtime)
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .awaitingCheckout else { return }
        appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
        armScheduledPauseTransition(at: window.end)
        guard sessionGeneration?.isCurrentNow ?? true else { return }
        await appPrefs.setFlag(Self.flagPauseActive, false)
        guard sessionGeneration?.isCurrentNow ?? true else { return }
        await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
        guard sessionGeneration?.isCurrentNow ?? true else { return }
        await pauseAlarms.scheduleResume(at: nil, notify: false, lang: lang)
    }

    private func transitionScheduledPauseToTerminal(
        _ existing: ScheduledPauseDeferral,
        generation: UInt64,
        lang: String,
        sessionGeneration: AuthSessionGeneration? = nil
    ) async {
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true else { return }
        var runtime = existing
        runtime.phase = .terminal
        runtime.activationEpochMs = nil
        pauseActivationTask?.cancel()
        pauseActivationTask = nil
        scheduledPauseDeferral = runtime
        await persistScheduledPauseRuntime(runtime)
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true else { return }
        appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
        armScheduledPauseTransition(at: runtime.windowEnd)
        await appPrefs.setFlag(Self.flagPauseActive, false)
        guard sessionGeneration?.isCurrentNow ?? true else { return }
        await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
        guard sessionGeneration?.isCurrentNow ?? true else { return }
        await pauseAlarms.scheduleResume(at: nil, notify: false, lang: lang)
    }

    private func activateScheduledPause(
        _ existing: ScheduledPauseDeferral,
        userSettings: UserSettings,
        generation: UInt64,
        now: Date,
        lang: String,
        sessionGeneration: AuthSessionGeneration? = nil
    ) async {
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              now < existing.windowEnd else { return }
        var runtime = existing
        runtime.phase = .active
        runtime.activationEpochMs = nil
        scheduledPauseDeferral = runtime
        await persistScheduledPauseRuntime(runtime)
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true else { return }
        pauseActivationTask?.cancel()
        pauseActivationTask = nil
        appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
        armScheduledPauseTransition(at: runtime.windowEnd)
        let alreadyScheduled = await pauseAlarms.consumeScheduledTransition(
            started: true,
            dueAtOrBefore: now)
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        let wasPaused = await appPrefs.getFlag(Self.flagPauseActive)
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        await appPrefs.setFlag(Self.flagPauseActive, true)
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        if !wasPaused {
            if userSettings.notifyScheduledPause && !alreadyScheduled {
                guard sessionGeneration?.isCurrentNow ?? true else { return }
                notifications.postScheduledPauseTransition(started: true, lang: lang)
            }
            activityLogger.logInactive("Scheduled pause started.")
        }
        await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        await pauseAlarms.scheduleResume(
            at: runtime.windowEnd,
            notify: userSettings.notifyScheduledPause,
            lang: lang)
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        await cancelAccuracyRetryEpisode()
    }

    private func maintainActiveScheduledPause(
        window: ScheduledPauseWindow,
        userSettings: UserSettings,
        generation: UInt64,
        lang: String,
        sessionGeneration: AuthSessionGeneration? = nil
    ) async {
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              let runtime = scheduledPauseDeferral,
              runtime.phase == .active else { return }
        await appPrefs.setFlag(Self.flagPauseActive, true)
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
        armScheduledPauseTransition(at: window.end)
        await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        await pauseAlarms.scheduleResume(
            at: window.end,
            notify: userSettings.notifyScheduledPause,
            lang: lang)
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.phase == .active else { return }
        await cancelAccuracyRetryEpisode()
    }

    private func scheduleScheduledPauseConfirmationRetry(
        _ existing: ScheduledPauseDeferral,
        retryAt: Date,
        userSettings: UserSettings,
        generation: UInt64,
        lang: String,
        sessionGeneration: AuthSessionGeneration? = nil
    ) async {
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              existing.phase == .awaitingCheckout else { return }
        guard retryAt < existing.windowEnd else {
            appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
            return
        }
        var runtime = existing
        runtime.activationEpochMs = epochMs(retryAt)
        await persistScheduledPauseRuntime(runtime)
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true else { return }
        await armScheduledPauseActivation(
            runtime,
            userSettings: userSettings,
            generation: generation,
            lang: lang,
            sessionGeneration: sessionGeneration)
    }

    private func shouldRetryScheduledPauseConfirmation(_ error: ApiError) -> Bool {
        switch error {
        case .network:
            return true
        case .http(let status, _):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .unauthorized, .conflict, .unknown:
            return false
        }
    }

    private func armScheduledPauseActivation(
        _ runtime: ScheduledPauseDeferral,
        userSettings: UserSettings,
        generation: UInt64,
        lang: String,
        sessionGeneration: AuthSessionGeneration? = nil
    ) async {
        let supportsActivationWake =
            runtime.phase == .activationScheduled || runtime.phase == .awaitingCheckout
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              supportsActivationWake,
              let dueAt = runtime.activationAt,
              dueAt < runtime.windowEnd else { return }
        pauseActivationTask?.cancel()
        appRefreshScheduler.schedulePauseActivation(at: dueAt)
        armScheduledPauseTransition(at: runtime.windowEnd)
        // Não há notificação antecipada durante grace/retry de confirmação: um CHECKIN em outro cliente
        // pode ocorrer antes do vencimento. A mensagem só é postada após o GET fresco confirmar a ativação.
        await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
        guard generation == scheduledPauseGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              scheduledPauseDeferral?.id == runtime.id,
              scheduledPauseDeferral?.activationEpochMs == runtime.activationEpochMs else { return }
        let remaining = max(0, dueAt.timeIntervalSince(clock.now()))
        let milliseconds = Int((remaining * 1_000).rounded(.up))
        let sleeper = pauseActivationSleeper
        let runtimeID = runtime.id
        let dueEpochMs = runtime.activationEpochMs!
        pauseActivationTask = Task { [weak self] in
            await sleeper.sleep(milliseconds: milliseconds)
            guard !Task.isCancelled else { return }
            await self?.scheduledPauseActivationTaskFired(
                runtimeID: runtimeID,
                dueEpochMs: dueEpochMs)
        }
    }

    private func scheduledPauseActivationTaskFired(runtimeID: String, dueEpochMs: Int64) async {
        guard let runtime = scheduledPauseDeferral,
              runtime.id == runtimeID,
              (runtime.phase == .activationScheduled || runtime.phase == .awaitingCheckout),
              runtime.activationEpochMs == dueEpochMs else { return }
        pauseActivationTask = nil
        await runOnce(.pauseActivation)
    }

    private func armScheduledPauseTransition(at deadline: Date) {
        pauseTransitionTask?.cancel()
        let deadlineEpochMs = epochMs(deadline)
        pauseTransitionEpochMs = deadlineEpochMs
        appRefreshScheduler.schedulePauseTransition(at: deadline)
        let remaining = max(0, deadline.timeIntervalSince(clock.now()))
        let milliseconds = Int((remaining * 1_000).rounded(.up))
        let sleeper = pauseTransitionSleeper
        pauseTransitionTask = Task { [weak self] in
            await sleeper.sleep(milliseconds: milliseconds)
            guard !Task.isCancelled else { return }
            await self?.scheduledPauseTransitionTaskFired(dueEpochMs: deadlineEpochMs)
        }
    }

    private func scheduledPauseTransitionTaskFired(dueEpochMs: Int64) async {
        guard pauseTransitionEpochMs == dueEpochMs else { return }
        pauseTransitionTask = nil
        pauseTransitionEpochMs = nil
        await runOnce(.pauseTransition)
    }

    private func persistScheduledPauseRuntime(_ runtime: ScheduledPauseDeferral) async {
        scheduledPauseDeferral = runtime
        guard let data = try? JSONCoding.encoder.encode(runtime),
              let json = String(data: data, encoding: .utf8) else { return }
        await appPrefs.setScheduledPauseDeferralJson(json)
    }

    private func restoreScheduledPauseDeferralIfNeeded() async {
        guard !didRestoreScheduledPauseDeferral else { return }
        didRestoreScheduledPauseDeferral = true
        let generation = scheduledPauseGeneration
        let raw = await appPrefs.scheduledPauseDeferralJson()
        guard generation == scheduledPauseGeneration else { return }
        guard !raw.isEmpty else { return }
        guard let restored = try? JSONCoding.decoder.decode(
            ScheduledPauseDeferral.self,
            from: Data(raw.utf8)
        ) else {
            await appPrefs.setScheduledPauseDeferralJson("")
            appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
            return
        }
        scheduledPauseDeferral = restored
    }

    private func cancelScheduledPauseRuntime(
        clearActiveFlag: Bool,
        lang: String,
        preserveResumeNotification: Bool = false,
        sessionGeneration: AuthSessionGeneration? = nil
    ) async {
        guard sessionGeneration?.isCurrentNow ?? true else { return }
        pauseActivationTask?.cancel()
        pauseActivationTask = nil
        pauseTransitionTask?.cancel()
        pauseTransitionTask = nil
        pauseTransitionEpochMs = nil
        scheduledPauseDeferral = nil
        await appPrefs.setScheduledPauseDeferralJson("")
        guard sessionGeneration?.isCurrentNow ?? true else { return }
        appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
        appRefreshScheduler.clearPauseTransitionDeadlineAndScheduleRegular()
        await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
        guard sessionGeneration?.isCurrentNow ?? true else { return }
        if !preserveResumeNotification {
            await pauseAlarms.scheduleResume(at: nil, notify: false, lang: lang)
            guard sessionGeneration?.isCurrentNow ?? true else { return }
        }
        if clearActiveFlag {
            await appPrefs.setFlag(Self.flagPauseActive, false)
        }
    }

    /// Evento confirmado fora do motor (submit manual ou replay concluído). O estado devolvido pelo
    /// servidor, e não apenas a ação solicitada, decide se o checkout realmente ficou por último.
    func acceptedCheck(
        chave: String,
        project: String,
        action: CheckAction,
        newState: HistoryState
    ) async {
        let automationGenerationAtReceipt = automationContextGeneration
        let arrivedDuringContextTransition = automationContextInvalidationInProgress
        guard !arrivedDuringContextTransition else { return }
        await waitForAutomationContextInvalidationIfNeeded()
        guard automationGenerationAtReceipt == automationContextGeneration else { return }
        await restoreScheduledPauseDeferralIfNeeded()
        guard automationGenerationAtReceipt == automationContextGeneration else { return }
        let persistedChave = await appPrefs.chave()
        guard automationGenerationAtReceipt == automationContextGeneration,
              persistedChave == chave else { return }
        let lang = resolveEffectiveLanguageCode(await appPrefs.language())
        guard automationGenerationAtReceipt == automationContextGeneration else { return }
        let userSettings = await loadUserSettings(chave)
        guard automationGenerationAtReceipt == automationContextGeneration else { return }
        let revalidatedChave = await appPrefs.chave()
        guard userSettings.automaticActivitiesEnabled,
              userSettings.activeProject == project,
              userSettings.projects.contains(project),
              newState.projeto == nil || newState.projeto == project,
              automationGenerationAtReceipt == automationContextGeneration,
              revalidatedChave == chave else { return }
        invalidateActiveEvaluationEffects()
        accuracyRetryGeneration &+= 1
        scheduledPauseGeneration &+= 1
        let generation = scheduledPauseGeneration
        await cancelAccuracyRetryEpisode(forceCleanup: true)
        guard automationGenerationAtReceipt == automationContextGeneration,
              generation == scheduledPauseGeneration else { return }
        let settings = ScheduledPauseSettings(
            scheduledPauseEnabled: userSettings.scheduledPauseEnabled,
            scheduledPauseFrom: userSettings.scheduledPauseFrom,
            scheduledPauseTo: userSettings.scheduledPauseTo,
            suspendSaturdays: userSettings.suspendSaturdays,
            suspendSundays: userSettings.suspendSundays)
        let now = clock.now()
        let calendar = Calendar.current
        guard let window = currentScheduledPauseWindow(now, calendar, settings) else { return }
        armScheduledPauseTransition(at: window.end)

        if let runtime = scheduledPauseDeferral,
           !scheduledPauseRuntime(
               runtime,
               matchesChave: chave,
               activeProject: project,
               settings: settings,
               window: window) {
            await cancelScheduledPauseRuntime(clearActiveFlag: true, lang: lang)
        }
        guard automationGenerationAtReceipt == automationContextGeneration,
              generation == scheduledPauseGeneration else { return }
        if scheduledPauseDeferral?.phase == .active
            || scheduledPauseDeferral?.phase == .terminal {
            return
        }

        switch resolveLastRecordedAction(newState) {
        case .checkIn:
            await transitionScheduledPauseToAwaiting(
                chave: chave,
                activeProject: project,
                settings: settings,
                window: window,
                generation: generation,
                lang: lang)

        case .checkOut:
            _ = await scheduleOrActivateAfterConfirmedCheckout(
                state: newState,
                chave: chave,
                activeProject: project,
                settings: settings,
                window: window,
                userSettings: userSettings,
                generation: generation,
                now: now,
                lang: lang)

        case nil:
            break
        }
    }

    func confirmedState(chave: String, newState: HistoryState) async {
        let automationGenerationAtReceipt = automationContextGeneration
        let arrivedDuringContextTransition = automationContextInvalidationInProgress
        guard !arrivedDuringContextTransition else { return }
        await waitForAutomationContextInvalidationIfNeeded()
        guard automationGenerationAtReceipt == automationContextGeneration else { return }
        await restoreScheduledPauseDeferralIfNeeded()
        guard automationGenerationAtReceipt == automationContextGeneration else { return }
        let persistedChave = await appPrefs.chave()
        guard automationGenerationAtReceipt == automationContextGeneration,
              persistedChave == chave else { return }
        let lang = resolveEffectiveLanguageCode(await appPrefs.language())
        guard automationGenerationAtReceipt == automationContextGeneration else { return }
        let userSettings = await loadUserSettings(chave)
        guard automationGenerationAtReceipt == automationContextGeneration else { return }
        let revalidatedChave = await appPrefs.chave()
        guard userSettings.automaticActivitiesEnabled,
              !userSettings.activeProject.isEmpty,
              userSettings.projects.contains(userSettings.activeProject),
              newState.projeto == nil || newState.projeto == userSettings.activeProject,
              automationGenerationAtReceipt == automationContextGeneration,
              revalidatedChave == chave else { return }
        invalidateActiveEvaluationEffects()
        scheduledPauseGeneration &+= 1
        let generation = scheduledPauseGeneration
        let settings = ScheduledPauseSettings(
            scheduledPauseEnabled: userSettings.scheduledPauseEnabled,
            scheduledPauseFrom: userSettings.scheduledPauseFrom,
            scheduledPauseTo: userSettings.scheduledPauseTo,
            suspendSaturdays: userSettings.suspendSaturdays,
            suspendSundays: userSettings.suspendSundays)
        let now = clock.now()
        guard let window = currentScheduledPauseWindow(now, Calendar.current, settings) else { return }
        armScheduledPauseTransition(at: window.end)
        if let runtime = scheduledPauseDeferral,
           !scheduledPauseRuntime(
               runtime,
               matchesChave: chave,
               activeProject: userSettings.activeProject,
               settings: settings,
               window: window) {
            await cancelScheduledPauseRuntime(clearActiveFlag: true, lang: lang)
        }
        guard automationGenerationAtReceipt == automationContextGeneration,
              generation == scheduledPauseGeneration,
              scheduledPauseDeferral?.phase != .active,
              scheduledPauseDeferral?.phase != .terminal else { return }

        switch resolveLastRecordedAction(newState) {
        case .checkIn:
            await transitionScheduledPauseToAwaiting(
                chave: chave,
                activeProject: userSettings.activeProject,
                settings: settings,
                window: window,
                generation: generation,
                lang: lang)
        case .checkOut:
            _ = await scheduleOrActivateAfterConfirmedCheckout(
                state: newState,
                chave: chave,
                activeProject: userSettings.activeProject,
                settings: settings,
                window: window,
                userSettings: userSettings,
                generation: generation,
                now: now,
                lang: lang)
        case nil:
            if let runtime = scheduledPauseDeferral,
               runtime.phase == .activationScheduled,
               let dueAt = runtime.activationAt,
               dueAt > now {
                await armScheduledPauseActivation(
                    runtime,
                    userSettings: userSettings,
                    generation: generation,
                    lang: lang)
                return
            }
            let runtime = scheduledPauseDeferral
                ?? makeScheduledPauseRuntime(
                    chave: chave,
                    activeProject: userSettings.activeProject,
                    settings: settings,
                    window: window,
                    phase: .active)
            await activateScheduledPause(
                runtime,
                userSettings: userSettings,
                generation: generation,
                now: now,
                lang: lang)
        }
    }

    private func reconcileAcceptedCheckForScheduledPause(
        chave: String,
        project: String,
        action: CheckAction,
        newState: HistoryState,
        expectedPauseGeneration: UInt64,
        lang: String,
        sessionGeneration: AuthSessionGeneration
    ) async {
        guard expectedPauseGeneration == scheduledPauseGeneration,
              sessionGeneration.isCurrentNow,
              let runtime = scheduledPauseDeferral,
              runtime.chave == chave,
              runtime.activeProject == project,
              newState.projeto == nil || newState.projeto == project,
              runtime.phase != .active,
              runtime.phase != .terminal else { return }
        let now = clock.now()
        guard sessionGeneration.isCurrentNow,
              now >= runtime.windowStart, now < runtime.windowEnd else { return }
        let userSettings = await loadUserSettings(chave)
        guard expectedPauseGeneration == scheduledPauseGeneration,
              sessionGeneration.isCurrentNow else { return }
        let window = ScheduledPauseWindow(start: runtime.windowStart, end: runtime.windowEnd)
        switch resolveLastRecordedAction(newState) {
        case .checkIn:
            await transitionScheduledPauseToAwaiting(
                chave: chave,
                activeProject: project,
                settings: runtime.settings,
                window: window,
                generation: expectedPauseGeneration,
                lang: lang,
                sessionGeneration: sessionGeneration)
        case .checkOut:
            _ = await scheduleOrActivateAfterConfirmedCheckout(
                state: newState,
                chave: chave,
                activeProject: project,
                settings: runtime.settings,
                window: window,
                userSettings: userSettings,
                generation: expectedPauseGeneration,
                now: now,
                lang: lang,
                sessionGeneration: sessionGeneration)
        case nil:
            break
        }
    }

    /// Mudança de conta/projeto/toggle: nenhum deadline ou flag do contexto antigo pode sobreviver.
    func invalidateAutomationContext() async {
        let token = await beginAutomationContextTransition()
        await endAutomationContextTransition(token)
    }

    /// Abre uma transição explícita e mantém novas admissões atrás do barrier até `end`. A geração, os
    /// slots e caches antigos são invalidados antes do primeiro await interno.
    func beginAutomationContextTransition() async -> AutomationContextTransitionToken {
        while automationContextInvalidationInProgress {
            await waitForAutomationContextInvalidationIfNeeded()
        }
        let transitionToken = AutomationContextTransitionToken()
        let invalidationCompletion = SharedAccidentCompletion()
        automationContextInvalidationInProgress = true
        automationContextInvalidationCompletion = invalidationCompletion
        automationContextTransitionToken = transitionToken
        automationContextQuiescenceWait = switch runningWork {
        case .evaluation(let work):
            .evaluation(work.completion.task)
        case .accident(let work):
            .accident(work.completion.task)
        case nil:
            nil
        }
        if case .evaluation(let work) = runningWork {
            _ = work.ownership.invalidateContext()
        }
        invalidateActiveEvaluationEffects()
        automationContextGeneration &+= 1
        accuracyRetryGeneration &+= 1
        scheduledPauseGeneration &+= 1

        // Retira todos os slots antigos de forma atômica e bounded antes do primeiro await. O running
        // permanece visível ao driver, mas sua operação candidata é cancelada e seus guards observarão a
        // nova geração.
        let stalePauseTransition = pendingPauseTransitionWork
        let stalePauseActivation = pendingPauseActivationWork
        let staleForeground = pendingForegroundWork
        let staleAccuracyRetry = pendingAccuracyRetryWork
        let staleNormal = pendingNormalWake
        let staleAccident = pendingAccidentWork
        pendingPauseTransitionWork = nil
        pendingPauseActivationWork = nil
        pendingForegroundWork = nil
        pendingAccuracyRetryWork = nil
        pendingNormalWake = nil
        pendingAccidentWork = nil
        pauseReconciliationRequired = false
        servedInDrainCycle.removeAll()
        drainCycleLastIrreversibleAction = nil

        cancelAutomaticOperation?()
        cancelAutomaticOperation = nil
        automaticOperationID = nil
        // O baseline é contexto local da conta/projeto/toggle. Limpá-lo antes do primeiro `await` evita
        // que a primeira avaliação do contexto novo seja comparada com uma posição do contexto antigo.
        lastLat = nil
        lastLon = nil
        lastCaptureAccuracyMeters = nil
        cachedState = nil
        cacheChave = ""
        cachedStateAt = Date(timeIntervalSince1970: 0)
        cachedOptions = nil
        cachedOptionsAt = Date(timeIntervalSince1970: 0)
        lastReauthNotificationAt = Date(timeIntervalSince1970: 0)
        // Tudo que pode criar trabalho novo é removido antes do primeiro await. Entradas concorrentes
        // aguardam o barrier acima, portanto o teardown externo não alcança um episódio do contexto novo.
        accuracyRetryTask?.cancel()
        accuracyRetryTask = nil
        accuracyRetryEpisode = nil
        pauseActivationTask?.cancel()
        pauseActivationTask = nil
        pauseTransitionTask?.cancel()
        pauseTransitionTask = nil
        pauseTransitionEpochMs = nil
        scheduledPauseDeferral = nil

        await finishDeferredAsStale(stalePauseTransition)
        await finishDeferredAsStale(stalePauseActivation)
        await finishDeferredAsStale(staleForeground)
        await finishDeferredAsStale(staleAccuracyRetry)
        await finishDeferredAsStale(staleNormal)
        await staleAccident?.completion.resolve()

        let lang = resolveEffectiveLanguageCode(await appPrefs.language())
        await appPrefs.setAccuracyRetryEpisodeJson("")
        appRefreshScheduler.clearAccuracyRetryDeadlineAndScheduleRegular()
        await notifications.clearLowAccuracyNotification()
        await appPrefs.setScheduledPauseDeferralJson("")
        appRefreshScheduler.clearPauseActivationDeadlineAndScheduleRegular()
        appRefreshScheduler.clearPauseTransitionDeadlineAndScheduleRegular()
        await pauseAlarms.scheduleStart(at: nil, notify: false, lang: lang)
        await pauseAlarms.scheduleResume(at: nil, notify: false, lang: lang)
        await appPrefs.setFlag(Self.flagPauseActive, false)

        return transitionToken
    }

    func awaitAutomationQuiescence(
        _ token: AutomationContextTransitionToken
    ) async {
        guard token == automationContextTransitionToken else { return }
        let wait = automationContextQuiescenceWait
        await wait?.wait()
    }

    func endAutomationContextTransition(
        _ token: AutomationContextTransitionToken
    ) async {
        guard token == automationContextTransitionToken,
              let invalidationCompletion = automationContextInvalidationCompletion else { return }
        automationContextInvalidationInProgress = false
        automationContextInvalidationCompletion = nil
        automationContextTransitionToken = nil
        automationContextQuiescenceWait = nil
        await invalidationCompletion.resolve()
    }

    /// A edição preserva uma pausa já ACTIVE até avaliar a configuração nova, invalida qualquer decisão
    /// pendente anterior e garante a reconciliação imediata. O pedido fica pendente se outra run estiver
    /// em voo; assim a mudança não depende de um futuro evento de localização/foreground.
    func scheduledPauseSettingsDidChange() async {
        let automationGenerationAtReceipt = automationContextGeneration
        let arrivedDuringContextTransition = automationContextInvalidationInProgress
        guard !arrivedDuringContextTransition else { return }
        await waitForAutomationContextInvalidationIfNeeded()
        guard !Task.isCancelled,
              automationGenerationAtReceipt == automationContextGeneration else { return }
        invalidateActiveEvaluationEffects()
        scheduledPauseGeneration &+= 1
        let expectedPauseGeneration = scheduledPauseGeneration
        await restoreScheduledPauseDeferralIfNeeded()
        guard !Task.isCancelled,
              automationGenerationAtReceipt == automationContextGeneration,
              expectedPauseGeneration == scheduledPauseGeneration else { return }
        if scheduledPauseDeferral?.phase != .active {
            let lang = resolveEffectiveLanguageCode(await appPrefs.language())
            guard !Task.isCancelled,
                  automationGenerationAtReceipt == automationContextGeneration,
                  expectedPauseGeneration == scheduledPauseGeneration else { return }
            await cancelScheduledPauseRuntime(clearActiveFlag: false, lang: lang)
            guard !Task.isCancelled,
                  automationGenerationAtReceipt == automationContextGeneration,
                  expectedPauseGeneration == scheduledPauseGeneration else { return }
        }
        pauseReconciliationRequired = true
        let ticket = await evaluationTicket(
            .foreground,
            seedCandidate: nil,
            forceForegroundReconciliation: true,
            ownerRegistration: nil
        )
        // Em idle, preserva o contrato histórico de reconciliação concluída ao retornar. Se já existe
        // motor em voo, o ticket especial fica bounded e esta chamada continua não bloqueante.
        if ticket.admission == .admitted {
            _ = await ticket.completion()
        }
    }

    // MARK: - Episódio de baixa precisão

    /// Invalida avaliações de precisão que atravessaram um `await`. É intencionalmente público no actor
    /// para que OFF, mudança de projeto e submit manual aceito possam encerrar o episódio sem corrida.
    func invalidateAccuracyRetry() async {
        let automationGenerationAtReceipt = automationContextGeneration
        let arrivedDuringContextTransition = automationContextInvalidationInProgress
        guard !arrivedDuringContextTransition else { return }
        await waitForAutomationContextInvalidationIfNeeded()
        guard !Task.isCancelled,
              automationGenerationAtReceipt == automationContextGeneration else { return }
        await invalidateAccuracyRetryWithoutWaitingForAutomationTransition()
    }

    /// Variante interna para um trabalho já admitido. Ela nunca espera o barrier de automação: o owner de
    /// uma troca destrutiva pode estar aguardando justamente o terminal desse trabalho em quiescence.
    private func invalidateAccuracyRetryWithoutWaitingForAutomationTransition() async {
        invalidateActiveEvaluationEffects()
        accuracyRetryGeneration &+= 1
        await cancelAccuracyRetryEpisode(forceCleanup: true)
    }

    /// Revoga de forma síncrona o fence da avaliação viva antes de publicar qualquer nova geração. A
    /// invalidação não atravessa `await`; match/fila/submit linearizam seus efeitos contra este token.
    private func invalidateActiveEvaluationEffects() {
        activeEvaluationEffectValidity?.invalidate()
    }

    private func waitForAutomationContextInvalidationIfNeeded() async {
        guard automationContextInvalidationInProgress,
              let completion = automationContextInvalidationCompletion else { return }
        await completion.task.value
    }

    private func finishDeferredAsStale(_ work: CanonicalEvaluationWork?) async {
        guard let work else { return }
        // `contextInvalidated` é global, mas não pode sobrescrever uma expiração que já venceu a
        // disputa first-wins no ticket pending. Nesse caso o request permanece `.expired`, reporta
        // false ao sistema e conserva o owner no journal.
        _ = work.ownership.invalidateContext()
        let cancellationReason = work.ownership.cancellationContext.reason
        await work.journalAdmission.value
        await recordCoalescedWakes(for: work)
        await recordOwnerExpirations(
            work.ownership.expirationSnapshot,
            evaluationID: work.request.id
        )
        let terminal = cancellationReason.map {
            terminalForCancellation($0, stage: .admitted)
        } ?? makeTerminal(outcome: .staleContext, stage: .admitted)
        await evaluationJournal.finish(id: work.request.id, terminal: terminal)
        _ = work.ownership.finish()
        await work.completion.resolve(EvaluationCompletion(
            evaluationID: work.request.id,
            outcome: terminal.outcome,
            completedBeforeExpiration: terminal.outcome != .expired
        ))
    }

    private func restoreAccuracyRetryEpisodeIfNeeded(armProcessTask: Bool) async {
        guard !didRestoreAccuracyRetryEpisode else { return }
        didRestoreAccuracyRetryEpisode = true
        let generation = accuracyRetryGeneration
        let raw = await appPrefs.accuracyRetryEpisodeJson()
        guard generation == accuracyRetryGeneration else { return }
        guard !raw.isEmpty else { return }
        guard let restored = try? JSONCoding.decoder.decode(
            AccuracyRetryEpisode.self,
            from: Data(raw.utf8)
        ) else {
            await appPrefs.setAccuracyRetryEpisodeJson("")
            appRefreshScheduler.clearAccuracyRetryDeadlineAndScheduleRegular()
            await notifications.clearLowAccuracyNotification()
            return
        }
        accuracyRetryEpisode = restored
        if !restored.notificationPosted {
            let language = resolveEffectiveLanguageCode(await appPrefs.language())
            guard generation == accuracyRetryGeneration,
                  accuracyRetryEpisode?.id == restored.id else {
                await discardStaleAccuracyRetryEpisode(id: restored.id)
                return
            }
            await notifications.postLowAccuracyNotification(
                expectedAction: restored.expectedAction,
                lang: language)
            guard generation == accuracyRetryGeneration,
                  accuracyRetryEpisode?.id == restored.id else {
                await discardStaleAccuracyRetryEpisode(id: restored.id)
                return
            }
            var updated = restored
            updated.notificationPosted = true
            accuracyRetryEpisode = updated
            await persistAccuracyRetryEpisode(updated)
            guard generation == accuracyRetryGeneration,
                  accuracyRetryEpisode?.id == restored.id else {
                await discardStaleAccuracyRetryEpisode(id: restored.id)
                return
            }
        }
        if armProcessTask, generation == accuracyRetryGeneration,
           let episode = accuracyRetryEpisode {
            armAccuracyRetry(episode)
        }
    }

    private func reconcileAccuracyRetryEpisode(
        after result: AutoActivitiesResult,
        trigger: OrchestratorTrigger,
        chave: String,
        activeProject: String,
        lang: String,
        generation: UInt64,
        sessionGeneration: AuthSessionGeneration
    ) async {
        guard generation == accuracyRetryGeneration,
              sessionGeneration.isCurrentNow else { return }
        switch result {
        case .accuracyTooLow(let expectedAction):
            let contextIsEligible = await accuracyRetryContextIsEligible(
                chave: chave,
                activeProject: activeProject
            )
            guard generation == accuracyRetryGeneration,
                  sessionGeneration.isCurrentNow else { return }
            guard contextIsEligible else {
                await invalidateAccuracyRetryWithoutWaitingForAutomationTransition()
                return
            }
            if let episode = accuracyRetryEpisode,
               episode.chave == chave, episode.activeProject == activeProject {
                // Leituras adicionais não deslocam o prazo original. Só a tentativa que efetivamente venceu
                // o prazo arma o próximo ciclo de 180s.
                if trigger == .accuracyRetry {
                    await advanceAccuracyRetry(
                        episode,
                        generation: generation,
                        sessionGeneration: sessionGeneration
                    )
                }
                return
            }
            await startAccuracyRetryEpisode(
                chave: chave,
                activeProject: activeProject,
                expectedAction: expectedAction,
                lang: lang,
                generation: generation,
                sessionGeneration: sessionGeneration)

        case .locationTimeout:
            // Timeout isolado não abre episódio. Se ocorreu na tentativa de um episódio existente, mantém a
            // causa original e arma o próximo ciclo; falta de permissão, abaixo, encerra.
            if let episode = accuracyRetryEpisode,
               episode.chave == chave, episode.activeProject == activeProject,
               trigger == .accuracyRetry {
                await advanceAccuracyRetry(
                    episode,
                    generation: generation,
                    sessionGeneration: sessionGeneration
                )
            }

        case .submitted, .noAction, .networkError, .notConfigured, .noPermission:
            await cancelAccuracyRetryEpisode()
        }
    }

    private func startAccuracyRetryEpisode(
        chave: String,
        activeProject: String,
        expectedAction: CheckAction?,
        lang: String,
        generation: UInt64,
        sessionGeneration: AuthSessionGeneration
    ) async {
        guard generation == accuracyRetryGeneration,
              sessionGeneration.isCurrentNow,
              !chave.isEmpty, !activeProject.isEmpty else { return }
        let dueAt = clock.now().addingTimeInterval(Self.accuracyRetryInterval)
        guard sessionGeneration.isCurrentNow else { return }
        let episode = AccuracyRetryEpisode(
            id: UUID().uuidString,
            chave: chave,
            activeProject: activeProject,
            nextRetryEpochMs: epochMs(dueAt),
            notificationPosted: false,
            expectedActionRaw: rawExpectedAction(expectedAction))
        accuracyRetryEpisode = episode
        await persistAccuracyRetryEpisode(episode)
        guard generation == accuracyRetryGeneration,
              sessionGeneration.isCurrentNow,
              accuracyRetryEpisode?.id == episode.id else {
            await discardStaleAccuracyRetryEpisode(id: episode.id)
            return
        }
        // O deadline fica durável antes do post: se o processo morrer nessa janela, o refresh compartilhado
        // ainda acorda no prazo e a restauração repõe a notificação pelo identificador estável.
        guard sessionGeneration.isCurrentNow else {
            await discardStaleAccuracyRetryEpisode(id: episode.id)
            return
        }
        appRefreshScheduler.scheduleAccuracyRetry(at: episode.nextRetryAt)
        guard sessionGeneration.isCurrentNow else {
            await discardStaleAccuracyRetryEpisode(id: episode.id)
            return
        }
        await notifications.postLowAccuracyNotification(expectedAction: expectedAction, lang: lang)
        guard generation == accuracyRetryGeneration,
              sessionGeneration.isCurrentNow,
              accuracyRetryEpisode?.id == episode.id else {
            await discardStaleAccuracyRetryEpisode(id: episode.id)
            return
        }
        var notifiedEpisode = episode
        notifiedEpisode.notificationPosted = true
        guard sessionGeneration.isCurrentNow else {
            await discardStaleAccuracyRetryEpisode(id: episode.id)
            return
        }
        accuracyRetryEpisode = notifiedEpisode
        await persistAccuracyRetryEpisode(notifiedEpisode)
        guard generation == accuracyRetryGeneration,
              sessionGeneration.isCurrentNow,
              accuracyRetryEpisode?.id == episode.id else {
            await discardStaleAccuracyRetryEpisode(id: episode.id)
            return
        }
        armAccuracyRetry(notifiedEpisode, scheduleBackgroundRefresh: false)
    }

    private func advanceAccuracyRetry(
        _ current: AccuracyRetryEpisode,
        generation: UInt64? = nil,
        sessionGeneration: AuthSessionGeneration? = nil
    ) async {
        let expectedGeneration = generation ?? accuracyRetryGeneration
        guard expectedGeneration == accuracyRetryGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              accuracyRetryEpisode?.id == current.id else { return }
        var next = current
        next.nextRetryEpochMs = epochMs(clock.now().addingTimeInterval(Self.accuracyRetryInterval))
        guard sessionGeneration?.isCurrentNow ?? true else { return }
        accuracyRetryEpisode = next
        await persistAccuracyRetryEpisode(next)
        guard expectedGeneration == accuracyRetryGeneration,
              sessionGeneration?.isCurrentNow ?? true,
              accuracyRetryEpisode?.id == current.id else {
            await discardStaleAccuracyRetryEpisode(id: current.id)
            return
        }
        armAccuracyRetry(next)
    }

    private func armAccuracyRetry(
        _ episode: AccuracyRetryEpisode,
        scheduleBackgroundRefresh: Bool = true
    ) {
        accuracyRetryTask?.cancel()
        if scheduleBackgroundRefresh {
            appRefreshScheduler.scheduleAccuracyRetry(at: episode.nextRetryAt)
        }
        let remaining = max(0, episode.nextRetryAt.timeIntervalSince(clock.now()))
        let delayMilliseconds = Int((remaining * 1_000).rounded(.up))
        let sleeper = accuracyRetrySleeper
        let episodeID = episode.id
        let dueEpochMs = episode.nextRetryEpochMs
        accuracyRetryTask = Task { [weak self] in
            await sleeper.sleep(milliseconds: delayMilliseconds)
            guard !Task.isCancelled else { return }
            await self?.accuracyRetryTaskFired(episodeID: episodeID, dueEpochMs: dueEpochMs)
        }
    }

    private func accuracyRetryTaskFired(episodeID: String, dueEpochMs: Int64) async {
        guard let episode = accuracyRetryEpisode,
              episode.id == episodeID,
              episode.nextRetryEpochMs == dueEpochMs else { return }
        accuracyRetryTask = nil
        await runOnce(.accuracyRetry)
    }

    private func persistAccuracyRetryEpisode(_ episode: AccuracyRetryEpisode) async {
        guard let data = try? JSONCoding.encoder.encode(episode),
              let json = String(data: data, encoding: .utf8) else { return }
        await appPrefs.setAccuracyRetryEpisodeJson(json)
    }

    private func cancelAccuracyRetryEpisode(forceCleanup: Bool = false) async {
        guard forceCleanup || accuracyRetryEpisode != nil else { return }
        accuracyRetryTask?.cancel()
        accuracyRetryTask = nil
        accuracyRetryEpisode = nil
        await appPrefs.setAccuracyRetryEpisodeJson("")
        appRefreshScheduler.clearAccuracyRetryDeadlineAndScheduleRegular()
        await notifications.clearLowAccuracyNotification()
    }

    private func discardStaleAccuracyRetryEpisode(id: String) async {
        // Uma geração nova já pode ter feito a limpeza. Se houver um episódio realmente diferente,
        // preserva-o; o single-flight impede essa situação no fluxo normal, mas a guarda evita dano futuro.
        if let current = accuracyRetryEpisode, current.id != id { return }
        accuracyRetryTask?.cancel()
        accuracyRetryTask = nil
        accuracyRetryEpisode = nil
        await appPrefs.setAccuracyRetryEpisodeJson("")
        appRefreshScheduler.clearAccuracyRetryDeadlineAndScheduleRegular()
        await notifications.clearLowAccuracyNotification()
    }

    private func accuracyRetryContextIsEligible(chave: String, activeProject: String) async -> Bool {
        guard !chave.isEmpty, !activeProject.isEmpty,
              await appPrefs.chave() == chave else { return false }
        let settings = await loadUserSettings(chave)
        guard settings.automaticActivitiesEnabled,
              settings.activeProject == activeProject,
              settings.projects.contains(activeProject) else { return false }
        let pauseSettings = ScheduledPauseSettings(
            scheduledPauseEnabled: settings.scheduledPauseEnabled,
            scheduledPauseFrom: settings.scheduledPauseFrom,
            scheduledPauseTo: settings.scheduledPauseTo,
            suspendSaturdays: settings.suspendSaturdays,
            suspendSundays: settings.suspendSundays)
        let now = clock.now()
        let calendar = Calendar.current
        guard let window = currentScheduledPauseWindow(now, calendar, pauseSettings) else {
            return true
        }
        guard let runtime = scheduledPauseDeferral,
              scheduledPauseRuntime(
                  runtime,
                  matchesChave: chave,
                  activeProject: activeProject,
                  settings: pauseSettings,
                  window: window) else {
            return false
        }
        return runtime.phase == .awaitingCheckout
    }

    private func rawExpectedAction(_ action: CheckAction?) -> String? {
        switch action {
        case .checkIn: return "checkin"
        case .checkOut: return "checkout"
        case nil: return nil
        }
    }

    private func maybeNotifyAccident(
        _ chave: String,
        notifyAccident: Bool,
        lang: String,
        automationGeneration: UInt64,
        sessionGeneration: AuthSessionGeneration
    ) async -> Bool {
        guard notifyAccident,
              automationGeneration == automationContextGeneration,
              sessionGeneration.isCurrentNow else { return false }
        switch await accidentRepository.getState(chave) {
        case .success(let state):
            guard automationGeneration == automationContextGeneration,
                  sessionGeneration.isCurrentNow else { return false }
            let activeIds = Set(state.activeAccidents.map(\.accidentId))
            let seen = await appPrefs.seenAccidentIds()
            guard automationGeneration == automationContextGeneration,
                  sessionGeneration.isCurrentNow else { return false }
            if !activeIds.subtracting(seen).isEmpty {
                guard notifications.postAccidentNotificationIfCurrent(
                    lang: lang,
                    sessionGeneration: sessionGeneration
                ) else { return false }
            }
            guard automationGeneration == automationContextGeneration,
                  sessionGeneration.isCurrentNow else { return false }
            if activeIds != seen {
                guard await appPrefs.setSeenAccidentIdsIfCurrent(
                    activeIds,
                    sessionGeneration: sessionGeneration
                ) else { return false }
            }
            return false
        case .failure(let error):
            guard automationGeneration == automationContextGeneration,
                  sessionGeneration.isCurrentNow,
                  case .unauthorized = error else { return false }
            return true
        }
    }

    func getLocationOptions() async -> BackgroundInputResolution<LocationOptions> {
        await getLocationOptions(automationGeneration: automationContextGeneration)
    }

    private func getLocationOptionsWithAuthRetry(
        chave: String,
        lang: String,
        authRetryBudget: EvaluationAuthRetryBudget,
        contextGeneration: UInt64,
        generation: UInt64,
        pauseGeneration: UInt64
    ) async -> AuthenticatedDependencyResolution<LocationOptions> {
        let first = await getLocationOptions(
            automationGeneration: contextGeneration,
            sessionGeneration: authRetryBudget.sessionGeneration
        )
        if let invalid = await invalidEvaluationContextTerminal(
            stage: .options,
            authRetryBudget: authRetryBudget,
            contextGeneration: contextGeneration,
            generation: generation,
            pauseGeneration: pauseGeneration
        ) {
            return .terminal(invalid)
        }
        guard case .unauthorized? = first.failure else {
            return .resolution(first)
        }
        if let terminal = await terminalPreventingUnauthorizedRetry(
            stage: .options,
            chave: chave,
            lang: lang,
            authRetryBudget: authRetryBudget,
            contextGeneration: contextGeneration,
            generation: generation,
            pauseGeneration: pauseGeneration
        ) {
            return .terminal(terminal)
        }
        let retried = await getLocationOptions(
            automationGeneration: contextGeneration,
            sessionGeneration: authRetryBudget.sessionGeneration
        )
        if let invalid = await invalidEvaluationContextTerminal(
            stage: .options,
            authRetryBudget: authRetryBudget,
            contextGeneration: contextGeneration,
            generation: generation,
            pauseGeneration: pauseGeneration
        ) {
            return .terminal(invalid)
        }
        if case .unauthorized? = retried.failure {
            return .terminal(makeTerminal(outcome: .unauthorized, stage: .options))
        }
        return .resolution(retried)
    }

    private func getLocationOptions(
        automationGeneration: UInt64,
        sessionGeneration: AuthSessionGeneration? = nil
    ) async -> BackgroundInputResolution<LocationOptions> {
        let now = clock.now()
        let cached = cachedOptions
        if let cached, now.timeIntervalSince(cachedOptionsAt) < Self.locationOptionsTTL {
            return .resolved(cached, source: .cache, upstreamFailure: nil)
        }
        switch await checkRepository.getLocations() {
        case .success(let options):
            if automationGeneration == automationContextGeneration,
               sessionGeneration?.isCurrentNow ?? true {
                cachedOptions = options
                cachedOptionsAt = now
            }
            return .resolved(options, source: .remote, upstreamFailure: nil)
        case .failure(let error):
            guard let fallback = offlineFallbackLocationOptions(cached, error) else {
                return .failed(error)
            }
            return .resolved(
                fallback,
                source: cached == nil ? .offlineDefault : .cache,
                upstreamFailure: error
            )
        }
    }

    func getRemoteState(_ chave: String) async -> BackgroundInputResolution<HistoryState> {
        await getRemoteState(chave, automationGeneration: automationContextGeneration)
    }

    private func getRemoteStateWithAuthRetry(
        _ chave: String,
        forceFresh: Bool,
        lang: String,
        authRetryBudget: EvaluationAuthRetryBudget,
        contextGeneration: UInt64,
        generation: UInt64,
        pauseGeneration: UInt64
    ) async -> AuthenticatedDependencyResolution<HistoryState> {
        let first = forceFresh
            ? await getFreshRemoteState(
                chave,
                automationGeneration: contextGeneration,
                sessionGeneration: authRetryBudget.sessionGeneration
            )
            : await getRemoteState(
                chave,
                automationGeneration: contextGeneration,
                sessionGeneration: authRetryBudget.sessionGeneration
            )
        if let invalid = await invalidEvaluationContextTerminal(
            stage: .state,
            authRetryBudget: authRetryBudget,
            contextGeneration: contextGeneration,
            generation: generation,
            pauseGeneration: pauseGeneration
        ) {
            return .terminal(invalid)
        }
        guard case .unauthorized? = first.failure else {
            return .resolution(first)
        }
        if let terminal = await terminalPreventingUnauthorizedRetry(
            stage: .state,
            chave: chave,
            lang: lang,
            authRetryBudget: authRetryBudget,
            contextGeneration: contextGeneration,
            generation: generation,
            pauseGeneration: pauseGeneration
        ) {
            return .terminal(terminal)
        }
        let retried = forceFresh
            ? await getFreshRemoteState(
                chave,
                automationGeneration: contextGeneration,
                sessionGeneration: authRetryBudget.sessionGeneration
            )
            : await getRemoteState(
                chave,
                automationGeneration: contextGeneration,
                sessionGeneration: authRetryBudget.sessionGeneration
            )
        if let invalid = await invalidEvaluationContextTerminal(
            stage: .state,
            authRetryBudget: authRetryBudget,
            contextGeneration: contextGeneration,
            generation: generation,
            pauseGeneration: pauseGeneration
        ) {
            return .terminal(invalid)
        }
        if case .unauthorized? = retried.failure {
            return .terminal(makeTerminal(outcome: .unauthorized, stage: .state))
        }
        return .resolution(retried)
    }

    private func getRemoteState(
        _ chave: String,
        automationGeneration: UInt64,
        sessionGeneration: AuthSessionGeneration? = nil
    ) async -> BackgroundInputResolution<HistoryState> {
        let now = clock.now()
        if chave == cacheChave, let cached = cachedState, now.timeIntervalSince(cachedStateAt) < Self.stateCacheTTL {
            return .resolved(cached, source: .cache, upstreamFailure: nil)
        }
        switch await checkRepository.getState(chave) {
        case .success(let state):
            if automationGeneration == automationContextGeneration,
               sessionGeneration?.isCurrentNow ?? true {
                cachedState = state
                cacheChave = chave
                cachedStateAt = now
            }
            return .resolved(state, source: .remote, upstreamFailure: nil)
        case .failure(let error):
            return .failed(error)
        }
    }

    /// Gate da pausa nunca usa cache e preserva a diferença entre "GET bem-sucedido sem atividade"
    /// (um `HistoryState` cujo último ato é nil) e falha de transporte/autorização.
    func getFreshRemoteState(_ chave: String) async -> BackgroundInputResolution<HistoryState> {
        await getFreshRemoteState(chave, automationGeneration: automationContextGeneration)
    }

    private func getFreshRemoteState(
        _ chave: String,
        automationGeneration: UInt64,
        sessionGeneration: AuthSessionGeneration? = nil
    ) async -> BackgroundInputResolution<HistoryState> {
        let now = clock.now()
        switch await checkRepository.getState(chave) {
        case .success(let state):
            if automationGeneration == automationContextGeneration,
               sessionGeneration?.isCurrentNow ?? true {
                cachedState = state
                cacheChave = chave
                cachedStateAt = now
            }
            return .resolved(state, source: .remote, upstreamFailure: nil)
        case .failure(let error):
            return .failed(error)
        }
    }

    private func evaluateCandidateTimer(
        chave: String,
        userProjects: UserProjects,
        options: LocationOptions,
        stateFromPauseGate: HistoryState?,
        usedFreshState: Bool,
        contextGeneration: UInt64,
        generation: UInt64,
        pauseGeneration: UInt64,
        authRetryBudget: EvaluationAuthRetryBudget,
        lang: String,
        appliesMovementGate: Bool,
        forceFreshState: Bool,
        suppressingDuplicateOf: CheckAction?,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> CandidateTimerEvaluationResult {
        guard authRetryBudget.sessionGeneration.isCurrentNow else {
            return .terminal(lockedResult(.staleContext, stage: .acquisition))
        }
        guard let phased = runAutomaticActivities as? any PhasedRunningAutomaticActivities else {
            return .terminal(lockedResult(.internalFailure, stage: .settings))
        }

        let configuration: AutomaticActivitiesConfiguration
        switch phased.preflight(
            chave: chave,
            userProjects: userProjects,
            mixedZoneIntervalMinutes: options.mixedZoneIntervalMinutes
        ) {
        case .terminal(let execution):
            return .terminal(
                LockedEvaluationResult(
                    terminal: terminalForExecution(execution),
                    legacyEntry: legacyEntry(for: execution.result, trigger: .timer)
                )
            )
        case .ready(let ready):
            configuration = ready
        }

        let prepared: PreparedAutomaticActivitiesMatch
        var movementBaseline: CandidateMovementBaseline?
        lastCaptureAccuracyMeters = nil
        guard authRetryBudget.sessionGeneration.isCurrentNow else {
            return .terminal(lockedResult(.staleContext, stage: .acquisition))
        }
        let movement = await candidateTimerMovement(
            options.accuracyThresholdMeters,
            contextGeneration: contextGeneration,
            generation: generation,
            pauseGeneration: pauseGeneration,
            sessionGeneration: authRetryBudget.sessionGeneration,
            appliesMovementGate: appliesMovementGate
        )

        switch movement {
            case .skip(let trace, let baseline):
                let terminal = addingCaptureDiagnostics(
                    makeTerminal(outcome: .skippedNoMovement, stage: .movement),
                    capture: trace
                )
                let legacyEntry = EvaluationEntry(
                    at: clock.now(),
                    trigger: .timer,
                    accuracyMeters: lastCaptureAccuracyMeters,
                    resolvedLocal: nil,
                    decidedAction: nil,
                    outcome: .skip
                )
                activityLogger.logSystem("Auto-check skipped (no movement).", .info)
                return .terminal(
                    LockedEvaluationResult(
                        terminal: terminal,
                        legacyEntry: legacyEntry,
                        candidateMovementBaseline: baseline
                    )
                )

            case .interrupted(let outcome, let trace):
                var terminal = makeTerminal(outcome: outcome, stage: .movement)
                if let trace {
                    terminal = addingCaptureDiagnostics(terminal, capture: trace)
                }
                return .terminal(
                    LockedEvaluationResult(
                        terminal: terminal,
                        legacyEntry: nil
                    )
                )

            case .failed(let failure):
                return .execution(
                    candidateCaptureFailureExecution(failure),
                    configuration: configuration,
                    prepared: nil,
                    movementBaseline: nil
                )

            case .rejected(let validity, let trace):
                return .execution(
                    AutomaticActivitiesExecution(
                        result: .locationTimeout,
                        trace: AutomaticActivitiesTrace(
                            maximumStage: .captured,
                            capture: trace,
                            failure: .sampleRejected(validity),
                            offlineDisposition: nil
                        ),
                        submissionContext: nil
                    ),
                    configuration: configuration,
                    prepared: nil,
                    movementBaseline: nil
                )

            case .proceed(let sample, let movementTrace, let proposedBaseline):
                guard contextGeneration == automationContextGeneration,
                      generation == accuracyRetryGeneration,
                      pauseGeneration == scheduledPauseGeneration else {
                    return .terminal(
                        LockedEvaluationResult(
                            terminal: addingCaptureDiagnostics(
                                makeTerminal(outcome: .staleContext, stage: .movement),
                                capture: movementTrace
                            ),
                            legacyEntry: nil
                        )
                    )
                }
                guard !Task.isCancelled else {
                    return .terminal(
                        LockedEvaluationResult(
                            terminal: addingCaptureDiagnostics(
                                makeTerminal(outcome: .cancelled, stage: .movement),
                                capture: movementTrace
                            ),
                            legacyEntry: nil
                        )
                    )
                }
                var preparation = await runCancellableAutomaticOperation {
                    await phased.prepare(
                        configuration,
                        accuracyThresholdMeters: options.accuracyThresholdMeters,
                        locationAttempt: .finalSample(sample),
                        effectGuard: effectGuard
                    )
                }
                if let retryContext = preparation.matchRetryContext {
                    if let terminal = await terminalPreventingUnauthorizedRetry(
                        stage: .match,
                        chave: chave,
                        lang: lang,
                        authRetryBudget: authRetryBudget,
                        contextGeneration: contextGeneration,
                        generation: generation,
                        pauseGeneration: pauseGeneration
                    ) {
                        return .terminal(
                            LockedEvaluationResult(
                                terminal: addingCaptureDiagnostics(
                                    terminal,
                                    capture: movementTrace
                                ),
                                legacyEntry: nil
                            )
                        )
                    }
                    preparation = await runCancellableAutomaticOperation {
                        await phased.prepare(
                            retryContext.configuration,
                            accuracyThresholdMeters: retryContext.accuracyThresholdMeters,
                            locationAttempt: retryContext.locationAttempt,
                            effectGuard: effectGuard
                        )
                    }
                }
                if let terminal = await invalidEvaluationContextTerminal(
                    stage: .match,
                    authRetryBudget: authRetryBudget,
                    contextGeneration: contextGeneration,
                    generation: generation,
                    pauseGeneration: pauseGeneration
                ) {
                    return .terminal(
                        LockedEvaluationResult(
                            terminal: addingCaptureDiagnostics(
                                terminal,
                                capture: movementTrace
                            ),
                            legacyEntry: nil
                        )
                    )
                }
                switch preparation {
                case .terminal(let execution):
                    let acceptedBaseline =
                        candidatePreparationAcceptedSample(execution)
                            ? proposedBaseline
                            : nil
                    return .execution(
                        execution,
                        configuration: configuration,
                        prepared: nil,
                        movementBaseline: acceptedBaseline
                    )
                case .ready(let ready):
                    prepared = ready
                    movementBaseline = proposedBaseline
                }
            }

        if let terminal = await invalidEvaluationContextTerminal(
            stage: .match,
            authRetryBudget: authRetryBudget,
            contextGeneration: contextGeneration,
            generation: generation,
            pauseGeneration: pauseGeneration
        ) {
            return .terminal(
                LockedEvaluationResult(
                    terminal: addingCaptureDiagnostics(
                        terminal,
                        capture: prepared.capture
                    ),
                    legacyEntry: nil,
                    candidateMovementBaseline: movementBaseline
                )
            )
        }
        guard !Task.isCancelled else {
            return .execution(
                candidateInterruptionExecution(
                    prepared,
                    reason: .taskCancelled
                ),
                configuration: configuration,
                prepared: prepared,
                movementBaseline: movementBaseline
            )
        }

        let currentState: HistoryState?
        let forcedFreshStateFailure: ApiError?
        if !prepared.requiresCurrentState {
            currentState = nil
            forcedFreshStateFailure = nil
        } else if usedFreshState {
            currentState = stateFromPauseGate
            forcedFreshStateFailure = nil
        } else {
            let authenticatedState = await getRemoteStateWithAuthRetry(
                chave,
                forceFresh: forceFreshState,
                lang: lang,
                authRetryBudget: authRetryBudget,
                contextGeneration: contextGeneration,
                generation: generation,
                pauseGeneration: pauseGeneration
            )
            switch authenticatedState {
            case .terminal(let terminal):
                return .terminal(
                    LockedEvaluationResult(
                        terminal: addingCaptureDiagnostics(
                            terminal,
                            capture: prepared.capture
                        ),
                        legacyEntry: nil,
                        candidateMovementBaseline: movementBaseline
                    )
                )
            case .resolution(let resolution):
                currentState = resolution.value
                forcedFreshStateFailure = forceFreshState
                    ? resolution.failure
                    : nil
            }
        }

        if let terminal = await invalidEvaluationContextTerminal(
            stage: .state,
            authRetryBudget: authRetryBudget,
            contextGeneration: contextGeneration,
            generation: generation,
            pauseGeneration: pauseGeneration
        ) {
            return .terminal(
                LockedEvaluationResult(
                    terminal: addingCaptureDiagnostics(
                        terminal,
                        capture: prepared.capture
                    ),
                    legacyEntry: nil,
                    candidateMovementBaseline: movementBaseline
                )
            )
        }
        guard !Task.isCancelled else {
            return .execution(
                candidateInterruptionExecution(
                    prepared,
                    reason: .taskCancelled
                ),
                configuration: configuration,
                prepared: prepared,
                movementBaseline: movementBaseline
            )
        }
        if let forcedFreshStateFailure {
            return .terminal(
                LockedEvaluationResult(
                    terminal: addingCaptureDiagnostics(
                        terminalForAPIError(
                            forcedFreshStateFailure,
                            stage: .state
                        ),
                        capture: prepared.capture
                    ),
                    legacyEntry: nil,
                    candidateMovementBaseline: movementBaseline
                )
            )
        }

        let completed = await runCancellableAutomaticOperation {
            await phased.complete(
                prepared,
                currentState: currentState,
                suppressingDuplicateOf: suppressingDuplicateOf,
                effectGuard: effectGuard
            )
        }
        return .execution(
            completed,
            configuration: configuration,
            prepared: prepared,
            movementBaseline: movementBaseline
        )
    }

    /// O snapshot lock-backed é revogado de forma síncrona antes que uma transição de identidade aguarde o
    /// barrier do ator. Isso fecha a janela entre o último guard assíncrono e match/fila/submit sem levar
    /// credenciais ou identidade para o Domain.
    private static func automaticActivitiesEffectGuard(
        for authRetryBudget: EvaluationAuthRetryBudget
    ) -> AutomaticActivitiesEffectGuard {
        AutomaticActivitiesEffectGuard(
            sessionGeneration: authRetryBudget.sessionGeneration,
            evaluationValidity: authRetryBudget.evaluationEffectValidity
        )
    }

    /// A invalidação de conta/projeto/toggle cancela a operação automática viva antes de seu próximo efeito
    /// irreversível. Os guards internos do use-case continuam autoritativos para match/fila/submit.
    private func runCancellableAutomaticOperation<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        let operationID = UUID()
        let task = Task { await operation() }
        automaticOperationID = operationID
        cancelAutomaticOperation = { task.cancel() }

        let value = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if automaticOperationID == operationID {
            automaticOperationID = nil
            cancelAutomaticOperation = nil
        }
        return value
    }

    private func candidateTimerMovement(
        _ accuracyThresholdMeters: Int,
        contextGeneration: UInt64,
        generation: UInt64,
        pauseGeneration: UInt64,
        sessionGeneration: AuthSessionGeneration,
        appliesMovementGate: Bool
    ) async -> CandidateTimerMovementResult {
        guard sessionGeneration.isCurrentNow else {
            return .interrupted(.staleContext, nil)
        }
        let provider = locationProvider
        let capture = await runCancellableAutomaticOperation {
            await provider.capture(
                accuracyThresholdMeters,
                seed: nil
            )
        }
        guard case .success(let sample) = capture else {
            if contextGeneration != automationContextGeneration
                || generation != accuracyRetryGeneration
                || pauseGeneration != scheduledPauseGeneration
                || !sessionGeneration.isCurrentNow {
                return .interrupted(.staleContext, nil)
            }
            if Task.isCancelled {
                return .interrupted(.cancelled, nil)
            }
            if case .failure(let failure) = capture {
                return .failed(failure)
            }
            return .failed(.unavailable)
        }

        let evaluatedAt = clock.now()
        let validity = LocationSamplePolicy.candidateTrial.validity(
            of: sample,
            now: evaluatedAt,
            requiredAccuracyMeters: accuracyThresholdMeters
        )
        let trace = candidateMovementTrace(
            sample: sample,
            validity: validity,
            accuracyThresholdMeters: accuracyThresholdMeters,
            evaluatedAt: evaluatedAt
        )
        guard contextGeneration == automationContextGeneration,
              generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration,
              sessionGeneration.isCurrentNow else {
            return .interrupted(.staleContext, trace)
        }
        guard !Task.isCancelled else {
            return .interrupted(.cancelled, trace)
        }

        lastCaptureAccuracyMeters = sample.horizontalAccuracyMeters
        switch validity {
        case .freshButTooInaccurate:
            // Accuracy grosseira não demonstra imobilidade e nunca contamina o baseline.
            return .proceed(sample, trace: trace, baseline: nil)
        case .stale, .invalid, .fromFuture:
            return .rejected(validity, trace)
        case .usable:
            // Um TIMER ocorrido durante episódio de precisão ainda usa o pipeline de captura única, porém
            // mantém a regra histórica: não aplica skip e não altera o baseline desse episódio.
            guard appliesMovementGate else {
                return .proceed(sample, trace: trace, baseline: nil)
            }
            let previousLatitude = lastLat
            let previousLongitude = lastLon
            let proposedBaseline = CandidateMovementBaseline(
                latitude: sample.latitude,
                longitude: sample.longitude
            )
            guard let previousLatitude, let previousLongitude else {
                return .proceed(
                    sample,
                    trace: trace,
                    baseline: proposedBaseline
                )
            }
            let distance = CLLocation(
                latitude: previousLatitude,
                longitude: previousLongitude
            ).distance(
                from: CLLocation(
                    latitude: sample.latitude,
                    longitude: sample.longitude
                )
            )
            if MovementGatePolicy.production.shouldSkip(
                distanceMeters: distance,
                horizontalAccuracyMeters: sample.horizontalAccuracyMeters
            ) {
                return .skip(trace: trace, baseline: proposedBaseline)
            }
            return .proceed(
                sample,
                trace: trace,
                baseline: proposedBaseline
            )
        }
    }

    private func candidateMovementTrace(
        sample: LocationSample,
        validity: LocationSampleValidity,
        accuracyThresholdMeters: Int,
        evaluatedAt: Date
    ) -> AutomaticCaptureTrace {
        let quality: AutomaticCaptureQuality
        switch validity {
        case .usable:
            quality = .usable
        case .freshButTooInaccurate:
            quality = .coarse
        case .stale, .invalid, .fromFuture:
            quality = .rejected(validity)
        }
        let source: AutomaticCaptureSource =
            sample.horizontalAccuracyMeters.isFinite
                && sample.horizontalAccuracyMeters > Double(accuracyThresholdMeters)
                ? .bestPartial
                : .freshCapture
        return AutomaticCaptureTrace(
            source: source,
            physicalSource: sample.source,
            reused: false,
            quality: quality,
            accuracyBucket: .classify(meters: sample.horizontalAccuracyMeters),
            ageBucket: .classify(
                seconds: evaluatedAt.timeIntervalSince(sample.capturedAt)
            )
        )
    }

    private func candidateCaptureFailureExecution(
        _ failure: LocationAcquisitionFailure
    ) -> AutomaticActivitiesExecution {
        let result: AutoActivitiesResult
        switch failure {
        case .timeout, .cancelled:
            result = .locationTimeout
        case .unavailable, .permissionDenied:
            result = .noPermission
        }
        return AutomaticActivitiesExecution(
            result: result,
            trace: AutomaticActivitiesTrace(
                maximumStage: .captureStarted,
                capture: nil,
                failure: .acquisition(failure),
                offlineDisposition: nil
            ),
            submissionContext: nil
        )
    }

    private func candidatePreparationAcceptedSample(
        _ execution: AutomaticActivitiesExecution
    ) -> Bool {
        guard execution.trace.maximumStage.rawValue
                >= AutomaticActivitiesStage.matched.rawValue else {
            return false
        }
        if case .cancelled = execution.trace.failure {
            return false
        }
        return true
    }

    private func candidateInterruptionExecution(
        _ prepared: PreparedAutomaticActivitiesMatch,
        reason: EvaluationCancellationReason
    ) -> AutomaticActivitiesExecution {
        AutomaticActivitiesExecution(
            result: .locationTimeout,
            trace: AutomaticActivitiesTrace(
                maximumStage: .matched,
                capture: prepared.capture,
                failure: .cancelled(reason),
                offlineDisposition: nil
            ),
            submissionContext: nil
        )
    }

    private func shouldSkip(
        _ accuracyThresholdMeters: Int,
        contextGeneration: UInt64,
        generation: UInt64,
        pauseGeneration: UInt64,
        sessionGeneration: AuthSessionGeneration
    ) async -> SkipDecision {
        guard sessionGeneration.isCurrentNow else { return .cancelled }
        let provider = locationProvider
        let capture = await runCancellableAutomaticOperation {
            await provider.capture(accuracyThresholdMeters, seed: nil)
        }
        if case .failure(.cancelled) = capture {
            return .cancelled
        }
        guard contextGeneration == automationContextGeneration,
              generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration,
              sessionGeneration.isCurrentNow else {
            return .cancelled
        }
        guard !Task.isCancelled else { return .cancelled }
        guard case .success(let sample) = capture else {
            return .noFix
        }
        let lat = sample.latitude
        let lon = sample.longitude
        let accuracy = sample.horizontalAccuracyMeters
        lastCaptureAccuracyMeters = accuracy
        // Um fix acima do limite não prova ausência de movimento. Não contamina o baseline e nunca produz
        // SKIP; o match principal precisa enxergar a baixa precisão e abrir/manter o episódio de retry.
        guard accuracy.isFinite, accuracy >= 0, accuracy <= Double(accuracyThresholdMeters) else {
            return .run
        }
        let prevLat = lastLat; let prevLon = lastLon
        lastLat = lat; lastLon = lon
        guard let prevLat, let prevLon else { return .run }   // 1ª vez → RUN
        let distance = CLLocation(latitude: prevLat, longitude: prevLon).distance(from: CLLocation(latitude: lat, longitude: lon))
        let threshold = max(Self.skipThresholdMeters, 2.0 * accuracy)
        return distance < threshold ? .skip : .run
    }

    /// Retorna nil somente quando um refresh foi concluído e o caller está autorizado a repetir a
    /// dependência que produziu 401/403. O orçamento pertence à avaliação inteira, portanto um segundo
    /// unauthorized nunca abre outro login nem reinicia captura/movimento/matriz.
    private func terminalPreventingUnauthorizedRetry(
        stage: EvaluationStage,
        chave: String,
        lang: String,
        authRetryBudget: EvaluationAuthRetryBudget,
        contextGeneration: UInt64,
        generation: UInt64,
        pauseGeneration: UInt64
    ) async -> EvaluationTerminal? {
        if let invalid = await invalidEvaluationContextTerminal(
            stage: stage,
            authRetryBudget: authRetryBudget,
            contextGeneration: contextGeneration,
            generation: generation,
            pauseGeneration: pauseGeneration
        ) {
            return invalid
        }
        guard await authRetryBudget.reserveSilentRelogin() else {
            return makeTerminal(outcome: .unauthorized, stage: stage)
        }

        let result = await authSessionCoordinator.silentRelogin(chave)
        if let invalid = await invalidEvaluationContextTerminal(
            stage: stage,
            authRetryBudget: authRetryBudget,
            contextGeneration: contextGeneration,
            generation: generation,
            pauseGeneration: pauseGeneration
        ) {
            return invalid
        }
        switch result {
        case .refreshed:
            guard authRetryBudget.sessionGeneration.isCurrentNow else {
                return makeTerminal(outcome: .staleContext, stage: stage)
            }
            activityLogger.logAuth("Session refreshed.", .info)
            return nil
        case .missingPassword, .failed:
            guard authRetryBudget.sessionGeneration.isCurrentNow else {
                return makeTerminal(outcome: .staleContext, stage: stage)
            }
            postReauthNotificationCoalesced(lang)
            activityLogger.logError("Re-authentication required.")
            return makeTerminal(outcome: .reloginFailed, stage: stage)
        case .staleContext:
            return makeTerminal(outcome: .staleContext, stage: stage)
        }
    }

    private func invalidEvaluationContextTerminal(
        stage: EvaluationStage,
        authRetryBudget: EvaluationAuthRetryBudget,
        contextGeneration: UInt64,
        generation: UInt64,
        pauseGeneration: UInt64
    ) async -> EvaluationTerminal? {
        if Task.isCancelled {
            return makeTerminal(outcome: .cancelled, stage: stage)
        }
        guard contextGeneration == automationContextGeneration,
              generation == accuracyRetryGeneration,
              pauseGeneration == scheduledPauseGeneration,
              await authSessionCoordinator.isCurrent(
                  authRetryBudget.sessionGeneration
              ) else {
            return makeTerminal(outcome: .staleContext, stage: stage)
        }
        return nil
    }

    private func postReauthNotificationCoalesced(_ lang: String) {
        let now = clock.now()
        if now.timeIntervalSince(lastReauthNotificationAt) > Self.reauthNotificationCooldown {
            notifications.postReauthNotification(lang: lang)
            lastReauthNotificationAt = now
        }
    }

    private func submittedLocal(_ result: AutoActivitiesResult) -> String? {
        if case .submitted(_, let local, _) = result { return local }
        return nil
    }
    private func submittedActionName(_ result: AutoActivitiesResult) -> String? {
        if case .submitted(let action, _, _) = result { return action == .checkIn ? "CHECKIN" : "CHECKOUT" }
        return nil
    }
    private func outcome(of result: AutoActivitiesResult) -> EvaluationOutcome {
        switch result {
        case .submitted: return .submitted
        case .accuracyTooLow, .locationTimeout, .noPermission, .noAction, .notConfigured: return .noAction
        case .networkError: return .networkError
        }
    }
}

private extension OrchestratorTrigger {
    var evaluationTrigger: EvaluationTrigger {
        switch self {
        case .timer: .timer
        case .geofence: .geofence
        case .significantLocation: .significantLocation
        case .foreground: .foreground
        case .accuracyRetry: .accuracyRetry
        case .pauseActivation: .pauseActivation
        case .pauseTransition: .pauseTransition
        }
    }

    var evaluationWake: EvaluationWakeKind {
        switch self {
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
