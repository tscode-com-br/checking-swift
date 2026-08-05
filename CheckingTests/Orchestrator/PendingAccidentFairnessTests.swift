import Foundation
import XCTest
@testable import Checking

/// Provas do slot bounded de acidente e da justiça do drain serial do pipeline candidato.
///
/// O probe compartilhado observa somente unidades de trabalho controladas em memória. Os testes não usam
/// sleep real, rede, Core Location ou estado de dispositivo.
final class PendingAccidentFairnessTests: XCTestCase {
    private enum ObservedWork: Sendable, Equatable {
        case automatic(Int)
        case accident(Int)
    }

    private actor ConcurrencyProbe {
        struct Snapshot: Sendable, Equatable {
            let activeCount: Int
            let maximumActiveCount: Int
            let entries: [ObservedWork]
        }

        private var activeCount = 0
        private var maximumActiveCount = 0
        private var entries: [ObservedWork] = []

        func enter(_ work: ObservedWork) {
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
            entries.append(work)
        }

        func leave() {
            activeCount -= 1
        }

        func snapshot() -> Snapshot {
            Snapshot(
                activeCount: activeCount,
                maximumActiveCount: maximumActiveCount,
                entries: entries
            )
        }
    }

    private actor MutableAccidentPreferences: AppPreferencesReading {
        private var notifyAccident = false
        private var seenAccidents: Set<Int> = []
        private var flags: [String: Bool] = [:]
        private var retryEpisodeJSON = ""
        private var pauseDeferralJSON = ""

        func chave() async -> String { "HR70" }
        func language() async -> String { "pt" }

        func userSettingsJson() async -> String {
            let settings = UserSettings(
                projects: ["P80"],
                activeProject: "P80",
                automaticActivitiesEnabled: true,
                scheduledPauseEnabled: false,
                scheduledPauseFrom: "20:00",
                scheduledPauseTo: "07:00",
                suspendSaturdays: false,
                suspendSundays: false,
                notifyActivities: false,
                notifyScheduledPause: false,
                notifyAccident: notifyAccident
            )
            let data = try! JSONCoding.encoder.encode(["HR70": settings])
            return String(decoding: data, as: UTF8.self)
        }

        func backgroundLocationConsentAt() async -> String {
            "2026-01-01T00:00:00Z"
        }

        func seenAccidentIds() async -> Set<Int> { seenAccidents }
        func setSeenAccidentIds(_ ids: Set<Int>) async { seenAccidents = ids }
        func getFlag(_ name: String) async -> Bool { flags[name] ?? false }
        func setFlag(_ name: String, _ value: Bool) async { flags[name] = value }
        func accuracyRetryEpisodeJson() async -> String { retryEpisodeJSON }
        func setAccuracyRetryEpisodeJson(_ json: String) async { retryEpisodeJSON = json }
        func scheduledPauseDeferralJson() async -> String { pauseDeferralJSON }
        func setScheduledPauseDeferralJson(_ json: String) async { pauseDeferralJSON = json }

        func setNotifyAccident(_ enabled: Bool) {
            notifyAccident = enabled
        }
    }

