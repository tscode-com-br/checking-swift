import Foundation
import XCTest
@testable import Checking

final class DurableEvaluationTerminalTests: XCTestCase {
    private actor GatedAutomaticActivities: RunningAutomaticActivities {
        private let gate: AsyncGate
        private let execution: AutomaticActivitiesExecution
        private var calls = 0

        init(
            gate: AsyncGate,
            execution: AutomaticActivitiesExecution
        ) {
            self.gate = gate
            self.execution = execution
        }

        func execute(
            chave: String,
            userProjects: UserProjects?,
            currentState: HistoryState?,
            mixedZoneIntervalMinutes: Int,
            accuracyThresholdMeters: Int,
            locationAttempt: LocationAttemptInput
        ) async -> AutomaticActivitiesExecution {
            calls += 1
            await gate.wait()
            return execution
        }

        func callCount() -> Int {
            calls
        }
    }

    private final class EvaluationIDFactory: @unchecked Sendable {
        private let lock = NSLock()
        private let values: [EvaluationID]
        private var index = 0

        init(_ values: [EvaluationID]) {
            precondition(!values.isEmpty)
            self.values = values
        }

        func next() -> EvaluationID {
            lock.withLock {
                let value = values[min(index, values.count - 1)]
                index += 1
                return value
            }
        }

        var callCount: Int {
            lock.withLock { index }
        }
    }

    private actor UnavailableEvaluationJournal: EvaluationJournaling {
        struct Attempts: Sendable, Equatable {
            let begins: Int
            let coalescences: Int
            let finishes: Int
        }

        private var beginAttempts = 0
        private var coalescenceAttempts = 0
        private var finishAttempts = 0

        func begin(_ start: EvaluationStart) async {
            beginAttempts += 1
        }

        func coalesce(_ event: EvaluationCoalescence) async {
            coalescenceAttempts += 1
        }

        func finish(id: EvaluationID, terminal: EvaluationTerminal) async {
            finishAttempts += 1
        }

        func reconcileOrphans() async {}
        func recent(limit: Int) async -> [EvaluationRecord] { [] }
        func clear() async {}

        func attempts() -> Attempts {
            Attempts(
                begins: beginAttempts,
                coalescences: coalescenceAttempts,
                finishes: finishAttempts
            )
        }
    }

    private final class ScriptedOptionsRepository: CheckRepository, @unchecked Sendable {
        private let lock = NSLock()
        private let base: FakeCheckRepository
        private var optionResults: [AppResult<LocationOptions>]
        private var optionCalls = 0

        init(
            optionResults: [AppResult<LocationOptions>],
            state: HistoryState
        ) {
            precondition(!optionResults.isEmpty)
            self.optionResults = optionResults
            base = FakeCheckRepository()
            base.getStateResult = .success(state)
        }

        var getLocationsCallCount: Int {
            lock.withLock { optionCalls }
        }

        func matchLocation(
            _ lat: Double,
            _ lon: Double,
            _ accuracyMeters: Double?
        ) async -> AppResult<LocationMatch> {
            await base.matchLocation(lat, lon, accuracyMeters)
        }

        func getState(_ chave: String) async -> AppResult<HistoryState> {
            await base.getState(chave)
        }

        func getHistory(_ chave: String) async -> AppResult<[CheckHistoryEntry]> {
            await base.getHistory(chave)
        }

        func getLocations() async -> AppResult<LocationOptions> {
            lock.withLock {
                optionCalls += 1
                if optionResults.count > 1 {
                    return optionResults.removeFirst()
                }
                return optionResults[0]
            }
        }

        func getGeofences(_ chave: String) async -> AppResult<[GeofenceCircle]> {
            await base.getGeofences(chave)
        }

        func invalidateGeofenceCache() {
            base.invalidateGeofenceCache()
        }

        func submit(
            chave: String,
            projeto: String,
            action: CheckAction,
            local: String?,
            informe: InformeType,
            eventTime: Date,
            clientEventId: String,
            fillForms: Bool
        ) async -> AppResult<HistoryState> {
            await base.submit(
                chave: chave,
                projeto: projeto,
                action: action,
                local: local,
                informe: informe,
                eventTime: eventTime,
                clientEventId: clientEventId,
                fillForms: fillForms
            )
        }
    }

    private struct OperationalCase {
        let name: String
        let execution: AutomaticActivitiesExecution
        let expectedOutcome: EvaluationTerminalOutcome
        let expectedStage: EvaluationStage
        let expectedHTTP: EvaluationHTTPDiagnostic?
        let expectedLegacyOutcome: EvaluationOutcome
        let forbiddenSentinels: [String]
    }

    private let now = iso("2026-06-18T09:09:09Z")

    override func setUp() {
        super.setUp()
        EvaluationLog.shared.reset()
    }

    private func evaluationID(_ value: Int) -> EvaluationID {
        let suffix = String(format: "%012d", value)
        return EvaluationID(
            UUID(uuidString: "10000000-0000-0000-0000-\(suffix)")!
        )
    }

    private func activePreferences(
        automaticActivitiesEnabled: Bool = true,
        scheduledPauseEnabled: Bool = false,
        notifyActivities: Bool = false
    ) -> FakeAppPreferences {
        let settings = UserSettings(
            projects: ["P80"],
            activeProject: "P80",
            automaticActivitiesEnabled: automaticActivitiesEnabled,
            scheduledPauseEnabled: scheduledPauseEnabled,
            scheduledPauseFrom: scheduledPauseEnabled ? "00:00" : "20:00",
            scheduledPauseTo: scheduledPauseEnabled ? "23:59" : "07:00",
            suspendSaturdays: false,
            suspendSundays: false,
            notifyActivities: notifyActivities,
            notifyScheduledPause: false,
            notifyAccident: false
        )
        let data = try! JSONCoding.encoder.encode(["HR70": settings])
        let preferences = FakeAppPreferences()
        preferences.chaveValue = "HR70"
        preferences.languageValue = "pt"
        preferences.userSettingsJsonValue = String(data: data, encoding: .utf8)!
        return preferences
    }

    private func state(
        _ action: CheckAction?,
        at date: Date? = nil
    ) -> HistoryState {
        HistoryState(
            found: action != nil,
            chave: "HR70",
            projeto: "P80",
            currentAction: action,
            currentLocal: action == .checkIn ? "Unidade P80" : nil,
            hasCurrentDayCheckin: action == .checkIn,
            lastCheckinAt: action == .checkIn ? date : nil,
            lastCheckoutAt: action == .checkOut ? date : nil,
            transportEnabled: false
        )
    }

    private func repository(
        state: HistoryState? = nil
    ) -> FakeCheckRepository {
        let repository = FakeCheckRepository()
        repository.getLocationsResult = .success(
            LocationOptions(
                items: ["Unidade P80"],
                accuracyThresholdMeters: 50,
                mixedZoneIntervalMinutes: 15
            )
        )
        repository.getStateResult = .success(
            state ?? self.state(.checkOut, at: now.addingTimeInterval(-60))
        )
        return repository
    }

