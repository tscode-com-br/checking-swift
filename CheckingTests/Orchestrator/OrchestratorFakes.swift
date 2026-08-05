import Foundation
@testable import Checking

// Fakes do orquestrador (reusa FakeCheckRepository/FakeLocationProvider/NoopActivityLogger de UseCaseFakes,
// AsyncGate/waitUntil de PlatformFakes, iso/FixedClock do suporte).

final class FakeAppPreferences: AppPreferencesReading, @unchecked Sendable {
    var chaveValue = ""
    var languageValue = "pt"
    var userSettingsJsonValue = ""
    var backgroundLocationConsentAtValue = "2026-01-01T00:00:00Z"
    var accuracyRetryEpisodeJsonValue = ""
    var scheduledPauseDeferralJsonValue = ""
    var seenAccidentIdsValue: Set<Int> = []
    var chaveGate: AsyncGate?                       // se setado, chave() trava até release() (single-flight)
    var chaveGateOnCall: Int?                       // nil preserva o comportamento histórico: trava toda leitura
    var languageGate: AsyncGate?
    var accuracyRetryEpisodeGate: AsyncGate?
    var beforeGuardedSeenWrite: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var setSeenRecorded: [Set<Int>] = []
    private var flagsStore: [String: Bool] = [:]
    private var chaveReadStartedValue = false
    private var chaveReadCountValue = 0
    private var languageReadStartedValue = false
    private var accuracyRetryEpisodeReadStartedValue = false
    var setSeenCalls: [Set<Int>] { lock.withLock { setSeenRecorded } }
    var chaveReadStarted: Bool { lock.withLock { chaveReadStartedValue } }
    var chaveReadCount: Int { lock.withLock { chaveReadCountValue } }
    var languageReadStarted: Bool { lock.withLock { languageReadStartedValue } }
    var accuracyRetryEpisodeReadStarted: Bool {
        lock.withLock { accuracyRetryEpisodeReadStartedValue }
    }

    func chave() async -> String {
        let call = lock.withLock {
            chaveReadStartedValue = true
            chaveReadCountValue += 1
            return chaveReadCountValue
        }
        if let chaveGate, chaveGateOnCall == nil || chaveGateOnCall == call {
            await chaveGate.wait()
        }
        return chaveValue
    }
    func language() async -> String {
        lock.withLock { languageReadStartedValue = true }
        await languageGate?.wait()
        return languageValue
    }
    func userSettingsJson() async -> String { userSettingsJsonValue }
    func backgroundLocationConsentAt() async -> String { backgroundLocationConsentAtValue }
    func seenAccidentIds() async -> Set<Int> { seenAccidentIdsValue }
    func setSeenAccidentIds(_ ids: Set<Int>) async { lock.withLock { setSeenRecorded.append(ids) } }
    func setSeenAccidentIdsIfCurrent(
        _ ids: Set<Int>,
        sessionGeneration: AuthSessionGeneration
    ) async -> Bool {
        beforeGuardedSeenWrite?()
        // Mesma ordem da produção: validity -> lock do fake; nenhum caminho faz a ordem inversa.
        return sessionGeneration.performIfCurrent {
            lock.withLock { setSeenRecorded.append(ids) }
        }
    }
    func getFlag(_ name: String) async -> Bool { lock.withLock { flagsStore[name] ?? false } }
    func setFlag(_ name: String, _ value: Bool) async { lock.withLock { flagsStore[name] = value } }
    func accuracyRetryEpisodeJson() async -> String {
        lock.withLock { accuracyRetryEpisodeReadStartedValue = true }
        await accuracyRetryEpisodeGate?.wait()
        return lock.withLock { accuracyRetryEpisodeJsonValue }
    }
    func setAccuracyRetryEpisodeJson(_ json: String) async {
        lock.withLock { accuracyRetryEpisodeJsonValue = json }
    }
    func scheduledPauseDeferralJson() async -> String {
        lock.withLock { scheduledPauseDeferralJsonValue }
    }
    func setScheduledPauseDeferralJson(_ json: String) async {
        lock.withLock { scheduledPauseDeferralJsonValue = json }
    }
}