    private actor ControlledAutoActivities: RunningAutomaticActivities {
        private let gates: [AsyncGate?]
        private let probe: ConcurrencyProbe
        private var calls = 0

        init(gates: [AsyncGate?], probe: ConcurrencyProbe) {
            self.gates = gates
            self.probe = probe
        }

        func execute(
            chave: String,
            userProjects: UserProjects?,
            currentState: HistoryState?,
            mixedZoneIntervalMinutes: Int,
            accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> AutomaticActivitiesExecution {
            let index = calls
            calls += 1
            await probe.enter(.automatic(index))
            if index < gates.count {
                await gates[index]?.wait()
            }
            await probe.leave()
            return AutomaticActivitiesExecution(
                result: .noAction,
                trace: AutomaticActivitiesTrace(
                    maximumStage: .decisionCompleted,
                    capture: nil,
                    failure: nil,
                    offlineDisposition: nil
                ),
                submissionContext: nil
            )
        }

        func callCount() -> Int {
            calls
        }
    }

    private actor ControlledAccidentRepository: AccidentStateReading {
        private let gate: AsyncGate
        private let probe: ConcurrencyProbe
        private var calls = 0

        init(gate: AsyncGate, probe: ConcurrencyProbe) {
            self.gate = gate
            self.probe = probe
        }

        func getState(_ chave: String) async -> AppResult<AccidentState> {
            let index = calls
            calls += 1
            await probe.enter(.accident(index))
            await gate.wait()
            await probe.leave()
            return .success(AccidentState(
                isActive: false,
                accidentId: nil,
                accidentNumberLabel: nil,
                projectId: nil,
                projectName: nil,
                locationName: nil,
                description: nil,
                awarenessStatus: nil,
                currentUserReport: nil,
                activeAccidents: []
            ))
        }

        func callCount() -> Int {
            calls
        }
    }

    private actor CompletionCounter {
        private var value = 0

        func increment() {
            value += 1
        }

        func snapshot() -> Int {
            value
        }
    }

    private let now = iso("2026-07-31T08:00:00Z")

    override func setUp() {
        super.setUp()
        EvaluationLog.shared.reset()
    }

    func test_motorOccupied_manyAccidentSignalsShareOnePendingWorkAndCompletion() async {
        let activeGate = AsyncGate()
        let accidentGate = AsyncGate()
        let probe = ConcurrencyProbe()
        let preferences = MutableAccidentPreferences()
        let activities = ControlledAutoActivities(
            gates: [activeGate],
            probe: probe
        )
        let accidentRepository = ControlledAccidentRepository(
            gate: accidentGate,
            probe: probe
        )
        let orchestrator = makeCandidateOrchestrator(
            preferences: preferences,
            activities: activities,
            accidentRepository: accidentRepository
        )

        let occupied = await orchestrator.evaluationTicket(.geofence)
        await waitForAutomaticCalls(1, activities: activities)

        // A avaliação ocupante já leu notifyAccident=false antes de entrar no motor. A mudança vale
        // somente para o trabalho de acidente que será drenado depois dela.
        await preferences.setNotifyAccident(true)
        let completions = CompletionCounter()
        let accidentTasks = await enqueueAccidentSignals(
            count: 16,
            orchestrator: orchestrator,
            completions: completions
        )

        let completionsBeforeRelease = await completions.snapshot()
        let accidentCallsBeforeRelease = await accidentRepository.callCount()
        XCTAssertEqual(completionsBeforeRelease, 0)
        XCTAssertEqual(accidentCallsBeforeRelease, 0)

        await activeGate.release()
        let occupiedCompletion = await occupied.completion()
        XCTAssertEqual(occupiedCompletion.outcome, .noAction)
        await waitForAccidentCalls(1, repository: accidentRepository)

        // Todas as chamadas aguardam o mesmo one-shot: iniciar a query não pode concluir caller algum.
        let completionsWhileBlocked = await completions.snapshot()
        let accidentCallsWhileBlocked = await accidentRepository.callCount()
        XCTAssertEqual(completionsWhileBlocked, 0)
        XCTAssertEqual(accidentCallsWhileBlocked, 1)
        let whileAccidentIsBlocked = await probe.snapshot()
        XCTAssertEqual(whileAccidentIsBlocked.entries, [
            .automatic(0),
            .accident(0),
        ])
        XCTAssertEqual(whileAccidentIsBlocked.maximumActiveCount, 1)
        XCTAssertEqual(whileAccidentIsBlocked.activeCount, 1)

        await accidentGate.release()
        for task in accidentTasks {
            await task.value
        }

        let finalCompletionCount = await completions.snapshot()
        let finalAccidentCalls = await accidentRepository.callCount()
        let finalAutomaticCalls = await activities.callCount()
        XCTAssertEqual(finalCompletionCount, 16)
        XCTAssertEqual(finalAccidentCalls, 1)
        XCTAssertEqual(finalAutomaticCalls, 1)
        let finalProbe = await probe.snapshot()
        XCTAssertEqual(finalProbe.maximumActiveCount, 1)
        XCTAssertEqual(finalProbe.activeCount, 0)
        XCTAssertEqual(finalProbe.entries, [
            .automatic(0),
            .accident(0),
        ])
    }

    func test_normalWakeFlood_doesNotStarveAccident_andPreservesNormalRetryAccidentOrder() async {
        let firstGate = AsyncGate()
        let firstPendingNormalGate = AsyncGate()
        let accidentGate = AsyncGate()
        let probe = ConcurrencyProbe()
        let preferences = MutableAccidentPreferences()
        let activities = ControlledAutoActivities(
            gates: [firstGate, firstPendingNormalGate, nil],
            probe: probe
        )
        let accidentRepository = ControlledAccidentRepository(
            gate: accidentGate,
            probe: probe
        )
        let journal = RecordingEvaluationJournal()
        let orchestrator = makeCandidateOrchestrator(
            preferences: preferences,
            activities: activities,
            accidentRepository: accidentRepository,
            journal: journal
        )

        let first = await orchestrator.evaluationTicket(.geofence)
        await waitForAutomaticCalls(1, activities: activities)

        let retry = await orchestrator.evaluationTicket(.accuracyRetry)
        let normal = await orchestrator.evaluationTicket(.geofence)
        XCTAssertEqual(retry.admission, .deferred)
        XCTAssertEqual(normal.admission, .deferred)

        let accidentCompletions = CompletionCounter()
        let accidentTasks = await enqueueAccidentSignals(
            count: 12,
            orchestrator: orchestrator,
            completions: accidentCompletions
        )

        await firstGate.release()
        _ = await first.completion()
        await waitForAutomaticCalls(2, activities: activities)

        // A ordem aprovada inicia primeiro o pending normal. Enquanto ele permanece bloqueado, retry e
        // acidente continuam pendentes e não possuem terminal.
        let whileFirstPendingNormalIsBlocked = await journal.snapshot()
        XCTAssertEqual(whileFirstPendingNormalIsBlocked.finishes.map(\.id), [
            first.evaluationID,
        ])
        let accidentCallsBeforeNormalTerminal = await accidentRepository.callCount()
        XCTAssertEqual(accidentCallsBeforeNormalTerminal, 0)

        // Enquanto a classe normal atual está ocupada, um flood cria somente o próximo slot normal.
        let nextNormal = await orchestrator.evaluationTicket(.geofence)
        XCTAssertEqual(nextNormal.admission, .deferred)
        var coalescedNormalTickets: [EvaluationTicket] = []
        for trigger in [
            OrchestratorTrigger.timer,
            .significantLocation,
            .geofence,
            .timer,
            .geofence,
            .significantLocation,
            .timer,
            .geofence,
        ] {
            let ticket = await orchestrator.evaluationTicket(trigger)
            XCTAssertEqual(ticket.admission, .coalesced)
            XCTAssertEqual(ticket.evaluationID, nextNormal.evaluationID)
            coalescedNormalTickets.append(ticket)
        }
        let normalPendingDuringFlood = await orchestrator.hasPendingNormalWakeForTest
        XCTAssertTrue(normalPendingDuringFlood)

        // O normal atual já capturou notifyAccident=false. O acidente lerá true; antes de liberar sua
        // query, o valor volta a false para que o normal do ciclo seguinte não gere query incidental.
        await preferences.setNotifyAccident(true)
        await firstPendingNormalGate.release()
        let normalCompletion = await normal.completion()
        XCTAssertEqual(normalCompletion.outcome, .noAction)
        let retryCompletion = await retry.completion()
        XCTAssertEqual(retryCompletion.outcome, .staleContext)
        await waitForAccidentCalls(1, repository: accidentRepository)

        // A classe normal já foi servida neste ciclo. Mesmo com outro normal pending, acidente deve entrar
        // agora, antes do terceiro call do motor; isto é a prova de ausência de starvation.
        let automaticCallsBeforeNextCycle = await activities.callCount()
        let normalStillPending = await orchestrator.hasPendingNormalWakeForTest
        let accidentCompletionsWhileBlocked = await accidentCompletions.snapshot()
        XCTAssertEqual(automaticCallsBeforeNextCycle, 2)
        XCTAssertTrue(normalStillPending)
        XCTAssertEqual(accidentCompletionsWhileBlocked, 0)
        let whileAccidentIsBlocked = await journal.snapshot()
        XCTAssertEqual(whileAccidentIsBlocked.finishes.map(\.id), [
            first.evaluationID,
            normal.evaluationID,
            retry.evaluationID,
        ])
        let observedBeforeNextCycle = await probe.snapshot()
        XCTAssertEqual(observedBeforeNextCycle.entries, [
            .automatic(0),
            .automatic(1),
            .accident(0),
        ])
        XCTAssertEqual(observedBeforeNextCycle.maximumActiveCount, 1)

        await preferences.setNotifyAccident(false)
        await accidentGate.release()
        for task in accidentTasks {
            await task.value
        }
        let finalAccidentCompletionCount = await accidentCompletions.snapshot()
        let accidentCallsAfterCompletion = await accidentRepository.callCount()
        XCTAssertEqual(finalAccidentCompletionCount, 12)
        XCTAssertEqual(accidentCallsAfterCompletion, 1)

        let nextNormalCompletion = await nextNormal.completion()
        XCTAssertEqual(nextNormalCompletion.outcome, .noAction)
        for ticket in coalescedNormalTickets {
            let completion = await ticket.completion()
            XCTAssertEqual(completion, nextNormalCompletion)
        }

        let finalAutomaticCalls = await activities.callCount()
        let finalAccidentCalls = await accidentRepository.callCount()
        XCTAssertEqual(finalAutomaticCalls, 3)
        XCTAssertEqual(finalAccidentCalls, 1)
        let finalJournal = await journal.snapshot()
        XCTAssertEqual(finalJournal.finishes.map(\.id), [
            first.evaluationID,
            normal.evaluationID,
            retry.evaluationID,
            nextNormal.evaluationID,
        ])
        let finalProbe = await probe.snapshot()
        XCTAssertEqual(finalProbe.entries, [
            .automatic(0),
            .automatic(1),
            .accident(0),
            .automatic(2),
        ])
        XCTAssertEqual(finalProbe.maximumActiveCount, 1)
        XCTAssertEqual(finalProbe.activeCount, 0)
    }

    private func makeCandidateOrchestrator(
        preferences: any AppPreferencesReading,
        activities: any RunningAutomaticActivities,
        accidentRepository: any AccidentStateReading,
        journal: any EvaluationJournaling = NoopEvaluationJournal()
    ) -> BackgroundCheckOrchestrator {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(LocationOptions(
            items: ["configured-location"],
            accuracyThresholdMeters: 50,
            mixedZoneIntervalMinutes: 15
        ))
        repository.getStateResult = .success(ucHistory(.checkOut))
        return BackgroundCheckOrchestrator(
            appPrefs: preferences,
            checkRepository: repository,
            runAutomaticActivities: activities,
            locationProvider: FakeLocationProvider(.unavailable),
            clock: FixedClock(now),
            authSessionCoordinator: OrchestratorAuthSessionCoordinator(
                authRepository: NoopAuthRepository(),
                securePasswordStore: NoopSecurePasswordStore()
            ),
            accidentRepository: accidentRepository,
            activityLogger: NoopActivityLogger(),
            notifications: SpyNotifications(),
            automaticEvaluationPipeline: .candidate,
            evaluationJournal: journal,
            backgroundTaskGuard: NoopBackgroundTaskGuard(),
            pauseAlarms: NoopPauseAlarmScheduling(),
            accuracyRetrySleeper: TaskSleeper(),
            pauseActivationSleeper: TaskSleeper(),
            pauseTransitionSleeper: TaskSleeper(),
            appRefreshScheduler: NoopAppRefreshScheduler()
        )
    }

    private func enqueueAccidentSignals(
        count: Int,
        orchestrator: BackgroundCheckOrchestrator,
        completions: CompletionCounter
    ) async -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []
        for _ in 0..<count {
            let task = Task {
                await orchestrator.runAccidentCheck()
                await completions.increment()
            }
            tasks.append(task)
            // `runAccidentCheck` registra o slot antes de aguardar o one-shot. Yields cooperativos deixam
            // essa admissão terminar mantendo o motor ocupante bloqueado, sem depender de tempo real.
            for _ in 0..<8 {
                await Task.yield()
            }
        }
        return tasks
    }

    private func waitForAutomaticCalls(
        _ expected: Int,
        activities: ControlledAutoActivities
    ) async {
        await waitUntil {
            await activities.callCount() == expected
        }
        let callCount = await activities.callCount()
        XCTAssertEqual(callCount, expected)
    }

    private func waitForAccidentCalls(
        _ expected: Int,
        repository: ControlledAccidentRepository
    ) async {
        await waitUntil {
            await repository.callCount() == expected
        }
        let callCount = await repository.callCount()
        XCTAssertEqual(callCount, expected)
    }
}