    private func automaticExecution(
        result: AutoActivitiesResult,
        stage: AutomaticActivitiesStage,
        capture: AutomaticCaptureTrace? = nil,
        failure: AutomaticActivitiesFailure? = nil,
        offlineDisposition: AutomaticOfflineDisposition? = nil,
        submissionContext: AutomaticSubmissionContext? = nil
    ) -> AutomaticActivitiesExecution {
        AutomaticActivitiesExecution(
            result: result,
            trace: AutomaticActivitiesTrace(
                maximumStage: stage,
                capture: capture,
                failure: failure,
                offlineDisposition: offlineDisposition
            ),
            submissionContext: submissionContext
        )
    }

    private func assertSingleTerminal(
        _ journal: RecordingEvaluationJournal,
        completion: EvaluationCompletion,
        expectedID: EvaluationID,
        outcome: EvaluationTerminalOutcome,
        stage: EvaluationStage,
        trigger: EvaluationTrigger,
        http: EvaluationHTTPDiagnostic? = nil,
        completedBeforeExpiration: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let snapshot = await journal.snapshot()
        XCTAssertTrue(completion.admitted, file: file, line: line)
        XCTAssertEqual(
            completion.completedBeforeExpiration,
            completedBeforeExpiration,
            file: file,
            line: line
        )
        XCTAssertEqual(completion.evaluationID, expectedID, file: file, line: line)
        XCTAssertEqual(completion.outcome, outcome, file: file, line: line)
        XCTAssertEqual(snapshot.begins.count, 1, file: file, line: line)
        XCTAssertEqual(snapshot.finishes.count, 1, file: file, line: line)
        XCTAssertTrue(snapshot.coalescences.isEmpty, file: file, line: line)
        XCTAssertEqual(snapshot.begins.first?.id, expectedID, file: file, line: line)
        XCTAssertEqual(snapshot.begins.first?.trigger, trigger, file: file, line: line)
        XCTAssertEqual(snapshot.begins.first?.stage, .restore, file: file, line: line)
        XCTAssertEqual(snapshot.finishes.first?.id, expectedID, file: file, line: line)
        XCTAssertEqual(snapshot.finishes.first?.terminal.outcome, outcome, file: file, line: line)
        XCTAssertEqual(snapshot.finishes.first?.terminal.stage, stage, file: file, line: line)
        XCTAssertEqual(snapshot.finishes.first?.terminal.http, http, file: file, line: line)
    }

    private func waitFor(
        _ condition: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("condition was not reached", file: file, line: line)
    }

    func test_noKeyBeginsAndFinishesExactlyOnceWithoutLegacyEntry() async {
        let id = evaluationID(1)
        let ids = EvaluationIDFactory([id])
        let journal = RecordingEvaluationJournal()
        let guardSpy = SpyBackgroundTaskGuard()
        let automatic = SpyAutoActivities()
        let sut = makeOrchestrator(
            autoActivities: automatic,
            evaluationJournal: journal,
            makeEvaluationID: { ids.next() },
            backgroundTaskGuard: guardSpy
        )

        let completion = await sut.runOnce(.foreground)

        await assertSingleTerminal(
            journal,
            completion: completion,
            expectedID: id,
            outcome: .noKey,
            stage: .settings,
            trigger: .foreground
        )
        XCTAssertEqual(ids.callCount, 1)
        XCTAssertEqual(automatic.callCount, 0)
        XCTAssertTrue(EvaluationLog.shared.isEmpty())
        XCTAssertEqual(guardSpy.beginCount, 1)
        XCTAssertEqual(guardSpy.endTokens, [17])
    }

    func test_toggleOffPreservesLegacyLogAndByteExactActivityLines() async {
        let id = evaluationID(2)
        let ids = EvaluationIDFactory([id])
        let journal = RecordingEvaluationJournal()
        let guardSpy = SpyBackgroundTaskGuard()
        let dao = CapturingDao()
        let logger = ActivityLogger(
            clock: FixedClock(now),
            activityLog: ActivityLog(dao: dao),
            scheduler: InlineLogScheduler()
        )
        let preferences = FakeAppPreferences()
        preferences.chaveValue = "HR70"
        preferences.languageValue = "pt"
        preferences.userSettingsJsonValue = ""
        let automatic = SpyAutoActivities()
        let sut = makeOrchestrator(
            prefs: preferences,
            autoActivities: automatic,
            clock: FixedClock(now),
            evaluationJournal: journal,
            makeEvaluationID: { ids.next() },
            backgroundTaskGuard: guardSpy,
            activityLogger: logger
        )

        let completion = await sut.runOnce(.foreground)

        await assertSingleTerminal(
            journal,
            completion: completion,
            expectedID: id,
            outcome: .toggleOff,
            stage: .settings,
            trigger: .foreground
        )
        XCTAssertEqual(automatic.callCount, 0)
        XCTAssertEqual(EvaluationLog.shared.snapshot().map(\.outcome), [.toggleOff])
        XCTAssertEqual(
            dao.rows.map(\.description),
            [
                "Background evaluation (FOREGROUND).",
                "Automatic activities are OFF.",
            ]
        )
        XCTAssertEqual(guardSpy.beginCount, 1)
        XCTAssertEqual(guardSpy.endTokens, [17])
    }

    func test_pauseGatePausedAndGraceNoActionEachFinishOnceWithoutCallingEngine() async {
        let cases: [
            (
                name: String,
                remoteState: HistoryState,
                outcome: EvaluationTerminalOutcome,
                legacy: EvaluationOutcome,
                id: EvaluationID
            )
        ] = [
            (
                "already checked out before window",
                state(.checkOut, at: now.addingTimeInterval(-24 * 60 * 60)),
                .paused,
                .paused,
                evaluationID(3)
            ),
            (
                "recent checkout enters grace",
                state(.checkOut, at: now),
                .noAction,
                .noAction,
                evaluationID(4)
            ),
        ]

        for testCase in cases {
            EvaluationLog.shared.reset()
            let journal = RecordingEvaluationJournal()
            let automatic = SpyAutoActivities()
            let guardSpy = SpyBackgroundTaskGuard()
            let activationSleeper = ControlledAccuracyRetrySleeper()
            let transitionSleeper = ControlledAccuracyRetrySleeper()
            let sut = makeOrchestrator(
                prefs: activePreferences(scheduledPauseEnabled: true),
                checkRepository: repository(state: testCase.remoteState),
                autoActivities: automatic,
                clock: FixedClock(now),
                pauseActivationSleeper: activationSleeper,
                pauseTransitionSleeper: transitionSleeper,
                evaluationJournal: journal,
                makeEvaluationID: { testCase.id },
                backgroundTaskGuard: guardSpy
            )

            let completion = await sut.runOnce(.pauseTransition)

            await assertSingleTerminal(
                journal,
                completion: completion,
                expectedID: testCase.id,
                outcome: testCase.outcome,
                stage: .pause,
                trigger: .pauseTransition
            )
            XCTAssertEqual(automatic.callCount, 0, testCase.name)
            XCTAssertEqual(
                EvaluationLog.shared.snapshot().first?.outcome,
                testCase.legacy,
                testCase.name
            )
            XCTAssertEqual(guardSpy.beginCount, 1, testCase.name)
            XCTAssertEqual(guardSpy.endTokens, [17], testCase.name)

            await sut.invalidateAutomationContext()
        }
    }