final class FakeAccidentStateRepository: AccidentStateReading, @unchecked Sendable {
    var result: AppResult<AccidentState> = .failure(.network)
    var queuedResults: [AppResult<AccidentState>] = []
    var getStateGate: AsyncGate?
    var getStateGateOnCall: Int?
    var getStateStarted: AsyncGate?
    private let lock = NSLock()
    private var count = 0
    var getStateCount: Int { lock.withLock { count } }
    func getState(_ chave: String) async -> AppResult<AccidentState> {
        let snapshot: (value: AppResult<AccidentState>, call: Int) = lock.withLock {
            count += 1
            let value = queuedResults.isEmpty ? result : queuedResults.removeFirst()
            return (value, count)
        }
        await getStateStarted?.release()
        if getStateGateOnCall == nil || getStateGateOnCall == snapshot.call {
            await getStateGate?.wait()
        }
        return snapshot.value
    }
}

final class SpyNotifications: AutoActivityNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var accidents: [String] = []
    private var activities: [(action: CheckAction, local: String?, lang: String)] = []
    private var reauths: [String] = []
    private var pauses: [(started: Bool, lang: String)] = []
    private var lowAccuracies: [(expectedAction: CheckAction?, lang: String)] = []
    private var lowAccuracyClearCount = 0
    var beforeGuardedAccidentPost: (@Sendable () -> Void)?
    var accidentPosts: [String] { lock.withLock { accidents } }
    var activityPosts: [(action: CheckAction, local: String?, lang: String)] { lock.withLock { activities } }
    var reauthPosts: [String] { lock.withLock { reauths } }
    var pausePosts: [(started: Bool, lang: String)] { lock.withLock { pauses } }
    var lowAccuracyPosts: [(expectedAction: CheckAction?, lang: String)] { lock.withLock { lowAccuracies } }
    var clearLowAccuracyCount: Int { lock.withLock { lowAccuracyClearCount } }

    func postAccidentNotification(lang: String) { lock.withLock { accidents.append(lang) } }
    func postAccidentNotificationIfCurrent(
        lang: String,
        sessionGeneration: AuthSessionGeneration
    ) -> Bool {
        beforeGuardedAccidentPost?()
        return sessionGeneration.performIfCurrent {
            postAccidentNotification(lang: lang)
        }
    }
    func postActivityNotification(action: CheckAction, local: String?, lang: String) { lock.withLock { activities.append((action, local, lang)) } }
    func postReauthNotification(lang: String) { lock.withLock { reauths.append(lang) } }
    func postScheduledPauseTransition(started: Bool, lang: String) { lock.withLock { pauses.append((started, lang)) } }
    func postLowAccuracyNotification(expectedAction: CheckAction?, lang: String) async {
        lock.withLock { lowAccuracies.append((expectedAction, lang)) }
    }
    func clearLowAccuracyNotification() async { lock.withLock { lowAccuracyClearCount += 1 } }
}

final class SpyPauseAlarmScheduler: PauseAlarmScheduling, @unchecked Sendable {
    struct ScheduleCall: Equatable {
        let date: Date?
        let notify: Bool
        let lang: String
    }
    private let lock = NSLock()
    private var starts: [ScheduleCall] = []
    private var resumes: [ScheduleCall] = []
    var consumeStartResult = false
    var consumeResumeResult = false
    var startCalls: [ScheduleCall] { lock.withLock { starts } }
    var resumeCalls: [ScheduleCall] { lock.withLock { resumes } }

    func scheduleResume(at: Date?, notify: Bool, lang: String) async {
        lock.withLock { resumes.append(ScheduleCall(date: at, notify: notify, lang: lang)) }
    }
    func scheduleStart(at: Date?, notify: Bool, lang: String) async {
        lock.withLock { starts.append(ScheduleCall(date: at, notify: notify, lang: lang)) }
    }
    func consumeScheduledTransition(started: Bool, dueAtOrBefore now: Date) async -> Bool {
        started ? consumeStartResult : consumeResumeResult
    }
}

