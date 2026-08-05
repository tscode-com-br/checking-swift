import Foundation
import XCTest
@testable import Checking

final class AutomaticActivitiesExecutionTests: XCTestCase {
    private final class EffectGuardSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool]
        private var reads = 0

        init(_ values: [Bool]) {
            precondition(!values.isEmpty)
            self.values = values
        }

        func next() -> Bool {
            lock.withLock {
                defer { reads += 1 }
                return values[min(reads, values.count - 1)]
            }
        }

        var readCount: Int { lock.withLock { reads } }
    }

    private final class ClientEventIDFactory: @unchecked Sendable {
        private let lock = NSLock()
        private let value: String
        private var calls = 0

        init(_ value: String) {
            self.value = value
        }

        func next() -> String {
            lock.withLock {
                calls += 1
                return value
            }
        }

        var callCount: Int {
            lock.withLock { calls }
        }
    }

    private final class MutableClock: Clock, @unchecked Sendable {
        private let lock = NSLock()
        private var instant: Date

        init(_ instant: Date) {
            self.instant = instant
        }

        func now() -> Date {
            lock.withLock { instant }
        }

        func advance(by interval: TimeInterval) {
            lock.withLock {
                instant = instant.addingTimeInterval(interval)
            }
        }
    }

    private let now = iso("2026-06-20T08:00:00Z")

    private var projects: UserProjects {
        UserProjects(projects: ["P80"], activeProject: "P80")
    }

    private var currentCheckoutState: HistoryState {
        ucHistory(
            .checkOut,
            currentLocal: "Unidade anterior",
            lastCheckoutAt: now.addingTimeInterval(-60)
        )
    }

    private var usableCaptureTrace: AutomaticCaptureTrace {
        AutomaticCaptureTrace(
            source: .freshCapture,
            physicalSource: .standardCapture,
            reused: false,
            quality: .usable
        )
    }

    private func matchedCapture(
        trace: AutomaticCaptureTrace? = nil
    ) -> LocationCaptureExecution {
        LocationCaptureExecution(
            result: .matched(ucMatch(.matched, "Unidade P80")),
            maximumStage: .matched,
            capture: trace ?? usableCaptureTrace,
            failure: nil
        )
    }

    private func makeUseCase(
        capture: FakeCaptureLocation,
        repository: FakeCheckRepository,
        queue: FakeOfflineQueue,
        ids: ClientEventIDFactory,
        logger: any ActivityLogging = NoopActivityLogger()
    ) -> RunAutomaticActivitiesUseCase {
        RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: FixedClock(now),
            activityLogger: logger,
            makeClientEventID: { ids.next() }
        )
    }

    private func expectedSubmission(
        chave: String,
        clientEventID: String
    ) -> AutomaticSubmissionContext {
        AutomaticSubmissionContext(
            chave: chave,
            projeto: "P80",
            action: .checkIn,
            local: "Unidade P80",
            informe: .normal,
            eventTime: now,
            clientEventId: clientEventID,
            fillForms: true
        )
    }

    func test_successPreservesExactContextStageAndCaptureWithoutExtraCalls() async {
        let trace = AutomaticCaptureTrace(
            source: .seed,
            physicalSource: .significantChange,
            reused: true,
            quality: .usable
        )
        let capture = FakeCaptureLocation(execution: matchedCapture(trace: trace))
        let repository = FakeCheckRepository()
        let queue = FakeOfflineQueue()
        let ids = ClientEventIDFactory("success-event-id")
        let newState = ucHistory(
            .checkIn,
            currentLocal: "Unidade P80",
            lastCheckinAt: now
        )
        repository.submitResult = .success(newState)
        let sut = makeUseCase(
            capture: capture,
            repository: repository,
            queue: queue,
            ids: ids
        )

        let execution = await sut.execute(
            chave: "STSM",
            userProjects: projects,
            currentState: currentCheckoutState,
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50
        )

        let submission = expectedSubmission(
            chave: "STSM",
            clientEventID: "success-event-id"
        )
        XCTAssertEqual(
            execution,
            AutomaticActivitiesExecution(
                result: .submitted(
                    action: .checkIn,
                    local: "Unidade P80",
                    newState: newState
                ),
                trace: AutomaticActivitiesTrace(
                    maximumStage: .submitted,
                    capture: trace,
                    failure: nil,
                    offlineDisposition: nil
                ),
                submissionContext: submission
            )
        )
        XCTAssertEqual(capture.callCount, 1)
        XCTAssertEqual(capture.thresholds, [50])
        XCTAssertEqual(capture.attempts, [.acquire])
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.submitCount, 1)
        XCTAssertEqual(
            repository.submitCalls,
            [
                .init(
                    chave: submission.chave,
                    projeto: submission.projeto,
                    action: submission.action,
                    local: submission.local,
                    informe: submission.informe,
                    eventTime: submission.eventTime,
                    clientEventId: submission.clientEventId,
                    fillForms: submission.fillForms
                ),
            ]
        )
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertEqual(ids.callCount, 1)
    }

    func test_acquisitionFailuresRemainTypedAndDoNotReachSubmitOrQueue() async {
        let cases: [
            (
                name: String,
                failure: LocationAcquisitionFailure,
                captureResult: LocationCaptureResult,
                businessResult: AutoActivitiesResult
            )
        ] = [
            ("timeout", .timeout, .timeout, .locationTimeout),
            ("unavailable", .unavailable, .noPermission, .noPermission),
            ("permission", .permissionDenied, .noPermission, .noPermission),
            (
                "cancelled",
                .cancelled(.bgTaskExpired),
                .timeout,
                .locationTimeout
            ),
        ]

        for testCase in cases {
            let capture = FakeCaptureLocation(
                execution: LocationCaptureExecution(
                    result: testCase.captureResult,
                    maximumStage: .captureStarted,
                    capture: nil,
                    failure: .acquisition(testCase.failure)
                )
            )
            let repository = FakeCheckRepository()
            let queue = FakeOfflineQueue()
            let ids = ClientEventIDFactory("must-not-be-used-\(testCase.name)")
            let sut = makeUseCase(
                capture: capture,
                repository: repository,
                queue: queue,
                ids: ids
            )

            let execution = await sut.execute(
                chave: "STSM",
                userProjects: projects,
                currentState: currentCheckoutState,
                mixedZoneIntervalMinutes: 15,
                accuracyThresholdMeters: 50
            )

            XCTAssertEqual(
                execution,
                AutomaticActivitiesExecution(
                    result: testCase.businessResult,
                    trace: AutomaticActivitiesTrace(
                        maximumStage: .captureStarted,
                        capture: nil,
                        failure: .acquisition(testCase.failure),
                        offlineDisposition: nil
                    ),
                    submissionContext: nil
                ),
                testCase.name
            )
            XCTAssertEqual(capture.callCount, 1, testCase.name)
            XCTAssertEqual(repository.matchLocationCallCount, 0, testCase.name)
            XCTAssertEqual(repository.submitCount, 0, testCase.name)
            XCTAssertTrue(queue.enqueued.isEmpty, testCase.name)
            XCTAssertEqual(ids.callCount, 0, testCase.name)
        }
    }

    func test_matchErrorTablePreservesApiErrorWithoutSubmitQueueOrRetry() async {
        let cases: [(name: String, error: ApiError)] = [
            ("unauthorized", .unauthorized),
            (
                "http-422",
                .http(status: 422, detail: "backend-unregistered-detail")
            ),
            ("other-4xx", .http(status: 400, detail: "bad-request-detail")),
            ("http-500", .http(status: 500, detail: "server-detail")),
            ("conflict", .conflict),
            ("unknown", .unknown(description: "external-error-description")),
        ]

        for testCase in cases {
            let trace = usableCaptureTrace
            let capture = FakeCaptureLocation(
                execution: LocationCaptureExecution(
                    result: .networkError(reading: nil),
                    maximumStage: .matched,
                    capture: trace,
                    failure: .match(testCase.error)
                )
            )
            let repository = FakeCheckRepository()
            let queue = FakeOfflineQueue()
            let ids = ClientEventIDFactory("must-not-be-used-\(testCase.name)")
            let sut = makeUseCase(
                capture: capture,
                repository: repository,
                queue: queue,
                ids: ids
            )

            let execution = await sut.execute(
                chave: "STSM",
                userProjects: projects,
                currentState: currentCheckoutState,
                mixedZoneIntervalMinutes: 15,
                accuracyThresholdMeters: 50
            )

            XCTAssertEqual(execution.result, .networkError, testCase.name)
            XCTAssertEqual(execution.trace.maximumStage, .matched, testCase.name)
            XCTAssertEqual(execution.trace.capture, trace, testCase.name)
            XCTAssertEqual(
                execution.trace.failure,
                .match(testCase.error),
                testCase.name
            )
            XCTAssertNil(execution.trace.offlineDisposition, testCase.name)
            XCTAssertNil(execution.submissionContext, testCase.name)
            XCTAssertEqual(capture.callCount, 1, testCase.name)
            XCTAssertEqual(repository.matchLocationCallCount, 0, testCase.name)
            XCTAssertEqual(repository.submitCount, 0, testCase.name)
            XCTAssertTrue(queue.enqueued.isEmpty, testCase.name)
            XCTAssertEqual(ids.callCount, 0, testCase.name)
        }
    }

    func test_matchNetworkFailureQueuesOneExactRawEventAndKeepsTypedCause() async {
        let reading = LocationReading(
            lat: 1.301_234,
            lon: 103.812_345,
            accuracyMeters: 512
        )
        let trace = AutomaticCaptureTrace(
            source: .bestPartial,
            physicalSource: .significantChange,
            reused: false,
            quality: .coarse
        )
        let capture = FakeCaptureLocation(
            execution: LocationCaptureExecution(
                result: .networkError(reading: reading),
                maximumStage: .matched,
                capture: trace,
                failure: .match(.network)
            )
        )
        let repository = FakeCheckRepository()
        let queue = FakeOfflineQueue()
        let ids = ClientEventIDFactory("raw-event-id")
        let sut = makeUseCase(
            capture: capture,
            repository: repository,
            queue: queue,
            ids: ids
        )

        let execution = await sut.execute(
            chave: "HR70",
            userProjects: projects,
            currentState: currentCheckoutState,
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 75
        )

        XCTAssertEqual(
            execution,
            AutomaticActivitiesExecution(
                result: .networkError,
                trace: AutomaticActivitiesTrace(
                    maximumStage: .matched,
                    capture: trace,
                    failure: .match(.network),
                    offlineDisposition: .queuedRaw
                ),
                submissionContext: nil
            )
        )
        XCTAssertEqual(
            queue.enqueued,
            [
                .raw(
                    .init(
                        chave: "HR70",
                        projeto: "P80",
                        capturedAtEpochMs: 1_781_942_400_000,
                        clientEventId: "raw-event-id",
                        latitude: reading.lat,
                        longitude: reading.lon,
                        accuracyMeters: reading.accuracyMeters
                    )
                ),
            ]
        )
        XCTAssertEqual(capture.callCount, 1)
        XCTAssertEqual(capture.thresholds, [75])
        XCTAssertEqual(capture.attempts, [.acquire])
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertEqual(ids.callCount, 1)
    }

    func test_contextInvalidatedImmediatelyBeforeRawEnqueueDoesNotPersistEvent() async {
        let capture = FakeCaptureLocation(
            execution: LocationCaptureExecution(
                result: .networkError(reading: LocationReading(
                    lat: 1.301_234,
                    lon: 103.812_345,
                    accuracyMeters: 12
                )),
                maximumStage: .matched,
                capture: usableCaptureTrace,
                failure: .match(.network)
            )
        )
        let repository = FakeCheckRepository()
        let queue = FakeOfflineQueue()
        let ids = ClientEventIDFactory("discarded-raw-event-id")
        let sut = makeUseCase(
            capture: capture,
            repository: repository,
            queue: queue,
            ids: ids
        )

        let execution = await sut.execute(
            chave: "HR70",
            userProjects: projects,
            currentState: currentCheckoutState,
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50,
            locationAttempt: .acquire,
            effectGuard: AutomaticActivitiesEffectGuard(
                operationIsCurrent: { false }
            )
        )

        XCTAssertEqual(execution.result, .locationTimeout)
        XCTAssertEqual(execution.trace.failure, .cancelled(.contextInvalidated))
        XCTAssertNil(execution.trace.offlineDisposition)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
    }

    func test_contextInvalidatedImmediatelyBeforeSubmitDoesNotDispatchOrEnqueue() async {
        let capture = FakeCaptureLocation(execution: matchedCapture())
        let repository = FakeCheckRepository()
        let queue = FakeOfflineQueue()
        let ids = ClientEventIDFactory("discarded-submit-event-id")
        let sut = makeUseCase(
            capture: capture,
            repository: repository,
            queue: queue,
            ids: ids
        )

        let execution = await sut.execute(
            chave: "HR70",
            userProjects: projects,
            currentState: currentCheckoutState,
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50,
            locationAttempt: .acquire,
            effectGuard: AutomaticActivitiesEffectGuard(
                operationIsCurrent: { false }
            )
        )

        XCTAssertEqual(execution.result, .locationTimeout)
        XCTAssertEqual(execution.trace.maximumStage, .decisionCompleted)
        XCTAssertEqual(execution.trace.failure, .cancelled(.contextInvalidated))
        XCTAssertNotNil(execution.submissionContext)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
    }

    func test_successResponseAfterContextInvalidationPreservesConfirmedOutcomeWithoutLogsOrQueue() async {
        let capture = FakeCaptureLocation(execution: matchedCapture())
        let repository = FakeCheckRepository()
        repository.submitResult = .success(currentCheckoutState)
        let queue = FakeOfflineQueue()
        let ids = ClientEventIDFactory("stale-success-event-id")
        // pre-submit + dispatch commit are current; only the response-side fence is revoked.
        let validity = EffectGuardSequence([true, true, false])
        let dao = CapturingDao()
        let logger = ActivityLogger(
            clock: FixedClock(now),
            activityLog: ActivityLog(dao: dao),
            scheduler: InlineLogScheduler()
        )
        let sut = makeUseCase(
            capture: capture,
            repository: repository,
            queue: queue,
            ids: ids,
            logger: logger
        )

        let execution = await sut.execute(
            chave: "HR70",
            userProjects: projects,
            currentState: currentCheckoutState,
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50,
            locationAttempt: .acquire,
            effectGuard: AutomaticActivitiesEffectGuard(
                operationIsCurrent: { validity.next() }
            )
        )

        XCTAssertEqual(execution.result, .submitted(
            action: .checkIn,
            local: "Unidade P80",
            newState: currentCheckoutState
        ))
        XCTAssertEqual(execution.trace.maximumStage, .submitted)
        XCTAssertNil(execution.trace.failure)
        XCTAssertEqual(execution.submissionContext?.clientEventId, "stale-success-event-id")
        XCTAssertEqual(execution.submissionContext?.eventTime, now)
        XCTAssertEqual(repository.submitCount, 1)
        XCTAssertEqual(
            repository.submitCalls,
            [
                .init(
                    chave: "HR70",
                    projeto: "P80",
                    action: .checkIn,
                    local: "Unidade P80",
                    informe: .normal,
                    eventTime: now,
                    clientEventId: "stale-success-event-id",
                    fillForms: true
                ),
            ]
        )
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertTrue(dao.rows.isEmpty, "efeitos locais da identidade invalidada devem ser suprimidos")
        XCTAssertEqual(validity.readCount, 3)
    }

    func test_successResponseAfterTaskCancellationPreservesConfirmedOutcomeWithoutLogsOrQueue() async {
        let capture = FakeCaptureLocation(execution: matchedCapture())
        let repository = FakeCheckRepository()
        repository.submitResult = .success(currentCheckoutState)
        let submitGate = AsyncGate()
        repository.submitGate = submitGate
        let queue = FakeOfflineQueue()
        let ids = ClientEventIDFactory("cancelled-success-event-id")
        let dao = CapturingDao()
        let logger = ActivityLogger(
            clock: FixedClock(now),
            activityLog: ActivityLog(dao: dao),
            scheduler: InlineLogScheduler()
        )
        let sut = makeUseCase(
            capture: capture,
            repository: repository,
            queue: queue,
            ids: ids,
            logger: logger
        )
        let taskProjects = projects
        let taskState = currentCheckoutState

        let task = Task {
            await sut.execute(
                chave: "HR70",
                userProjects: taskProjects,
                currentState: taskState,
                mixedZoneIntervalMinutes: 15,
                accuracyThresholdMeters: 50
            )
        }
        await waitUntil { repository.submitCount == 1 }
        XCTAssertEqual(repository.submitCount, 1)

        task.cancel()
        await submitGate.release()
        let execution = await task.value

        XCTAssertEqual(execution.result, .submitted(
            action: .checkIn,
            local: "Unidade P80",
            newState: currentCheckoutState
        ))
        XCTAssertEqual(execution.trace.maximumStage, .submitted)
        XCTAssertNil(execution.trace.failure)
        XCTAssertEqual(execution.submissionContext?.clientEventId, "cancelled-success-event-id")
        XCTAssertEqual(execution.submissionContext?.eventTime, now)
        XCTAssertEqual(
            repository.submitCalls,
            [
                .init(
                    chave: "HR70",
                    projeto: "P80",
                    action: .checkIn,
                    local: "Unidade P80",
                    informe: .normal,
                    eventTime: now,
                    clientEventId: "cancelled-success-event-id",
                    fillForms: true
                ),
            ]
        )
        XCTAssertEqual(ids.callCount, 1)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertTrue(dao.rows.isEmpty, "cancelamento tardio deve suprimir somente os efeitos locais")
    }

    func test_networkResponseAfterContextInvalidationIsDiscardedWithoutDecidedEnqueue() async {
        let capture = FakeCaptureLocation(execution: matchedCapture())
        let repository = FakeCheckRepository()
        repository.submitResult = .failure(.network)
        let queue = FakeOfflineQueue()
        let ids = ClientEventIDFactory("stale-network-event-id")
        // pre-submit + dispatch commit are current; only the response-side fence is revoked.
        let validity = EffectGuardSequence([true, true, false])
        let sut = makeUseCase(
            capture: capture,
            repository: repository,
            queue: queue,
            ids: ids
        )

        let execution = await sut.execute(
            chave: "HR70",
            userProjects: projects,
            currentState: currentCheckoutState,
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50,
            locationAttempt: .acquire,
            effectGuard: AutomaticActivitiesEffectGuard(
                operationIsCurrent: { validity.next() }
            )
        )

        XCTAssertEqual(execution.result, .locationTimeout)
        XCTAssertEqual(execution.trace.maximumStage, .submitStarted)
        XCTAssertEqual(execution.trace.failure, .cancelled(.contextInvalidated))
        XCTAssertNil(execution.trace.offlineDisposition)
        XCTAssertEqual(repository.submitCount, 1)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertEqual(validity.readCount, 3)
    }

    func test_networkResponseAfterTaskCancellationIsStaleAndNeverEnqueuesDecidedEvent() async {
        let capture = FakeCaptureLocation(execution: matchedCapture())
        let repository = FakeCheckRepository()
        repository.submitResult = .failure(.network)
        let submitGate = AsyncGate()
        repository.submitGate = submitGate
        let queue = FakeOfflineQueue()
        let ids = ClientEventIDFactory("cancelled-network-event-id")
        let dao = CapturingDao()
        let logger = ActivityLogger(
            clock: FixedClock(now),
            activityLog: ActivityLog(dao: dao),
            scheduler: InlineLogScheduler()
        )
        let sut = makeUseCase(
            capture: capture,
            repository: repository,
            queue: queue,
            ids: ids,
            logger: logger
        )
        let taskProjects = projects
        let taskState = currentCheckoutState

        let task = Task {
            await sut.execute(
                chave: "HR70",
                userProjects: taskProjects,
                currentState: taskState,
                mixedZoneIntervalMinutes: 15,
                accuracyThresholdMeters: 50
            )
        }
        await waitUntil { repository.submitCount == 1 }
        XCTAssertEqual(repository.submitCount, 1)

        task.cancel()
        await submitGate.release()
        let execution = await task.value

        XCTAssertEqual(execution.result, .locationTimeout)
        XCTAssertEqual(execution.trace.maximumStage, .submitStarted)
        XCTAssertEqual(execution.trace.failure, .cancelled(.taskCancelled))
        XCTAssertNil(execution.trace.offlineDisposition)
        XCTAssertEqual(execution.submissionContext?.clientEventId, "cancelled-network-event-id")
        XCTAssertEqual(execution.submissionContext?.eventTime, now)
        XCTAssertEqual(
            repository.submitCalls,
            [
                .init(
                    chave: "HR70",
                    projeto: "P80",
                    action: .checkIn,
                    local: "Unidade P80",
                    informe: .normal,
                    eventTime: now,
                    clientEventId: "cancelled-network-event-id",
                    fillForms: true
                ),
            ]
        )
        XCTAssertEqual(ids.callCount, 1)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertTrue(dao.rows.isEmpty, "falha stale não deve produzir linha de fila/log")
    }

    func test_submitErrorTablePreservesContextAndApiErrorWithoutOfflineEnqueue() async {
        let cases: [(name: String, error: ApiError)] = [
            ("unauthorized", .unauthorized),
            (
                "http-422",
                .http(status: 422, detail: "unregistered-submit-detail")
            ),
            ("other-4xx", .http(status: 400, detail: "bad-submit-detail")),
            ("http-500", .http(status: 500, detail: "server-submit-detail")),
            ("conflict", .conflict),
            ("unknown", .unknown(description: "submit-error-description")),
        ]

        for testCase in cases {
            let capture = FakeCaptureLocation(execution: matchedCapture())
            let repository = FakeCheckRepository()
            repository.submitResult = .failure(testCase.error)
            let queue = FakeOfflineQueue()
            let eventID = "submit-\(testCase.name)-event-id"
            let ids = ClientEventIDFactory(eventID)
            let sut = makeUseCase(
                capture: capture,
                repository: repository,
                queue: queue,
                ids: ids
            )

            let execution = await sut.execute(
                chave: "STSM",
                userProjects: projects,
                currentState: currentCheckoutState,
                mixedZoneIntervalMinutes: 15,
                accuracyThresholdMeters: 50
            )

            let submission = expectedSubmission(
                chave: "STSM",
                clientEventID: eventID
            )
            XCTAssertEqual(execution.result, .networkError, testCase.name)
            XCTAssertEqual(execution.trace.maximumStage, .submitStarted, testCase.name)
            XCTAssertEqual(
                execution.trace.capture,
                usableCaptureTrace,
                testCase.name
            )
            XCTAssertEqual(
                execution.trace.failure,
                .submit(testCase.error),
                testCase.name
            )
            XCTAssertNil(execution.trace.offlineDisposition, testCase.name)
            XCTAssertEqual(
                execution.submissionContext,
                submission,
                testCase.name
            )
            XCTAssertEqual(capture.callCount, 1, testCase.name)
            XCTAssertEqual(repository.matchLocationCallCount, 0, testCase.name)
            XCTAssertEqual(repository.submitCount, 1, testCase.name)
            XCTAssertEqual(
                repository.submitCalls,
                [
                    .init(
                        chave: submission.chave,
                        projeto: submission.projeto,
                        action: submission.action,
                        local: submission.local,
                        informe: submission.informe,
                        eventTime: submission.eventTime,
                        clientEventId: submission.clientEventId,
                        fillForms: submission.fillForms
                    ),
                ],
                testCase.name
            )
            XCTAssertTrue(queue.enqueued.isEmpty, testCase.name)
            XCTAssertEqual(ids.callCount, 1, testCase.name)
        }
    }

    func test_submitNetworkFailureQueuesOneExactDecidedEventWithSameIdentityAndTime() async {
        let capture = FakeCaptureLocation(execution: matchedCapture())
        let repository = FakeCheckRepository()
        repository.submitResult = .failure(.network)
        let queue = FakeOfflineQueue()
        let ids = ClientEventIDFactory("decided-event-id")
        let sut = makeUseCase(
            capture: capture,
            repository: repository,
            queue: queue,
            ids: ids
        )

        let execution = await sut.execute(
            chave: "STSM",
            userProjects: projects,
            currentState: currentCheckoutState,
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50
        )

        let submission = expectedSubmission(
            chave: "STSM",
            clientEventID: "decided-event-id"
        )
        XCTAssertEqual(
            execution,
            AutomaticActivitiesExecution(
                result: .networkError,
                trace: AutomaticActivitiesTrace(
                    maximumStage: .submitStarted,
                    capture: usableCaptureTrace,
                    failure: .submit(.network),
                    offlineDisposition: .queuedDecided
                ),
                submissionContext: submission
            )
        )
        XCTAssertEqual(
            queue.enqueued,
            [
                .decided(
                    .init(
                        chave: submission.chave,
                        projeto: submission.projeto,
                        capturedAtEpochMs: 1_781_942_400_000,
                        clientEventId: submission.clientEventId,
                        action: "checkin",
                        local: submission.local,
                        informe: "normal"
                    )
                ),
            ]
        )
        XCTAssertEqual(capture.callCount, 1)
        XCTAssertEqual(capture.thresholds, [50])
        XCTAssertEqual(capture.attempts, [.acquire])
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.submitCount, 1)
        XCTAssertEqual(
            repository.submitCalls,
            [
                .init(
                    chave: submission.chave,
                    projeto: submission.projeto,
                    action: submission.action,
                    local: submission.local,
                    informe: submission.informe,
                    eventTime: submission.eventTime,
                    clientEventId: submission.clientEventId,
                    fillForms: submission.fillForms
                ),
            ]
        )
        XCTAssertEqual(ids.callCount, 1)
    }

    func test_contextInvalidatedAfterNetworkSubmitBeforeDecidedEnqueueDoesNotPersistEvent() async {
        let capture = FakeCaptureLocation(execution: matchedCapture())
        let repository = FakeCheckRepository()
        repository.submitResult = .failure(.network)
        let queue = FakeOfflineQueue()
        let ids = ClientEventIDFactory("discarded-decided-event-id")
        let validity = EffectGuardSequence([true, true, false])
        let sut = makeUseCase(
            capture: capture,
            repository: repository,
            queue: queue,
            ids: ids
        )

        let execution = await sut.execute(
            chave: "HR70",
            userProjects: projects,
            currentState: currentCheckoutState,
            mixedZoneIntervalMinutes: 15,
            accuracyThresholdMeters: 50,
            locationAttempt: .acquire,
            effectGuard: AutomaticActivitiesEffectGuard(
                operationIsCurrent: { validity.next() }
            )
        )

        XCTAssertEqual(execution.result, .locationTimeout)
        XCTAssertEqual(execution.trace.maximumStage, .submitStarted)
        XCTAssertEqual(execution.trace.failure, .cancelled(.contextInvalidated))
        XCTAssertNil(execution.trace.offlineDisposition)
        XCTAssertEqual(repository.submitCount, 1)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertEqual(validity.readCount, 3)
    }

    func test_phasedPreflightRejectsMissingProjectBeforeCaptureWithExactLegacyLog() {
        let capture = FakeCaptureLocation(.timeout)
        let repository = FakeCheckRepository()
        let queue = FakeOfflineQueue()
        let ids = ClientEventIDFactory("must-not-be-used")
        let dao = CapturingDao()
        let logger = ActivityLogger(
            clock: FixedClock(now),
            activityLog: ActivityLog(dao: dao),
            scheduler: InlineLogScheduler()
        )
        let sut = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: FixedClock(now),
            activityLogger: logger,
            makeClientEventID: { ids.next() }
        )

        let preflight = sut.preflight(
            chave: "STSM",
            userProjects: UserProjects(projects: [], activeProject: ""),
            mixedZoneIntervalMinutes: 15
        )

        guard case .terminal(let execution) = preflight else {
            return XCTFail("expected not-configured terminal")
        }
        XCTAssertEqual(execution.result, .notConfigured)
        XCTAssertEqual(execution.trace.maximumStage, .started)
        XCTAssertNil(execution.trace.capture)
        XCTAssertNil(execution.trace.failure)
        XCTAssertNil(execution.submissionContext)
        XCTAssertEqual(capture.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertEqual(ids.callCount, 0)
        XCTAssertEqual(
            dao.rows.map(\.description),
            ["No active project — skipped."]
        )
    }

    func test_phasedFinalSamplePreparesCoordinateFreeMatchThenCompletesWithoutRecapture() async {
        let latitudeSentinel = 1.234_567_891
        let longitudeSentinel = 103.987_654_321
        let finalSample = LocationSample(
            latitude: latitudeSentinel,
            longitude: longitudeSentinel,
            horizontalAccuracyMeters: 8,
            capturedAt: now,
            source: .standardCapture
        )
        let provider = FakeLocationProvider(.failure(.unavailable))
        let repository = FakeCheckRepository()
        repository.matchLocationResult = .success(
            ucMatch(.matched, "Unidade P80")
        )
        repository.submitResult = .success(
            ucHistory(
                .checkIn,
                currentLocal: "Unidade P80",
                lastCheckinAt: now
            )
        )
        let queue = FakeOfflineQueue()
        let capture = CaptureLocationUseCase(
            locationProvider: provider,
            checkRepository: repository,
            activityLogger: NoopActivityLogger(),
            clock: FixedClock(now),
            captureBehavior: .freshnessValidated
        )
        let ids = ClientEventIDFactory("phased-event-id")
        let concrete = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: FixedClock(now),
            activityLogger: NoopActivityLogger(),
            makeClientEventID: { ids.next() }
        )
        let sut: any PhasedRunningAutomaticActivities = concrete

        let preflight = sut.preflight(
            chave: "STSM",
            userProjects: projects,
            mixedZoneIntervalMinutes: 15
        )
        guard case .ready(let configuration) = preflight else {
            return XCTFail("expected configured preflight")
        }

        let preparation = await sut.prepare(
            configuration,
            accuracyThresholdMeters: 50,
            locationAttempt: .finalSample(finalSample)
        )

        guard case .ready(let prepared) = preparation else {
            return XCTFail("expected resolved match")
        }
        XCTAssertTrue(preparation.requiresCurrentState)
        XCTAssertTrue(prepared.requiresCurrentState)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(
            repository.lastMatchLocationCall,
            .init(
                latitude: finalSample.latitude,
                longitude: finalSample.longitude,
                accuracyMeters: finalSample.horizontalAccuracyMeters
            )
        )
        // `finalSample` reutiliza a captura física desta mesma avaliação; não é uma seed externa.
        XCTAssertEqual(prepared.capture?.source, .freshCapture)
        XCTAssertEqual(prepared.capture?.reused, true)
        XCTAssertEqual(prepared.capture?.accuracyBucket, .zeroTo10Meters)
        XCTAssertEqual(prepared.capture?.ageBucket, .under1Second)
        let preparedDescription = String(reflecting: prepared)
        XCTAssertFalse(
            preparedDescription.contains(String(latitudeSentinel)),
            "prepared match must not retain latitude"
        )
        XCTAssertFalse(
            preparedDescription.contains(String(longitudeSentinel)),
            "prepared match must not retain longitude"
        )
        XCTAssertFalse(preparedDescription.contains("LocationSample("))

        let execution = await sut.complete(
            prepared,
            currentState: currentCheckoutState
        )

        XCTAssertEqual(execution.result, .submitted(
            action: .checkIn,
            local: "Unidade P80",
            newState: repository.submitResult.value!
        ))
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.submitCount, 1)
        XCTAssertEqual(ids.callCount, 1)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertEqual(
            repository.submitCalls.first,
            .init(
                chave: "STSM",
                projeto: "P80",
                action: .checkIn,
                local: "Unidade P80",
                informe: .normal,
                eventTime: now,
                clientEventId: "phased-event-id",
                fillForms: true
            )
        )
    }

    func test_phasedUnauthorizedMatchRetriesOnlyMatchWithSameFreshSampleAndNoProviderOrSubmit() async {
        let finalSample = LocationSample(
            latitude: 1.234_567,
            longitude: 103.987_654,
            horizontalAccuracyMeters: 8,
            capturedAt: now,
            source: .standardCapture
        )
        let clock = MutableClock(now)
        let provider = FakeLocationProvider(.failure(.unavailable))
        let repository = FakeCheckRepository()
        repository.matchLocationResult = .failure(.unauthorized)
        let queue = FakeOfflineQueue()
        let capture = CaptureLocationUseCase(
            locationProvider: provider,
            checkRepository: repository,
            activityLogger: NoopActivityLogger(),
            clock: clock,
            captureBehavior: .freshnessValidated
        )
        let ids = ClientEventIDFactory("must-not-be-created-during-match-retry")
        let sut = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: clock,
            activityLogger: NoopActivityLogger(),
            makeClientEventID: { ids.next() }
        )
        guard case .ready(let configuration) = sut.preflight(
            chave: "STSM",
            userProjects: projects,
            mixedZoneIntervalMinutes: 15
        ) else {
            return XCTFail("expected configured preflight")
        }

        let firstPreparation = await sut.prepare(
            configuration,
            accuracyThresholdMeters: 50,
            locationAttempt: .finalSample(finalSample)
        )

        guard case .terminal(let firstExecution) = firstPreparation,
              let retryContext = firstPreparation.matchRetryContext else {
            return XCTFail("match unauthorized must expose an in-memory retry context")
        }
        XCTAssertEqual(firstExecution.result, .networkError)
        XCTAssertEqual(firstExecution.trace.failure, .match(.unauthorized))
        XCTAssertNil(firstExecution.submissionContext)
        XCTAssertEqual(retryContext.configuration, configuration)
        XCTAssertEqual(retryContext.accuracyThresholdMeters, 50)
        XCTAssertEqual(retryContext.sample, finalSample)
        XCTAssertEqual(retryContext.locationAttempt, .finalSample(finalSample))
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertEqual(ids.callCount, 0)

        repository.matchLocationResult = .success(ucMatch(.matched, "Unidade P80"))
        let retryPreparation = await sut.prepare(
            retryContext.configuration,
            accuracyThresholdMeters: retryContext.accuracyThresholdMeters,
            locationAttempt: retryContext.locationAttempt
        )

        guard case .ready = retryPreparation else {
            return XCTFail("fresh retry must resolve the matcher")
        }
        XCTAssertNil(retryPreparation.matchRetryContext)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 2)
        XCTAssertEqual(
            repository.lastMatchLocationCall,
            .init(
                latitude: finalSample.latitude,
                longitude: finalSample.longitude,
                accuracyMeters: finalSample.horizontalAccuracyMeters
            )
        )
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertEqual(ids.callCount, 0)
    }

    func test_phasedUnauthorizedMatchRetryRevalidatesSampleAndNeverReacquiresWhenItBecameStale() async {
        let finalSample = LocationSample(
            latitude: 1.234_567,
            longitude: 103.987_654,
            horizontalAccuracyMeters: 8,
            capturedAt: now,
            source: .standardCapture
        )
        let clock = MutableClock(now)
        let provider = FakeLocationProvider(.failure(.unavailable))
        let repository = FakeCheckRepository()
        repository.matchLocationResult = .failure(.unauthorized)
        let queue = FakeOfflineQueue()
        let capture = CaptureLocationUseCase(
            locationProvider: provider,
            checkRepository: repository,
            activityLogger: NoopActivityLogger(),
            clock: clock,
            captureBehavior: .freshnessValidated
        )
        let ids = ClientEventIDFactory("must-not-be-created-for-stale-match-retry")
        let sut = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: clock,
            activityLogger: NoopActivityLogger(),
            makeClientEventID: { ids.next() }
        )
        guard case .ready(let configuration) = sut.preflight(
            chave: "STSM",
            userProjects: projects,
            mixedZoneIntervalMinutes: 15
        ) else {
            return XCTFail("expected configured preflight")
        }
        let firstPreparation = await sut.prepare(
            configuration,
            accuracyThresholdMeters: 50,
            locationAttempt: .finalSample(finalSample)
        )
        guard let retryContext = firstPreparation.matchRetryContext else {
            return XCTFail("match unauthorized must expose an in-memory retry context")
        }

        clock.advance(by: LocationSamplePolicy.candidateTrial.maximumAge + 0.001)
        repository.matchLocationResult = .success(ucMatch(.matched, "must-not-be-used"))
        let retryPreparation = await sut.prepare(
            retryContext.configuration,
            accuracyThresholdMeters: retryContext.accuracyThresholdMeters,
            locationAttempt: retryContext.locationAttempt
        )

        guard case .terminal(let retryExecution) = retryPreparation else {
            return XCTFail("stale retry sample must terminate before the matcher")
        }
        XCTAssertEqual(retryExecution.result, .locationTimeout)
        XCTAssertEqual(retryExecution.trace.failure, .sampleRejected(.stale))
        XCTAssertNil(retryExecution.matchRetryContext)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 1)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertEqual(ids.callCount, 0)
    }

    func test_phasedPreparationDeclaresExactlyWhichMatchesNeedState() async {
        let cases: [(status: MatchStatus, requiresState: Bool)] = [
            (.noKnownLocations, false),
            (.accuracyTooLow, true),
            (.matched, true),
            (.notInKnownLocation, true),
            (.outsideWorkplace, true),
        ]

        for testCase in cases {
            let capture = FakeCaptureLocation(
                .matched(ucMatch(testCase.status, "resolved"))
            )
            let repository = FakeCheckRepository()
            let sut = RunAutomaticActivitiesUseCase(
                captureLocationUseCase: capture,
                checkRepository: repository,
                offlineQueue: FakeOfflineQueue(),
                clock: FixedClock(now),
                activityLogger: NoopActivityLogger()
            )
            guard case .ready(let configuration) = sut.preflight(
                chave: "STSM",
                userProjects: projects,
                mixedZoneIntervalMinutes: 15
            ) else {
                return XCTFail("expected configured preflight")
            }

            let preparation = await sut.prepare(
                configuration,
                accuracyThresholdMeters: 50,
                locationAttempt: .acquire
            )

            XCTAssertEqual(
                preparation.requiresCurrentState,
                testCase.requiresState,
                String(describing: testCase.status)
            )
            XCTAssertEqual(capture.callCount, 1)
            XCTAssertEqual(repository.submitCount, 0)
        }
    }

    func test_phasedMatchNetworkQueuesRawAndTerminatesWithoutStateOrCoordinatesInEnvelope() async {
        let reading = LocationReading(
            lat: 1.222_333_444,
            lon: 103.444_555_666,
            accuracyMeters: 37
        )
        let capture = FakeCaptureLocation(
            execution: LocationCaptureExecution(
                result: .networkError(reading: reading),
                maximumStage: .matched,
                capture: usableCaptureTrace,
                failure: .match(.network)
            )
        )
        let repository = FakeCheckRepository()
        let queue = FakeOfflineQueue()
        let ids = ClientEventIDFactory("raw-phased-id")
        let sut = makeUseCase(
            capture: capture,
            repository: repository,
            queue: queue,
            ids: ids
        )
        guard case .ready(let configuration) = sut.preflight(
            chave: "STSM",
            userProjects: projects,
            mixedZoneIntervalMinutes: 15
        ) else {
            return XCTFail("expected configured preflight")
        }

        let preparation = await sut.prepare(
            configuration,
            accuracyThresholdMeters: 50,
            locationAttempt: .acquire
        )

        guard case .terminal(let execution) = preparation else {
            return XCTFail("match network must be terminal before state")
        }
        XCTAssertFalse(preparation.requiresCurrentState)
        XCTAssertEqual(execution.result, .networkError)
        XCTAssertEqual(execution.trace.failure, .match(.network))
        XCTAssertEqual(execution.trace.offlineDisposition, .queuedRaw)
        XCTAssertEqual(capture.callCount, 1)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertEqual(ids.callCount, 1)
        XCTAssertEqual(queue.enqueued.count, 1)
        guard case .raw(let raw) = queue.enqueued[0] else {
            return XCTFail("expected Raw")
        }
        XCTAssertEqual(raw.latitude, reading.lat)
        XCTAssertEqual(raw.longitude, reading.lon)
        XCTAssertEqual(raw.accuracyMeters, reading.accuracyMeters)
        let terminalDescription = String(reflecting: execution)
        XCTAssertFalse(terminalDescription.contains(String(reading.lat)))
        XCTAssertFalse(terminalDescription.contains(String(reading.lon)))
    }

    func test_phasedStaleFinalSampleNeverReacquiresMatchesOrSubmits() async {
        let provider = FakeLocationProvider(.success(
            LocationSample(
                latitude: 9,
                longitude: 9,
                horizontalAccuracyMeters: 1,
                capturedAt: now,
                source: .standardCapture
            )
        ))
        let repository = FakeCheckRepository()
        let queue = FakeOfflineQueue()
        let capture = CaptureLocationUseCase(
            locationProvider: provider,
            checkRepository: repository,
            activityLogger: NoopActivityLogger(),
            clock: FixedClock(now),
            captureBehavior: .freshnessValidated
        )
        let sut = RunAutomaticActivitiesUseCase(
            captureLocationUseCase: capture,
            checkRepository: repository,
            offlineQueue: queue,
            clock: FixedClock(now),
            activityLogger: NoopActivityLogger()
        )
        guard case .ready(let configuration) = sut.preflight(
            chave: "STSM",
            userProjects: projects,
            mixedZoneIntervalMinutes: 15
        ) else {
            return XCTFail("expected configured preflight")
        }
        let stale = LocationSample(
            latitude: 1.3,
            longitude: 103.8,
            horizontalAccuracyMeters: 5,
            capturedAt: now.addingTimeInterval(-10.001),
            source: .standardCapture
        )

        let preparation = await sut.prepare(
            configuration,
            accuracyThresholdMeters: 50,
            locationAttempt: .finalSample(stale)
        )

        guard case .terminal(let execution) = preparation else {
            return XCTFail("stale final sample must terminate")
        }
        XCTAssertEqual(execution.result, .locationTimeout)
        XCTAssertEqual(execution.trace.failure, .sampleRejected(.stale))
        XCTAssertFalse(preparation.requiresCurrentState)
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(repository.matchLocationCallCount, 0)
        XCTAssertEqual(repository.submitCount, 0)
        XCTAssertTrue(queue.enqueued.isEmpty)
    }

    func test_phasedCompletePreservesUnregistered422AsSubmitRejection() async {
        let detailSentinel = "PHASED_422_DETAIL_MUST_STAY_IN_MEMORY"
        let capture = FakeCaptureLocation(
            .matched(ucMatch(.notInKnownLocation, nearest: 500))
        )
        let repository = FakeCheckRepository()
        repository.submitResult = .failure(
            .http(status: 422, detail: detailSentinel)
        )
        let queue = FakeOfflineQueue()
        let ids = ClientEventIDFactory("phased-422-id")
        let sut = makeUseCase(
            capture: capture,
            repository: repository,
            queue: queue,
            ids: ids
        )
        guard case .ready(let configuration) = sut.preflight(
            chave: "STSM",
            userProjects: projects,
            mixedZoneIntervalMinutes: 15
        ) else {
            return XCTFail("expected configured preflight")
        }
        guard case .ready(let prepared) = await sut.prepare(
            configuration,
            accuracyThresholdMeters: 50,
            locationAttempt: .acquire
        ) else {
            return XCTFail("expected prepared match")
        }

        let execution = await sut.complete(
            prepared,
            currentState: ucHistory(
                .checkIn,
                currentLocal: "Unidade P80"
            )
        )

        XCTAssertEqual(execution.result, .networkError)
        XCTAssertEqual(
            execution.trace.failure,
            .submit(.http(status: 422, detail: detailSentinel))
        )
        XCTAssertNil(execution.trace.offlineDisposition)
        XCTAssertEqual(execution.submissionContext?.clientEventId, "phased-422-id")
        XCTAssertEqual(
            execution.submissionContext?.local,
            "Localização não Cadastrada"
        )
        XCTAssertNil(execution.matchRetryContext)
        XCTAssertEqual(repository.submitCount, 1)
        XCTAssertTrue(queue.enqueued.isEmpty)
        XCTAssertEqual(ids.callCount, 1)
    }

    func test_captureBucketsAreClosedSanitizedAndPreservedWhenReused() {
        XCTAssertEqual(
            AutomaticCaptureAccuracyBucket.classify(meters: 10),
            .zeroTo10Meters
        )
        XCTAssertEqual(
            AutomaticCaptureAccuracyBucket.classify(meters: 10.1),
            .elevenTo25Meters
        )
        XCTAssertEqual(
            AutomaticCaptureAccuracyBucket.classify(meters: 50),
            .twentySixTo50Meters
        )
        XCTAssertEqual(
            AutomaticCaptureAccuracyBucket.classify(meters: 100),
            .fiftyOneTo100Meters
        )
        XCTAssertEqual(
            AutomaticCaptureAccuracyBucket.classify(meters: 100.1),
            .over100Meters
        )
        XCTAssertEqual(
            AutomaticCaptureAccuracyBucket.classify(meters: .nan),
            .unknown
        )
        XCTAssertEqual(
            AutomaticCaptureAgeBucket.classify(seconds: 0.999),
            .under1Second
        )
        XCTAssertEqual(
            AutomaticCaptureAgeBucket.classify(seconds: 5),
            .oneTo5Seconds
        )
        XCTAssertEqual(
            AutomaticCaptureAgeBucket.classify(seconds: 15),
            .sixTo15Seconds
        )
        XCTAssertEqual(
            AutomaticCaptureAgeBucket.classify(seconds: 15.001),
            .over15Seconds
        )
        XCTAssertEqual(
            AutomaticCaptureAgeBucket.classify(seconds: -1),
            .unknown
        )

        let trace = AutomaticCaptureTrace(
            source: .freshCapture,
            physicalSource: .standardCapture,
            reused: false,
            quality: .usable,
            accuracyBucket: .elevenTo25Meters,
            ageBucket: .oneTo5Seconds
        ).markingReused()

        XCTAssertTrue(trace.reused)
        XCTAssertEqual(trace.accuracyBucket, .elevenTo25Meters)
        XCTAssertEqual(trace.ageBucket, .oneTo5Seconds)
    }

    func test_sanitizedProjectionDropsHttpDetailAndUnknownDescription() {
        let httpDetail = "SENTINEL_HTTP_DETAIL_MUST_NOT_SURVIVE"
        let unknownDescription = "SENTINEL_UNKNOWN_DESCRIPTION_MUST_NOT_SURVIVE"

        let sanitizedHTTP = AutomaticActivitiesFailure.match(
            .http(status: 422, detail: httpDetail)
        ).sanitized
        let sanitizedUnknown = AutomaticActivitiesFailure.submit(
            .unknown(description: unknownDescription)
        ).sanitized

        XCTAssertEqual(
            sanitizedHTTP,
            .match(
                SanitizedAutomaticApiFailure(
                    .http(status: 422, detail: nil)
                )
            )
        )
        XCTAssertEqual(
            sanitizedUnknown,
            .submit(
                SanitizedAutomaticApiFailure(
                    .unknown(description: nil)
                )
            )
        )
        XCTAssertFalse(String(reflecting: sanitizedHTTP).contains(httpDetail))
        XCTAssertFalse(
            String(reflecting: sanitizedUnknown).contains(unknownDescription)
        )

        let invalidHTTPStatus = SanitizedAutomaticApiFailure(
            .http(status: 999, detail: httpDetail)
        )
        XCTAssertEqual(invalidHTTPStatus.kind, .http)
        XCTAssertNil(invalidHTTPStatus.httpStatus)
        XCTAssertFalse(String(reflecting: invalidHTTPStatus).contains(httpDetail))
    }
}