    func test_operationalTerminalMatrixHasOneFinishCorrectStageAndSanitizedDiagnostics() async {
        let httpDetail = "HTTP_DETAIL_SENTINEL_MUST_NOT_REACH_JOURNAL"
        let unknownDescription = "UNKNOWN_DESCRIPTION_SENTINEL_MUST_NOT_REACH_JOURNAL"
        let keySentinel = "KEY_SENTINEL_MUST_NOT_REACH_JOURNAL"
        let projectSentinel = "PROJECT_SENTINEL_MUST_NOT_REACH_JOURNAL"
        let locationSentinel = "LOCATION_SENTINEL_MUST_NOT_REACH_JOURNAL"
        let submission = AutomaticSubmissionContext(
            chave: keySentinel,
            projeto: projectSentinel,
            action: .checkIn,
            local: locationSentinel,
            informe: .normal,
            eventTime: now,
            clientEventId: "CLIENT_EVENT_SENTINEL_MUST_NOT_REACH_JOURNAL",
            fillForms: true
        )
        let checkInState = state(.checkIn, at: now)
        let checkOutState = state(.checkOut, at: now)
        let cases: [OperationalCase] = [
            OperationalCase(
                name: "location timeout",
                execution: automaticExecution(
                    result: .locationTimeout,
                    stage: .captureStarted,
                    failure: .acquisition(.timeout)
                ),
                expectedOutcome: .locationTimeout,
                expectedStage: .acquisition,
                expectedHTTP: nil,
                expectedLegacyOutcome: .noAction,
                forbiddenSentinels: []
            ),
            OperationalCase(
                name: "location unavailable",
                execution: automaticExecution(
                    result: .noPermission,
                    stage: .captureStarted,
                    failure: .acquisition(.unavailable)
                ),
                expectedOutcome: .unavailable,
                expectedStage: .acquisition,
                expectedHTTP: nil,
                expectedLegacyOutcome: .noAction,
                forbiddenSentinels: []
            ),
            OperationalCase(
                name: "permission denied",
                execution: automaticExecution(
                    result: .noPermission,
                    stage: .captureStarted,
                    failure: .acquisition(.permissionDenied)
                ),
                expectedOutcome: .permissionDenied,
                expectedStage: .acquisition,
                expectedHTTP: nil,
                expectedLegacyOutcome: .noAction,
                forbiddenSentinels: []
            ),
            OperationalCase(
                name: "accuracy too low",
                execution: automaticExecution(
                    result: .accuracyTooLow(expectedAction: .checkIn),
                    stage: .matched
                ),
                expectedOutcome: .accuracyTooLow,
                expectedStage: .match,
                expectedHTTP: nil,
                expectedLegacyOutcome: .noAction,
                forbiddenSentinels: []
            ),
            OperationalCase(
                name: "match network",
                execution: automaticExecution(
                    result: .networkError,
                    stage: .matched,
                    failure: .match(.network)
                ),
                expectedOutcome: .networkFailure,
                expectedStage: .match,
                expectedHTTP: nil,
                expectedLegacyOutcome: .networkError,
                forbiddenSentinels: []
            ),
            OperationalCase(
                name: "raw queued",
                execution: automaticExecution(
                    result: .networkError,
                    stage: .matched,
                    failure: .match(.network),
                    offlineDisposition: .queuedRaw
                ),
                expectedOutcome: .queuedOfflineRaw,
                expectedStage: .match,
                expectedHTTP: nil,
                expectedLegacyOutcome: .networkError,
                forbiddenSentinels: []
            ),
            OperationalCase(
                name: "decided queued",
                execution: automaticExecution(
                    result: .networkError,
                    stage: .submitStarted,
                    failure: .submit(.network),
                    offlineDisposition: .queuedDecided,
                    submissionContext: submission
                ),
                expectedOutcome: .queuedOfflineDecided,
                expectedStage: .submit,
                expectedHTTP: nil,
                expectedLegacyOutcome: .networkError,
                forbiddenSentinels: [
                    keySentinel,
                    projectSentinel,
                    locationSentinel,
                    submission.clientEventId,
                ]
            ),
            OperationalCase(
                name: "submit HTTP 422",
                execution: automaticExecution(
                    result: .networkError,
                    stage: .submitStarted,
                    failure: .submit(.http(status: 422, detail: httpDetail)),
                    submissionContext: submission
                ),
                expectedOutcome: .httpRejected,
                expectedStage: .submit,
                expectedHTTP: EvaluationHTTPDiagnostic(status: 422),
                expectedLegacyOutcome: .networkError,
                forbiddenSentinels: [
                    httpDetail,
                    keySentinel,
                    projectSentinel,
                    locationSentinel,
                    submission.clientEventId,
                ]
            ),
            OperationalCase(
                name: "submit unknown",
                execution: automaticExecution(
                    result: .networkError,
                    stage: .submitStarted,
                    failure: .submit(.unknown(description: unknownDescription)),
                    submissionContext: submission
                ),
                expectedOutcome: .internalFailure,
                expectedStage: .submit,
                expectedHTTP: nil,
                expectedLegacyOutcome: .networkError,
                forbiddenSentinels: [
                    unknownDescription,
                    keySentinel,
                    projectSentinel,
                    locationSentinel,
                    submission.clientEventId,
                ]
            ),
            OperationalCase(
                name: "no action",
                execution: automaticExecution(
                    result: .noAction,
                    stage: .decisionCompleted
                ),
                expectedOutcome: .noAction,
                expectedStage: .decision,
                expectedHTTP: nil,
                expectedLegacyOutcome: .noAction,
                forbiddenSentinels: []
            ),
            OperationalCase(
                name: "submitted check-in",
                execution: automaticExecution(
                    result: .submitted(
                        action: .checkIn,
                        local: "Unidade P80",
                        newState: checkInState
                    ),
                    stage: .submitted,
                    submissionContext: submission
                ),
                expectedOutcome: .submittedCheckIn,
                expectedStage: .submit,
                expectedHTTP: nil,
                expectedLegacyOutcome: .submitted,
                forbiddenSentinels: [
                    keySentinel,
                    projectSentinel,
                    locationSentinel,
                    submission.clientEventId,
                ]
            ),
            OperationalCase(
                name: "submitted check-out",
                execution: automaticExecution(
                    result: .submitted(
                        action: .checkOut,
                        local: "Fora do Local de Trabalho",
                        newState: checkOutState
                    ),
                    stage: .submitted,
                    submissionContext: submission
                ),
                expectedOutcome: .submittedCheckOut,
                expectedStage: .submit,
                expectedHTTP: nil,
                expectedLegacyOutcome: .submitted,
                forbiddenSentinels: [
                    keySentinel,
                    projectSentinel,
                    locationSentinel,
                    submission.clientEventId,
                ]
            ),
            OperationalCase(
                name: "not configured",
                execution: automaticExecution(
                    result: .notConfigured,
                    stage: .started
                ),
                expectedOutcome: .notConfigured,
                expectedStage: .settings,
                expectedHTTP: nil,
                expectedLegacyOutcome: .noAction,
                forbiddenSentinels: []
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            EvaluationLog.shared.reset()
            let id = evaluationID(100 + index)
            let journal = RecordingEvaluationJournal()
            let guardSpy = SpyBackgroundTaskGuard()
            let automatic = SpyAutoActivities()
            automatic.execution = testCase.execution
            let sut = makeOrchestrator(
                prefs: activePreferences(),
                checkRepository: repository(),
                autoActivities: automatic,
                clock: FixedClock(now),
                evaluationJournal: journal,
                makeEvaluationID: { id },
                backgroundTaskGuard: guardSpy
            )

            let completion = await sut.runOnce(.geofence)

            await assertSingleTerminal(
                journal,
                completion: completion,
                expectedID: id,
                outcome: testCase.expectedOutcome,
                stage: testCase.expectedStage,
                trigger: .geofence,
                http: testCase.expectedHTTP
            )
            XCTAssertEqual(automatic.callCount, 1, testCase.name)
            XCTAssertEqual(guardSpy.beginCount, 1, testCase.name)
            XCTAssertEqual(guardSpy.endTokens, [17], testCase.name)
            XCTAssertEqual(
                EvaluationLog.shared.snapshot().first?.outcome,
                testCase.expectedLegacyOutcome,
                testCase.name
            )

            let snapshot = await journal.snapshot()
            if testCase.expectedOutcome == .submittedCheckIn
                || testCase.expectedOutcome == .submittedCheckOut {
                XCTAssertEqual(
                    snapshot.finishes.first?.terminal.notificationScheduled,
                    false,
                    testCase.name
                )
            }
            let terminalRepresentation = String(
                reflecting: snapshot.finishes.first?.terminal
            )
            for sentinel in testCase.forbiddenSentinels {
                XCTAssertFalse(
                    terminalRepresentation.contains(sentinel),
                    "\(testCase.name): leaked \(sentinel)"
                )
            }
        }
    }

    func test_optionsHardFailuresAndUnauthorizedReloginHaveOneTypedTerminal() async {
        let detailSentinel = "OPTIONS_DETAIL_SENTINEL_MUST_NOT_REACH_JOURNAL"
        let descriptionSentinel = "OPTIONS_UNKNOWN_SENTINEL_MUST_NOT_REACH_JOURNAL"
        let hardFailures: [
            (
                name: String,
                error: ApiError,
                outcome: EvaluationTerminalOutcome,
                http: EvaluationHTTPDiagnostic?
            )
        ] = [
            (
                "HTTP 422",
                .http(status: 422, detail: detailSentinel),
                .httpRejected,
                EvaluationHTTPDiagnostic(status: 422)
            ),
            (
                "other 4xx",
                .http(status: 418, detail: detailSentinel),
                .httpRejected,
                EvaluationHTTPDiagnostic(status: 418)
            ),
            (
                "HTTP 500",
                .http(status: 500, detail: detailSentinel),
                .httpRejected,
                EvaluationHTTPDiagnostic(status: 500)
            ),
            (
                "conflict",
                .conflict,
                .conflict,
                EvaluationHTTPDiagnostic(status: 409)
            ),
            (
                "unknown",
                .unknown(description: descriptionSentinel),
                .internalFailure,
                nil
            ),
        ]

        for (index, testCase) in hardFailures.enumerated() {
            EvaluationLog.shared.reset()
            let id = evaluationID(200 + index)
            let journal = RecordingEvaluationJournal()
            let repository = repository()
            repository.getLocationsResult = .failure(testCase.error)
            let automatic = SpyAutoActivities()
            let auth = SpyAuthRepository()
            let guardSpy = SpyBackgroundTaskGuard()
            let sut = makeOrchestrator(
                prefs: activePreferences(),
                checkRepository: repository,
                autoActivities: automatic,
                clock: FixedClock(now),
                authRepository: auth,
                securePasswordStore: NoopSecurePasswordStore(
                    password: "password-sentinel"
                ),
                evaluationJournal: journal,
                makeEvaluationID: { id },
                backgroundTaskGuard: guardSpy
            )

            let completion = await sut.runOnce(.significantLocation)

            await assertSingleTerminal(
                journal,
                completion: completion,
                expectedID: id,
                outcome: testCase.outcome,
                stage: .options,
                trigger: .significantLocation,
                http: testCase.http
            )
            XCTAssertEqual(repository.getLocationsCallCount, 1, testCase.name)
            XCTAssertEqual(repository.getStateCallCount, 0, testCase.name)
            XCTAssertEqual(automatic.callCount, 0, testCase.name)
            XCTAssertEqual(
                auth.callCount,
                0,
                "HTTP 422 e demais falhas não-auth nunca podem iniciar relogin"
            )
            XCTAssertTrue(EvaluationLog.shared.isEmpty(), testCase.name)
            XCTAssertEqual(guardSpy.endTokens, [17], testCase.name)

            let snapshot = await journal.snapshot()
            let representation = String(reflecting: snapshot.finishes[0].terminal)
            XCTAssertFalse(representation.contains(detailSentinel), testCase.name)
            XCTAssertFalse(representation.contains(descriptionSentinel), testCase.name)
        }

        let authenticated = AuthStatus(
            found: true,
            chave: "HR70",
            hasPassword: true,
            authenticated: true,
            message: "ok"
        )
        let validOptions = LocationOptions(
            items: ["Unidade P80"],
            accuracyThresholdMeters: 50,
            mixedZoneIntervalMinutes: 15
        )
        let unauthorizedCases: [
            (
                name: String,
                optionResults: [AppResult<LocationOptions>],
                authResult: AppResult<AuthStatus>,
                outcome: EvaluationTerminalOutcome,
                stage: EvaluationStage,
                engineCalls: Int,
                reauthPosts: Int,
                id: EvaluationID
            )
        ] = [
            (
                "relogin succeeds then options retry succeeds",
                [.failure(.unauthorized), .success(validOptions)],
                .success(authenticated),
                .noAction,
                .decision,
                1,
                0,
                evaluationID(210)
            ),
            (
                "relogin fails",
                [.failure(.unauthorized)],
                .failure(.network),
                .reloginFailed,
                .options,
                0,
                1,
                evaluationID(211)
            ),
            (
                "relogin succeeds but options retry is still unauthorized",
                [.failure(.unauthorized), .failure(.unauthorized)],
                .success(authenticated),
                .unauthorized,
                .options,
                0,
                0,
                evaluationID(212)
            ),
        ]

        for testCase in unauthorizedCases {
            EvaluationLog.shared.reset()
            let journal = RecordingEvaluationJournal()
            let repository = ScriptedOptionsRepository(
                optionResults: testCase.optionResults,
                state: state(.checkOut, at: now.addingTimeInterval(-60))
            )
            let automatic = SpyAutoActivities()
            automatic.result = .noAction
            let auth = SpyAuthRepository()
            auth.result = testCase.authResult
            let notifications = SpyNotifications()
            let guardSpy = SpyBackgroundTaskGuard()
            let sut = makeOrchestrator(
                prefs: activePreferences(),
                checkRepository: repository,
                autoActivities: automatic,
                notifications: notifications,
                clock: FixedClock(now),
                authRepository: auth,
                securePasswordStore: NoopSecurePasswordStore(password: "password-sentinel"),
                evaluationJournal: journal,
                makeEvaluationID: { testCase.id },
                backgroundTaskGuard: guardSpy
            )

            let completion = await sut.runOnce(.geofence)

            await assertSingleTerminal(
                journal,
                completion: completion,
                expectedID: testCase.id,
                outcome: testCase.outcome,
                stage: testCase.stage,
                trigger: .geofence
            )
            XCTAssertEqual(
                repository.getLocationsCallCount,
                testCase.optionResults.count,
                testCase.name
            )
            XCTAssertEqual(auth.callCount, 1, testCase.name)
            XCTAssertEqual(automatic.callCount, testCase.engineCalls, testCase.name)
            XCTAssertEqual(
                notifications.reauthPosts.count,
                testCase.reauthPosts,
                testCase.name
            )
            XCTAssertEqual(guardSpy.endTokens, [17], testCase.name)
        }
    }

    func test_obsoleteRetryAndPauseActivationTriggersEachFinishStaleExactlyOnce() async {
        let cases: [
            (
                trigger: OrchestratorTrigger,
                journalTrigger: EvaluationTrigger,
                stage: EvaluationStage,
                id: EvaluationID
            )
        ] = [
            (.accuracyRetry, .accuracyRetry, .restore, evaluationID(213)),
            (.pauseActivation, .pauseActivation, .pause, evaluationID(214)),
        ]

        for testCase in cases {
            EvaluationLog.shared.reset()
            let journal = RecordingEvaluationJournal()
            let automatic = SpyAutoActivities()
            let guardSpy = SpyBackgroundTaskGuard()
            let sut = makeOrchestrator(
                prefs: activePreferences(),
                checkRepository: repository(),
                autoActivities: automatic,
                evaluationJournal: journal,
                makeEvaluationID: { testCase.id },
                backgroundTaskGuard: guardSpy
            )

            let completion = await sut.runOnce(testCase.trigger)

            await assertSingleTerminal(
                journal,
                completion: completion,
                expectedID: testCase.id,
                outcome: .staleContext,
                stage: testCase.stage,
                trigger: testCase.journalTrigger
            )
            XCTAssertEqual(automatic.callCount, 0)
            XCTAssertEqual(guardSpy.beginCount, 0)
            XCTAssertTrue(guardSpy.endTokens.isEmpty)
            XCTAssertTrue(EvaluationLog.shared.isEmpty())
        }
    }

    func test_contextInvalidatedDuringReloginFinishesStaleWithoutRetryingDependency() async {
        let id = evaluationID(215)
        let journal = RecordingEvaluationJournal()
        let preferences = activePreferences()
        let repository = ScriptedOptionsRepository(
            optionResults: [.failure(.unauthorized)],
            state: state(.checkOut, at: now.addingTimeInterval(-60))
        )
        let automatic = SpyAutoActivities()
        let auth = SpyAuthRepository()
        let loginStarted = AsyncGate()
        let loginGate = AsyncGate()
        auth.loginStartedGate = loginStarted
        auth.loginGate = loginGate
        auth.result = .success(AuthStatus(
            found: true,
            chave: "HR70",
            hasPassword: true,
            authenticated: true,
            message: "ok"
        ))
        let guardSpy = SpyBackgroundTaskGuard()
        let sut = makeOrchestrator(
            prefs: preferences,
            checkRepository: repository,
            autoActivities: automatic,
            authRepository: auth,
            securePasswordStore: NoopSecurePasswordStore(password: "password-sentinel"),
            evaluationJournal: journal,
            makeEvaluationID: { id },
            backgroundTaskGuard: guardSpy
        )

        let evaluation = Task { await sut.runOnce(.geofence) }
        await loginStarted.wait()
        let transition = await sut.beginAutomationContextTransition()
        await loginGate.release()
        await sut.awaitAutomationQuiescence(transition)
        await sut.endAutomationContextTransition(transition)
        let completion = await evaluation.value

        await assertSingleTerminal(
            journal,
            completion: completion,
            expectedID: id,
            outcome: .staleContext,
            stage: .options,
            trigger: .geofence
        )
        XCTAssertEqual(repository.getLocationsCallCount, 1)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(automatic.callCount, 0)
        XCTAssertEqual(guardSpy.endTokens, [17])
    }

    func test_stateNetworkFailurePreservesSingleEngineCallAndOneTerminal() async {
        let id = evaluationID(220)
        let journal = RecordingEvaluationJournal()
        let repository = repository()
        repository.getStateResult = .failure(.network)
        let automatic = SpyAutoActivities()
        automatic.result = .noAction
        let guardSpy = SpyBackgroundTaskGuard()
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            checkRepository: repository,
            autoActivities: automatic,
            clock: FixedClock(now),
            evaluationJournal: journal,
            makeEvaluationID: { id },
            backgroundTaskGuard: guardSpy
        )

        let completion = await sut.runOnce(.geofence)

        await assertSingleTerminal(
            journal,
            completion: completion,
            expectedID: id,
            outcome: .noAction,
            stage: .decision,
            trigger: .geofence
        )
        XCTAssertEqual(repository.getStateCallCount, 1)
        XCTAssertEqual(automatic.callCount, 1)
        XCTAssertNil(automatic.calls.first?.currentState)
        XCTAssertEqual(EvaluationLog.shared.snapshot().map(\.outcome), [.noAction])
        XCTAssertEqual(guardSpy.endTokens, [17])
    }