final class SpyAppRefreshScheduler: AppRefreshScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var scheduledDates: [Date] = []
    private var regularSchedules = 0
    private var clearedRetryDeadlines = 0
    private var pauseDates: [Date] = []
    private var clearedPauseDeadlines = 0
    private var transitionDates: [Date] = []
    private var clearedTransitionDeadlines = 0
    private var trigger: OrchestratorTrigger = .timer
    var pendingTrigger: OrchestratorTrigger {
        get { lock.withLock { trigger } }
        set { lock.withLock { trigger = newValue } }
    }
    var dates: [Date] { lock.withLock { scheduledDates } }
    var regularScheduleCount: Int { lock.withLock { regularSchedules } }
    var clearRetryDeadlineCount: Int { lock.withLock { clearedRetryDeadlines } }
    var scheduledPauseDates: [Date] { lock.withLock { pauseDates } }
    var clearPauseDeadlineCount: Int { lock.withLock { clearedPauseDeadlines } }
    var scheduledTransitionDates: [Date] { lock.withLock { transitionDates } }
    var clearTransitionDeadlineCount: Int { lock.withLock { clearedTransitionDeadlines } }
    func scheduleRegularRefresh() -> String? {
        lock.withLock { regularSchedules += 1 }
        return nil
    }
    func scheduleAccuracyRetry(at deadline: Date) -> String? {
        lock.withLock { scheduledDates.append(deadline) }
        return nil
    }
    func clearAccuracyRetryDeadlineAndScheduleRegular() -> String? {
        lock.withLock { clearedRetryDeadlines += 1 }
        return nil
    }
    func schedulePauseActivation(at deadline: Date) -> String? {
        lock.withLock { pauseDates.append(deadline) }
        return nil
    }
    func clearPauseActivationDeadlineAndScheduleRegular() -> String? {
        lock.withLock { clearedPauseDeadlines += 1 }
        return nil
    }
    func schedulePauseTransition(at deadline: Date) -> String? {
        lock.withLock { transitionDates.append(deadline) }
        return nil
    }
    func clearPauseTransitionDeadlineAndScheduleRegular() -> String? {
        lock.withLock { clearedTransitionDeadlines += 1 }
        return nil
    }
    func triggerForPendingRefresh() -> OrchestratorTrigger {
        lock.withLock { trigger }
    }
}

actor ControlledAccuracyRetrySleeper: Sleeping {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }
    private var recordedDelays: [Int] = []
    private var waiters: [Waiter] = []
    private var cancelledBeforeRegistration: Set<UUID> = []

    func sleep(milliseconds: Int) async {
        let id = UUID()
        recordedDelays.append(milliseconds)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledBeforeRegistration.remove(id) != nil || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func releaseNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func delays() -> [Int] { recordedDelays }
    func waitingCount() -> Int { waiters.count }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            cancelledBeforeRegistration.insert(id)
            return
        }
        waiters.remove(at: index).continuation.resume()
    }
}

final class SpyAutoActivities: RunningAutomaticActivities, @unchecked Sendable {
    struct Call: Equatable {
        let chave: String
        let userProjects: UserProjects?
        let currentState: HistoryState?
        let mixedZoneIntervalMinutes: Int
        let accuracyThresholdMeters: Int
        let locationAttempt: LocationAttemptInput
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var executionValue = SpyAutoActivities.execution(for: .noAction)

    var callCount: Int { lock.withLock { recordedCalls.count } }
    var calls: [Call] { lock.withLock { recordedCalls } }
    var result: AutoActivitiesResult {
        get { lock.withLock { executionValue.result } }
        set { lock.withLock { executionValue = Self.execution(for: newValue) } }
    }
    var execution: AutomaticActivitiesExecution {
        get { lock.withLock { executionValue } }
        set { lock.withLock { executionValue = newValue } }
    }

