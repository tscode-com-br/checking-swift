import Foundation
import XCTest
@testable import Checking

/// Exercita a fronteira que o `AppDelegate` usa para os dois registros BackgroundTasks. `BGTask` não é
/// construível em XCTest, portanto este fake recebe exatamente o expiration handler que o adapter UIKit
/// recebe em produção, sem simular ou alterar o scheduler do sistema.
final class AppDelegateBackgroundTaskHandlerRoutingTests: XCTestCase {
    private final class SystemTaskProbe: SystemBackgroundTaskHandling, @unchecked Sendable {
        private let lock = NSLock()
        private var expirationHandler: (@Sendable () -> Void)?
        private var installationCount = 0

        @MainActor
        func installExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
            lock.withLock {
                installationCount += 1
                expirationHandler = handler
            }
        }

        func fireExpiration() {
            let handler = lock.withLock { expirationHandler }
            handler?()
        }

        var installedHandlers: Int { lock.withLock { installationCount } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.withLock { value += 1 }
        }

        var count: Int { lock.withLock { value } }
    }

    private final class RouteProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var candidateStarts = 0
        private var legacyStarts = 0

        func recordCandidateStart() {
            lock.withLock { candidateStarts += 1 }
        }

        func recordLegacyStart() {
            lock.withLock { legacyStarts += 1 }
        }

        var candidateCount: Int { lock.withLock { candidateStarts } }
        var legacyCount: Int { lock.withLock { legacyStarts } }
    }

    private final class CompletionProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []

        func record(_ success: Bool) {
            lock.withLock { values.append(success) }
        }

        var snapshot: [Bool] { lock.withLock { values } }
    }

    /// Repositório que suspende o submit de um evento já durável. Após `cancelCanonicalWork`, ele devolve
    /// uma resposta propositalmente indeterminada, como faria a borda HTTP cancelada; o replayer precisa
    /// conservar o evento, e o controller precisa concluir o task de sistema uma única vez com `false`.
    private final class SuspendedSubmitRepository: CheckRepository, @unchecked Sendable {
        struct Submit: Equatable, Sendable {
            let clientEventID: String
            let eventTime: Date
        }

        private let gate = AsyncGate()
        private let lock = NSLock()
        private var submitStarted = false
        private var recordedSubmits: [Submit] = []

        func matchLocation(
            _ lat: Double,
            _ lon: Double,
            _ accuracyMeters: Double?
        ) async -> AppResult<LocationMatch> {
            .failure(.network)
        }

        func getState(_ chave: String) async -> AppResult<HistoryState> {
            .failure(.network)
        }

        func getHistory(_ chave: String) async -> AppResult<[CheckHistoryEntry]> {
            .failure(.network)
        }

        func getLocations() async -> AppResult<LocationOptions> {
            .failure(.network)
        }

        func getGeofences(_ chave: String) async -> AppResult<[GeofenceCircle]> {
            .failure(.network)
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
            lock.withLock {
                submitStarted = true
                recordedSubmits.append(Submit(clientEventID: clientEventId, eventTime: eventTime))
            }
            await gate.wait()
            guard !Task.isCancelled else {
                // A resposta do transporte não é confiável depois da expiração; o fence do replayer
                // precisa devolver `.retry` antes de remover o handoff existente.
                return .failure(.unknown(description: nil))
            }
            return .success(HistoryState(
                found: true,
                chave: chave,
                projeto: projeto,
                currentAction: action,
                currentLocal: local,
                hasCurrentDayCheckin: action == .checkIn,
                lastCheckinAt: action == .checkIn ? eventTime : nil,
                lastCheckoutAt: action == .checkOut ? eventTime : nil,
                transportEnabled: false
            ))
        }

        func releaseSubmit() async {
            await gate.release()
        }

        var didStartSubmit: Bool { lock.withLock { submitStarted } }
        var submits: [Submit] { lock.withLock { recordedSubmits } }
    }

    @MainActor
    func test_everyProfileInstallsExactlyOneSelectedHandler() {
        for profile in BackgroundReliabilityProfile.allCases {
            let task = SystemTaskProbe()
            let routes = RouteProbe()
            let candidateExpiration = Counter()
            let legacyExpiration = Counter()

            AppDelegateBackgroundTaskHandlerRouter.install(
                profile: profile,
                task: task,
                startCandidate: {
                    routes.recordCandidateStart()
                    return SystemBackgroundTaskExpirationHandle {
                        candidateExpiration.increment()
                    }
                },
                startLegacy: {
                    routes.recordLegacyStart()
                    return SystemBackgroundTaskExpirationHandle {
                        legacyExpiration.increment()
                    }
                }
            )

            XCTAssertEqual(task.installedHandlers, 1, "\(profile) must install one expiration handler")
            let expectsCandidate = profile.operationalPipeline == .candidate
            XCTAssertEqual(routes.candidateCount, expectsCandidate ? 1 : 0, "\(profile)")
            XCTAssertEqual(routes.legacyCount, expectsCandidate ? 0 : 1, "\(profile)")

            task.fireExpiration()
            XCTAssertEqual(candidateExpiration.count, expectsCandidate ? 1 : 0, "\(profile)")
            XCTAssertEqual(legacyExpiration.count, expectsCandidate ? 0 : 1, "\(profile)")
        }
    }

    @MainActor
    func test_candidateProcessingHandlerExpirationKeepsActualOfflineQueueAndCompletesOnce() async {
        let event = PendingCheckEvent.decided(.init(
            chave: "HR70",
            projeto: "P80",
            capturedAtEpochMs: 1_723_000_000_123,
            clientEventId: "pending-existing-event",
            action: "checkout",
            local: "Zona Mista",
            informe: "normal"
        ))
        let store = InMemoryOfflineQueueStore()
        let queue = OfflineCheckQueue(store: store, scheduler: NoopSyncScheduler())
        await queue.enqueue(event)

        let repository = SuspendedSubmitRepository()
        let replayer = PendingCheckReplayer(
            queue: queue,
            repository: repository,
            logger: RecordingActivityLogger()
        )
        let coordinator = OfflineSyncCoordinator(
            replayer: replayer,
            monitor: FakeNetworkMonitor(online: false)
        )
        let task = SystemTaskProbe()
        let routes = RouteProbe()
        let schedules = Counter()
        let completions = CompletionProbe()

        AppDelegateBackgroundTaskHandlerRouter.install(
            profile: .candidate,
            task: task,
            startCandidate: {
                routes.recordCandidateStart()
                let controller = BGProcessingExecutionController(
                    startDrain: { await coordinator.drainTicket() },
                    scheduleProcessing: { schedules.increment() }
                )
                let handle = controller.start { success in
                    completions.record(success)
                }
                return SystemBackgroundTaskExpirationHandle { _ = handle.expire() }
            },
            startLegacy: {
                routes.recordLegacyStart()
                return SystemBackgroundTaskExpirationHandle {}
            }
        )

        await waitUntil { repository.didStartSubmit }
        XCTAssertTrue(repository.didStartSubmit)
        let installedHandlers = task.installedHandlers
        XCTAssertEqual(installedHandlers, 1)
        XCTAssertEqual(routes.candidateCount, 1)
        XCTAssertEqual(routes.legacyCount, 0)

        // Esta é a mesma closure instalada no `BGProcessingTask.expirationHandler` pelo AppDelegate.
        // Repeti-la modela uma corrida/entrega duplicada do framework sem permitir dupla conclusão.
        task.fireExpiration()
        task.fireExpiration()
        await repository.releaseSubmit()
        await waitUntil { completions.snapshot.count == 1 }

        XCTAssertEqual(completions.snapshot, [false])
        XCTAssertEqual(schedules.count, 1)
        XCTAssertEqual(repository.submits, [
            .init(
                clientEventID: "pending-existing-event",
                eventTime: Date(timeIntervalSince1970: 1_723_000_000.123)
            ),
        ])

        // Reabre o mesmo store para provar que o cancelamento não removeu nem recriou o handoff.
        let reopenedQueue = OfflineCheckQueue(store: store, scheduler: NoopSyncScheduler())
        let persistedEvents = await reopenedQueue.peekAll()
        XCTAssertEqual(persistedEvents, [event])
    }
}