    func test_typedContextCancellationAndBackgroundExpirationFinishOnce() async {
        let cases: [
            (
                name: String,
                reason: EvaluationCancellationReason,
                outcome: EvaluationTerminalOutcome,
                completedBeforeExpiration: Bool,
                id: EvaluationID
            )
        ] = [
            (
                "context invalidated",
                .contextInvalidated,
                .staleContext,
                true,
                evaluationID(230)
            ),
            (
                "BG task expired",
                .bgTaskExpired,
                .expired,
                false,
                evaluationID(231)
            ),
        ]

        for testCase in cases {
            EvaluationLog.shared.reset()
            let journal = RecordingEvaluationJournal()
            let automatic = SpyAutoActivities()
            automatic.execution = automaticExecution(
                result: .noAction,
                stage: .matched,
                failure: .cancelled(testCase.reason)
            )
            let guardSpy = SpyBackgroundTaskGuard()
            let sut = makeOrchestrator(
                prefs: activePreferences(),
                checkRepository: repository(),
                autoActivities: automatic,
                clock: FixedClock(now),
                evaluationJournal: journal,
                makeEvaluationID: { testCase.id },
                backgroundTaskGuard: guardSpy
            )

            let completion = await sut.runOnce(.geofence)

            await assertSingleTerminal(
                journal,
                completion: completion,
                expectedID: testCase.id,
                outcome: testCase.outcome,
                stage: .match,
                trigger: .geofence,
                completedBeforeExpiration: testCase.completedBeforeExpiration
            )
            XCTAssertEqual(automatic.callCount, 1, testCase.name)
            XCTAssertEqual(EvaluationLog.shared.snapshot().map(\.outcome), [.noAction])
            XCTAssertEqual(guardSpy.endTokens, [17], testCase.name)
        }
    }