    func execute(chave: String, userProjects: UserProjects?, currentState: HistoryState?,
                 mixedZoneIntervalMinutes: Int, accuracyThresholdMeters: Int,
                 locationAttempt: LocationAttemptInput) async -> AutomaticActivitiesExecution {
        lock.withLock {
            recordedCalls.append(Call(
                chave: chave,
                userProjects: userProjects,
                currentState: currentState,
                mixedZoneIntervalMinutes: mixedZoneIntervalMinutes,
                accuracyThresholdMeters: accuracyThresholdMeters,
                locationAttempt: locationAttempt
            ))
            return executionValue
        }
    }

    private static func execution(
        for result: AutoActivitiesResult
    ) -> AutomaticActivitiesExecution {
        let stage: AutomaticActivitiesStage
        switch result {
        case .submitted:
            stage = .submitted
        case .noAction:
            stage = .decisionCompleted
        case .accuracyTooLow:
            stage = .matched
        case .locationTimeout, .noPermission:
            stage = .captureStarted
        case .networkError:
            stage = .matched
        case .notConfigured:
            stage = .started
        }
        return AutomaticActivitiesExecution(
            result: result,
            trace: AutomaticActivitiesTrace(
                maximumStage: stage,
                capture: nil,
                failure: nil,
                offlineDisposition: nil
            ),
            submissionContext: nil
        )
    }
}

struct NoopAuthRepository: AuthRepositoring {
    var result: AppResult<AuthStatus> = .failure(.unknown(description: nil))
    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus> { result }
}

final class SpyAuthRepository: AuthRepositoring, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedChaves: [String] = []
    var result: AppResult<AuthStatus> = .failure(.unknown(description: nil))
    var loginStartedGate: AsyncGate?
    var loginGate: AsyncGate?
    var callCount: Int { lock.withLock { recordedChaves.count } }
    var chaves: [String] { lock.withLock { recordedChaves } }

    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus> {
        lock.withLock { recordedChaves.append(chave) }
        await loginStartedGate?.release()
        await loginGate?.wait()
        return result
    }
}

struct NoopSecurePasswordStore: SecurePasswordReading {
    var password = ""
    func getPassword(_ chave: String) -> String { password }
}

private final class OrchestratorAuthIdentityState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var invalidation: UInt64 = 0
    private var validity = AuthSessionGenerationValidity()

    func snapshot() -> AuthSessionGeneration {
        lock.withLock {
            AuthSessionGeneration(value: generation, validity: validity)
        }
    }

    func isCurrent(_ observed: AuthSessionGeneration) -> Bool {
        lock.withLock {
            observed.value == generation && observed.isCurrentNow
        }
    }

    func invalidate() -> AuthSessionInvalidation {
        lock.withLock {
            validity.invalidate()
            generation &+= 1
            invalidation &+= 1
            validity = AuthSessionGenerationValidity(isCurrent: false)
            return AuthSessionInvalidation(value: invalidation)
        }
    }

    func replaceAndActivate() {
        lock.withLock {
            validity.invalidate()
            generation &+= 1
            validity = AuthSessionGenerationValidity()
        }
    }

    func complete(_ token: AuthSessionInvalidation) {
        lock.withLock {
            guard token.value == invalidation else { return }
            validity.activate()
        }
    }
}