    func test_submittedNotificationAndCaptureTraceAreSanitizedInTerminal() async {
        let id = evaluationID(240)
        let localSentinel = "NOTIFICATION_LOCAL_SENTINEL"
        let journal = RecordingEvaluationJournal()
        let automatic = SpyAutoActivities()
        automatic.execution = automaticExecution(
            result: .submitted(
                action: .checkIn,
                local: localSentinel,
                newState: state(.checkIn, at: now)
            ),
            stage: .submitted,
            capture: AutomaticCaptureTrace(
                source: .bestPartial,
                physicalSource: .significantChange,
                reused: true,
                quality: .coarse
            )
        )
        let notifications = SpyNotifications()
        let guardSpy = SpyBackgroundTaskGuard()
        let sut = makeOrchestrator(
            prefs: activePreferences(notifyActivities: true),
            checkRepository: repository(),
            autoActivities: automatic,
            notifications: notifications,
            clock: FixedClock(now),
            evaluationJournal: journal,
            makeEvaluationID: { id },
            backgroundTaskGuard: guardSpy
        )

        let completion = await sut.runOnce(.significantLocation)

        await assertSingleTerminal(
            journal,
            completion: completion,
            expectedID: id,
            outcome: .submittedCheckIn,
            stage: .notification,
            trigger: .significantLocation
        )
        let snapshot = await journal.snapshot()
        let terminal = try? XCTUnwrap(snapshot.finishes.first?.terminal)
        XCTAssertEqual(terminal?.locationSource, .bestPartial)
        XCTAssertEqual(terminal?.captureReused, true)
        XCTAssertNil(terminal?.notificationScheduled)
        XCTAssertEqual(notifications.activityPosts.count, 1)
        XCTAssertEqual(notifications.activityPosts.first?.action, .checkIn)
        XCTAssertEqual(notifications.activityPosts.first?.local, localSentinel)
        XCTAssertFalse(String(reflecting: terminal).contains(localSentinel))
        XCTAssertEqual(guardSpy.endTokens, [17])
    }