/// Adapter de compatibilidade para as fixtures antigas do orquestrador. Produção recebe a autoridade
/// environment-owned; este actor preserva os spies existentes, o fence síncrono e refreshes coalescidos.
actor OrchestratorAuthSessionCoordinator: AuthSessionCoordinating {
    private struct RefreshSlot: Sendable {
        let chave: String
        let generation: UInt64
        let task: Task<SilentReloginResult, Never>
    }

    private let authRepository: any AuthRepositoring
    private let securePasswordStore: any SecurePasswordReading
    private nonisolated let identityState = OrchestratorAuthIdentityState()
    private var refreshSlot: RefreshSlot?

    init(
        authRepository: any AuthRepositoring,
        securePasswordStore: any SecurePasswordReading
    ) {
        self.authRepository = authRepository
        self.securePasswordStore = securePasswordStore
    }

    func useCurrentSession() -> AuthSessionGeneration {
        identityState.snapshot()
    }

    nonisolated func invalidateCurrentIdentity() -> AuthSessionInvalidation {
        identityState.invalidate()
    }

    func isCurrent(_ observed: AuthSessionGeneration) -> Bool {
        identityState.isCurrent(observed)
    }

    func awaitIdle() async {}

    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus> {
        await authRepository.login(chave, password)
    }

    func registerPassword(
        _ chave: String,
        _ project: String?,
        _ password: String
    ) async -> AppResult<AuthStatus> {
        .failure(.unknown(description: nil))
    }

    func changePassword(
        _ chave: String,
        _ oldPassword: String,
        _ newPassword: String
    ) async -> AppResult<AuthStatus> {
        .failure(.unknown(description: nil))
    }

    func selfRegister(
        _ chave: String,
        _ nome: String,
        _ projetos: [String],
        _ email: String?,
        _ password: String,
        _ confirmPassword: String
    ) async -> AppResult<AuthStatus> {
        .failure(.unknown(description: nil))
    }

    func silentRelogin(_ chave: String) async -> SilentReloginResult {
        let currentGeneration = identityState.snapshot().value
        if let refreshSlot,
           refreshSlot.chave == chave,
           refreshSlot.generation == currentGeneration {
            return await refreshSlot.task.value
        }
        let admittedGeneration = currentGeneration
        let passwordStore = securePasswordStore
        let repository = authRepository
        let task = Task {
            let password = passwordStore.getPassword(chave)
            guard !password.isEmpty else { return SilentReloginResult.missingPassword }
            switch await repository.login(chave, password) {
            case .success(let status): return .refreshed(status)
            case .failure(let error): return .failed(error)
            }
        }
        refreshSlot = RefreshSlot(
            chave: chave,
            generation: admittedGeneration,
            task: task
        )
        let result = await task.value
        if admittedGeneration == identityState.snapshot().value {
            refreshSlot = nil
            return result
        }
        refreshSlot = nil
        return .staleContext
    }

    func replaceIdentity() async { identityState.replaceAndActivate() }
    func explicitLogout() async { identityState.replaceAndActivate() }
    func completeInvalidatedLogout(_ invalidation: AuthSessionInvalidation) async {
        identityState.complete(invalidation)
    }
    func completeInvalidatedTransition(_ invalidation: AuthSessionInvalidation) async {
        identityState.complete(invalidation)
    }
    func deleteAccount() async -> DeleteAccountSessionResult {
        .failed(.unknown(description: nil))
    }
}

actor RecordingEvaluationJournal: EvaluationJournaling {
    struct FinishCall: Sendable, Equatable {
        let id: EvaluationID
        let terminal: EvaluationTerminal
    }

    struct Snapshot: Sendable, Equatable {
        let begins: [EvaluationStart]
        let coalescences: [EvaluationCoalescence]
        let progresses: [EvaluationProgress]
        let finishes: [FinishCall]
        let reconcileOrphansCount: Int
        let recentLimits: [Int]
        let clearCount: Int
    }

    private var begins: [EvaluationStart] = []
    private var coalescences: [EvaluationCoalescence] = []
    private var progresses: [EvaluationProgress] = []
    private var finishes: [FinishCall] = []
    private var reconcileCount = 0
    private var recentLimits: [Int] = []
    private var clears = 0

    func begin(_ start: EvaluationStart) async {
        begins.append(start)
    }

    func coalesce(_ event: EvaluationCoalescence) async {
        if event.targetCount != nil,
           let index = coalescences.firstIndex(where: {
               $0.evaluationID == event.evaluationID
                   && $0.wake == event.wake
                   && $0.targetCount != nil
           }) {
            if (event.targetCount ?? 0) >= (coalescences[index].targetCount ?? 0) {
                coalescences[index] = event
            }
            return
        }
        coalescences.append(event)
    }

    func advance(_ progress: EvaluationProgress) async {
        progresses.append(progress)
    }

    func finish(id: EvaluationID, terminal: EvaluationTerminal) async {
        finishes.append(FinishCall(id: id, terminal: terminal))
    }

    func reconcileOrphans() async {
        reconcileCount += 1
    }

    func recent(limit: Int) async -> [EvaluationRecord] {
        recentLimits.append(limit)
        return []
    }

    func clear() async {
        clears += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            begins: begins,
            coalescences: coalescences,
            progresses: progresses,
            finishes: finishes,
            reconcileOrphansCount: reconcileCount,
            recentLimits: recentLimits,
            clearCount: clears
        )
    }
}