    func test_generationInvalidatedDuringAwaitFinishesStaleContextWithoutEngineEffect() async {
        let id = evaluationID(250)
        let journal = RecordingEvaluationJournal()
        let chaveGate = AsyncGate()
        let preferences = activePreferences()
        preferences.chaveGate = chaveGate
        let automatic = SpyAutoActivities()
        let guardSpy = SpyBackgroundTaskGuard()
        let sut = makeOrchestrator(
            prefs: preferences,
            checkRepository: repository(),
            autoActivities: automatic,
            evaluationJournal: journal,
            makeEvaluationID: { id },
            backgroundTaskGuard: guardSpy
        )

        let evaluation = Task { await sut.runOnce(.geofence) }
        await waitFor {
            let snapshot = await journal.snapshot()
            return snapshot.begins.count == 1
                && guardSpy.beginCount == 1
                && preferences.chaveReadStarted
        }
        await sut.invalidateAutomationContext()
        await chaveGate.release()
        let completion = await evaluation.value

        await assertSingleTerminal(
            journal,
            completion: completion,
            expectedID: id,
            outcome: .staleContext,
            stage: .settings,
            trigger: .geofence
        )
        XCTAssertEqual(automatic.callCount, 0)
        XCTAssertTrue(EvaluationLog.shared.isEmpty())
        XCTAssertEqual(guardSpy.endTokens, [17])
    }

    func test_legacyProfile_secondConcurrentWakeKeepsHistoricalDropWithoutJournalCommands() async {
        let firstID = evaluationID(5)
        let secondID = evaluationID(6)
        let ids = EvaluationIDFactory([firstID, secondID])
        let journal = RecordingEvaluationJournal()
        let guardSpy = SpyBackgroundTaskGuard()
        let chaveGate = AsyncGate()
        let preferences = FakeAppPreferences()
        preferences.chaveGate = chaveGate
        let automatic = SpyAutoActivities()
        let sut = makeOrchestrator(
            prefs: preferences,
            autoActivities: automatic,
            automaticEvaluationPipeline: .legacy,
            evaluationJournal: journal,
            makeEvaluationID: { ids.next() },
            backgroundTaskGuard: guardSpy
        )

        let firstTask = Task { await sut.runOnce(.timer) }
        await waitFor {
            let snapshot = await journal.snapshot()
            return snapshot.begins.count == 1 && guardSpy.beginCount == 1
        }

        let dropped = await sut.runOnce(.geofence)
        let whileBlocked = await journal.snapshot()

        XCTAssertFalse(dropped.admitted)
        XCTAssertEqual(dropped.outcome, .notAdmitted)
        XCTAssertEqual(dropped.evaluationID, secondID)
        XCTAssertEqual(whileBlocked.begins.count, 1)
        XCTAssertTrue(whileBlocked.finishes.isEmpty)
        XCTAssertTrue(whileBlocked.coalescences.isEmpty)
        XCTAssertEqual(guardSpy.beginCount, 1)

        await chaveGate.release()
        let first = await firstTask.value

        await assertSingleTerminal(
            journal,
            completion: first,
            expectedID: firstID,
            outcome: .noKey,
            stage: .settings,
            trigger: .timer
        )
        XCTAssertEqual(ids.callCount, 2)
        XCTAssertEqual(automatic.callCount, 0)
        XCTAssertEqual(guardSpy.beginCount, 1)
        XCTAssertEqual(guardSpy.endTokens, [17])
    }