final class SpyBackgroundTaskGuard: BackgroundTaskGuard, @unchecked Sendable {
    private let lock = NSLock()
    private let token: Int
    private var beginCalls = 0
    private var endedTokens: [Int] = []

    init(token: Int = 17) {
        self.token = token
    }

    var beginCount: Int { lock.withLock { beginCalls } }
    var endTokens: [Int] { lock.withLock { endedTokens } }

    func begin() async -> Int {
        lock.withLock {
            beginCalls += 1
            return token
        }
    }

    func end(_ token: Int) {
        lock.withLock {
            endedTokens.append(token)
        }
    }
}

func makeOrchestrator(
    prefs: FakeAppPreferences = FakeAppPreferences(),
    checkRepository: any CheckRepository = FakeCheckRepository(),
    autoActivities: any RunningAutomaticActivities = SpyAutoActivities(),
    accidentRepository: FakeAccidentStateRepository = FakeAccidentStateRepository(),
    notifications: any AutoActivityNotifying = SpyNotifications(),
    locationProvider: any LocationProvider = FakeLocationProvider(.unavailable),
    automaticEvaluationPipeline: BackgroundAutomaticEvaluationPipeline = .legacy,
    applicationStateProvider: (any EvaluationApplicationStateProviding)? = nil,
    clock: any Clock = FixedClock(iso("2026-06-18T09:09:09Z")),
    authRepository: any AuthRepositoring = NoopAuthRepository(),
    securePasswordStore: any SecurePasswordReading = NoopSecurePasswordStore(),
    authSessionCoordinator: (any AuthSessionCoordinating)? = nil,
    pauseAlarms: any PauseAlarmScheduling = NoopPauseAlarmScheduling(),
    accuracyRetrySleeper: any Sleeping = TaskSleeper(),
    pauseActivationSleeper: any Sleeping = TaskSleeper(),
    pauseTransitionSleeper: any Sleeping = TaskSleeper(),
    appRefreshScheduler: any AppRefreshScheduling = NoopAppRefreshScheduler(),
    evaluationJournal: any EvaluationJournaling = NoopEvaluationJournal(),
    makeEvaluationID: @escaping @Sendable () -> EvaluationID = { EvaluationID() },
    backgroundTaskGuard: any BackgroundTaskGuard = NoopBackgroundTaskGuard(),
    backgroundExecutionLeasing: any BackgroundExecutionLeasing = NoopBackgroundExecutionLeasing(),
    activityLogger: any ActivityLogging = NoopActivityLogger()
) -> BackgroundCheckOrchestrator {
    let resolvedAuthSessionCoordinator = authSessionCoordinator
        ?? OrchestratorAuthSessionCoordinator(
            authRepository: authRepository,
            securePasswordStore: securePasswordStore
        )
    return BackgroundCheckOrchestrator(
        appPrefs: prefs, checkRepository: checkRepository, runAutomaticActivities: autoActivities,
        locationProvider: locationProvider, clock: clock,
        authSessionCoordinator: resolvedAuthSessionCoordinator,
        accidentRepository: accidentRepository,
        activityLogger: activityLogger, notifications: notifications,
        automaticEvaluationPipeline: automaticEvaluationPipeline,
        applicationStateProvider: applicationStateProvider,
        evaluationJournal: evaluationJournal,
        makeEvaluationID: makeEvaluationID,
        backgroundTaskGuard: backgroundTaskGuard,
        backgroundExecutionLeasing: backgroundExecutionLeasing,
        pauseAlarms: pauseAlarms,
        accuracyRetrySleeper: accuracyRetrySleeper,
        pauseActivationSleeper: pauseActivationSleeper,
        pauseTransitionSleeper: pauseTransitionSleeper,
        appRefreshScheduler: appRefreshScheduler)
}