    func test_cancellingOneWaiterDoesNotCancelSharedAdmittedEvaluation() async {
        let id = evaluationID(7)
        let journal = RecordingEvaluationJournal()
        let guardSpy = SpyBackgroundTaskGuard()
        let chaveGate = AsyncGate()
        let preferences = activePreferences()
        preferences.chaveGate = chaveGate
        let automatic = SpyAutoActivities()
        let sut = makeOrchestrator(
            prefs: preferences,
            autoActivities: automatic,
            evaluationJournal: journal,
            makeEvaluationID: { id },
            backgroundTaskGuard: guardSpy
        )

        let task = Task { await sut.runOnce(.geofence) }
        await waitFor {
            let snapshot = await journal.snapshot()
            return snapshot.begins.count == 1
                && guardSpy.beginCount == 1
                && preferences.chaveReadStarted
        }
        task.cancel()
        await chaveGate.release()
        let completion = await task.value

        await assertSingleTerminal(
            journal,
            completion: completion,
            expectedID: id,
            outcome: .noAction,
            stage: .decision,
            trigger: .geofence
        )
        XCTAssertEqual(automatic.callCount, 1)
        XCTAssertEqual(guardSpy.beginCount, 1)
        XCTAssertEqual(guardSpy.endTokens, [17])
    }

    func test_genericTaskCancellationDoesNotOverwriteTypedBackgroundExpiration() async {
        let id = evaluationID(70)
        let journal = RecordingEvaluationJournal()
        let executionGate = AsyncGate()
        let automatic = GatedAutomaticActivities(
            gate: executionGate,
            execution: automaticExecution(
                result: .noAction,
                stage: .matched,
                failure: .cancelled(.bgTaskExpired)
            )
        )
        let guardSpy = SpyBackgroundTaskGuard()
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            checkRepository: repository(),
            autoActivities: automatic,
            evaluationJournal: journal,
            makeEvaluationID: { id },
            backgroundTaskGuard: guardSpy
        )

        let task = Task { await sut.runOnce(.geofence) }
        await waitFor {
            await automatic.callCount() == 1
        }
        task.cancel()
        await executionGate.release()
        let completion = await task.value

        await assertSingleTerminal(
            journal,
            completion: completion,
            expectedID: id,
            outcome: .expired,
            stage: .match,
            trigger: .geofence,
            completedBeforeExpiration: false
        )
        let automaticCallCount = await automatic.callCount()
        XCTAssertEqual(automaticCallCount, 1)
        XCTAssertEqual(guardSpy.endTokens, [17])
    }

    func test_irreversibleAndTypedTerminalsWinOverLaterStaleOrCancellationSignals() async {
        let submittedState = state(.checkIn, at: now)
        let cases: [
            (
                name: String,
                execution: AutomaticActivitiesExecution,
                invalidateGeneration: Bool,
                cancelTask: Bool,
                outcome: EvaluationTerminalOutcome,
                stage: EvaluationStage,
                legacyOutcome: EvaluationOutcome?,
                id: EvaluationID
            )
        ] = [
            (
                "submitted wins over generic cancellation",
                automaticExecution(
                    result: .submitted(
                        action: .checkIn,
                        local: "Unidade P80",
                        newState: submittedState
                    ),
                    stage: .submitted
                ),
                false,
                true,
                .submittedCheckIn,
                .submit,
                .submitted,
                evaluationID(260)
            ),
            (
                "raw queue wins over generic cancellation",
                automaticExecution(
                    result: .networkError,
                    stage: .matched,
                    failure: .match(.network),
                    offlineDisposition: .queuedRaw
                ),
                false,
                true,
                .queuedOfflineRaw,
                .match,
                .networkError,
                evaluationID(261)
            ),
            (
                "decided queue wins over stale generation",
                automaticExecution(
                    result: .networkError,
                    stage: .submitStarted,
                    failure: .submit(.network),
                    offlineDisposition: .queuedDecided
                ),
                true,
                false,
                .queuedOfflineDecided,
                .submit,
                .networkError,
                evaluationID(262)
            ),
            (
                "typed expiration wins over stale generation",
                automaticExecution(
                    result: .noAction,
                    stage: .matched,
                    failure: .cancelled(.bgTaskExpired)
                ),
                true,
                false,
                .expired,
                .match,
                nil,
                evaluationID(263)
            ),
            (
                "typed stale context wins over generic cancellation",
                automaticExecution(
                    result: .noAction,
                    stage: .matched,
                    failure: .cancelled(.contextInvalidated)
                ),
                false,
                true,
                .staleContext,
                .match,
                .noAction,
                evaluationID(264)
            ),
        ]

        for testCase in cases {
            EvaluationLog.shared.reset()
            let journal = RecordingEvaluationJournal()
            let executionGate = AsyncGate()
            let automatic = GatedAutomaticActivities(
                gate: executionGate,
                execution: testCase.execution
            )
            let guardSpy = SpyBackgroundTaskGuard()
            let sut = makeOrchestrator(
                prefs: activePreferences(),
                checkRepository: repository(),
                autoActivities: automatic,
                evaluationJournal: journal,
                makeEvaluationID: { testCase.id },
                backgroundTaskGuard: guardSpy
            )

            let task = Task { await sut.runOnce(.geofence) }
            await waitFor {
                await automatic.callCount() == 1
            }
            if testCase.invalidateGeneration {
                await sut.invalidateAutomationContext()
            }
            if testCase.cancelTask {
                task.cancel()
            }
            await executionGate.release()
            let completion = await task.value

            await assertSingleTerminal(
                journal,
                completion: completion,
                expectedID: testCase.id,
                outcome: testCase.outcome,
                stage: testCase.stage,
                trigger: .geofence,
                completedBeforeExpiration: testCase.outcome != .expired
            )
            let legacyOutcomes = EvaluationLog.shared.snapshot().map(\.outcome)
            if let legacyOutcome = testCase.legacyOutcome {
                XCTAssertEqual(legacyOutcomes, [legacyOutcome], testCase.name)
            } else {
                XCTAssertTrue(legacyOutcomes.isEmpty, testCase.name)
            }
            let callCount = await automatic.callCount()
            XCTAssertEqual(callCount, 1, testCase.name)
            XCTAssertEqual(guardSpy.endTokens, [17], testCase.name)
        }
    }

    func test_timerSecondIdenticalFixSkipsWithOneTerminalPerAdmittedEvaluation() async {
        let firstID = evaluationID(8)
        let secondID = evaluationID(9)
        let ids = EvaluationIDFactory([firstID, secondID])
        let journal = RecordingEvaluationJournal()
        let guardSpy = SpyBackgroundTaskGuard()
        let automatic = SpyAutoActivities()
        automatic.result = .noAction
        let sample = ucLocationSample(
            lat: 1.301,
            lon: 103.812,
            accuracyMeters: 5,
            capturedAt: now
        )
        let provider = FakeLocationProvider(.success(sample))
        let dao = CapturingDao()
        let logger = ActivityLogger(
            clock: FixedClock(now),
            activityLog: ActivityLog(dao: dao),
            scheduler: InlineLogScheduler()
        )
        let sut = makeOrchestrator(
            prefs: activePreferences(),
            checkRepository: repository(),
            autoActivities: automatic,
            locationProvider: provider,
            clock: FixedClock(now),
            evaluationJournal: journal,
            makeEvaluationID: { ids.next() },
            backgroundTaskGuard: guardSpy,
            activityLogger: logger
        )

        let first = await sut.runOnce(.timer)
        let second = await sut.runOnce(.timer)

        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.begins.map(\.id), [firstID, secondID])
        XCTAssertEqual(snapshot.finishes.map(\.id), [firstID, secondID])
        XCTAssertEqual(snapshot.finishes.map(\.terminal.outcome), [.noAction, .skippedNoMovement])
        XCTAssertEqual(snapshot.finishes.map(\.terminal.stage), [.decision, .movement])
        XCTAssertEqual(first.outcome, .noAction)
        XCTAssertEqual(second.outcome, .skippedNoMovement)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(automatic.callCount, 1)
        XCTAssertEqual(guardSpy.beginCount, 2)
        XCTAssertEqual(guardSpy.endTokens, [17, 17])
        XCTAssertEqual(
            EvaluationLog.shared.snapshot().map(\.outcome),
            [.skip, .noAction]
        )
        XCTAssertEqual(
            dao.rows.last?.description,
            "Auto-check skipped (no movement)."
        )
    }

    func test_noopAndUnavailableJournalNeverChangeBusinessCompletion() async {
        let expected = automaticExecution(
            result: .noAction,
            stage: .decisionCompleted
        )

        do {
            let id = evaluationID(10)
            let automatic = SpyAutoActivities()
            automatic.execution = expected
            let guardSpy = SpyBackgroundTaskGuard()
            let sut = makeOrchestrator(
                prefs: activePreferences(),
                checkRepository: repository(),
                autoActivities: automatic,
                evaluationJournal: NoopEvaluationJournal(),
                makeEvaluationID: { id },
                backgroundTaskGuard: guardSpy
            )

            let completion = await sut.runOnce(.geofence)

            XCTAssertEqual(
                completion,
                EvaluationCompletion(
                    evaluationID: id,
                    outcome: .noAction,
                    completedBeforeExpiration: true
                )
            )
            XCTAssertEqual(automatic.callCount, 1)
            XCTAssertEqual(guardSpy.endTokens, [17])
        }

        do {
            let id = evaluationID(11)
            let unavailable = UnavailableEvaluationJournal()
            let automatic = SpyAutoActivities()
            automatic.execution = expected
            let guardSpy = SpyBackgroundTaskGuard()
            let sut = makeOrchestrator(
                prefs: activePreferences(),
                checkRepository: repository(),
                autoActivities: automatic,
                evaluationJournal: unavailable,
                makeEvaluationID: { id },
                backgroundTaskGuard: guardSpy
            )

            let completion = await sut.runOnce(.geofence)
            let attempts = await unavailable.attempts()
            let recent = await unavailable.recent(limit: 10)

            XCTAssertEqual(
                completion,
                EvaluationCompletion(
                    evaluationID: id,
                    outcome: .noAction,
                    completedBeforeExpiration: true
                )
            )
            XCTAssertEqual(
                attempts,
                .init(begins: 1, coalescences: 0, finishes: 1)
            )
            XCTAssertTrue(recent.isEmpty)
            XCTAssertEqual(automatic.callCount, 1)
            XCTAssertEqual(guardSpy.endTokens, [17])
        }
    }

    func test_reloginSuccessAndFailureUseOneEvaluationAndOneTerminal() async {
        let authenticated = AuthStatus(
            found: true,
            chave: "HR70",
            hasPassword: true,
            authenticated: true,
            message: "ok"
        )
        let cases: [
            (
                name: String,
                authResult: AppResult<AuthStatus>,
                expectedOutcome: EvaluationTerminalOutcome,
                expectedStage: EvaluationStage,
                expectedAutomaticCalls: Int,
                expectedReauthNotifications: Int,
                id: EvaluationID
            )
        ] = [
            (
                "success",
                .success(authenticated),
                .noAction,
                .decision,
                1,
                0,
                evaluationID(12)
            ),
            (
                "failure",
                .failure(.network),
                .reloginFailed,
                .state,
                0,
                1,
                evaluationID(13)
            ),
        ]

        for testCase in cases {
            EvaluationLog.shared.reset()
            let journal = RecordingEvaluationJournal()
            let repository = repository()
            repository.queuedGetStateResults = [
                .failure(.unauthorized),
                .success(state(.checkOut, at: now.addingTimeInterval(-60))),
            ]
            let automatic = SpyAutoActivities()
            automatic.result = .noAction
            let auth = SpyAuthRepository()
            auth.result = testCase.authResult
            let notifications = SpyNotifications()
            let guardSpy = SpyBackgroundTaskGuard()
            let dao = CapturingDao()
            let logger = ActivityLogger(
                clock: FixedClock(now),
                activityLog: ActivityLog(dao: dao),
                scheduler: InlineLogScheduler()
            )
            let sut = makeOrchestrator(
                prefs: activePreferences(),
                checkRepository: repository,
                autoActivities: automatic,
                notifications: notifications,
                clock: FixedClock(now),
                authRepository: auth,
                securePasswordStore: NoopSecurePasswordStore(password: "password-sentinel"),
                evaluationJournal: journal,
                makeEvaluationID: { testCase.id },
                backgroundTaskGuard: guardSpy,
                activityLogger: logger
            )

            let completion = await sut.runOnce(.geofence)

            await assertSingleTerminal(
                journal,
                completion: completion,
                expectedID: testCase.id,
                outcome: testCase.expectedOutcome,
                stage: testCase.expectedStage,
                trigger: .geofence
            )
            XCTAssertEqual(auth.callCount, 1, testCase.name)
            XCTAssertEqual(automatic.callCount, testCase.expectedAutomaticCalls, testCase.name)
            XCTAssertEqual(
                notifications.reauthPosts.count,
                testCase.expectedReauthNotifications,
                testCase.name
            )
            XCTAssertEqual(guardSpy.beginCount, 1, testCase.name)
            XCTAssertEqual(guardSpy.endTokens, [17], testCase.name)
            if testCase.name == "success" {
                XCTAssertTrue(
                    dao.rows.contains { $0.description == "Session refreshed." }
                )
            } else {
                XCTAssertEqual(
                    dao.rows.last?.description,
                    "Re-authentication required."
                )
            }
        }
    }
}
