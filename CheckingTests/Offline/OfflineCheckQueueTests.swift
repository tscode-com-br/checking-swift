import Foundation
import XCTest
@testable import Checking

// Port de OfflineCheckQueueTest.kt — cap/dedup/ordem/round-trip. Ver port_spec_offline_replay.md §9.1.
final class OfflineCheckQueueTests: XCTestCase {

    private final class BlockingWriteStore: OfflineQueueStore, @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        let writeEntered = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)

        func read() -> String {
            lock.withLock { value }
        }

        func write(_ json: String) {
            writeEntered.signal()
            releaseWrite.wait()
            lock.withLock { value = json }
        }
    }

    private func raw(_ id: String, at: Int64, lat: Double = 1.0) -> PendingCheckEvent {
        .raw(.init(chave: "HR70", projeto: "P80", capturedAtEpochMs: at, clientEventId: id,
                   latitude: lat, longitude: 103.0, accuracyMeters: 10.0))
    }
    private func decided(_ id: String, at: Int64) -> PendingCheckEvent {
        .decided(.init(chave: "HR70", projeto: "P80", capturedAtEpochMs: at, clientEventId: id,
                       action: "checkout", local: "Zona Mista", informe: "normal"))
    }
    private func makeQueue(_ store: OfflineQueueStore) -> OfflineCheckQueue {
        OfflineCheckQueue(store: store, scheduler: NoopSyncScheduler())
    }

    func test_enqueue_then_peek_returns_in_capture_order() async {
        let queue = makeQueue(InMemoryOfflineQueueStore())
        await queue.enqueue(raw("b", at: 200))
        await queue.enqueue(raw("a", at: 100))
        let ids = await queue.peekAll().map(\.clientEventId)
        XCTAssertEqual(ids, ["a", "b"])                 // ordem de captura, não de inserção
    }

    func test_enqueue_same_id_replaces_instead_of_duplicating() async {
        let queue = makeQueue(InMemoryOfflineQueueStore())
        await queue.enqueue(decided("x", at: 100))
        await queue.enqueue(decided("x", at: 150))
        let size = await queue.size()
        let only = await queue.peekAll().first
        XCTAssertEqual(size, 1)
        XCTAssertEqual(only?.capturedAtEpochMs, 150)     // o novo vence
    }

    func test_remove_drops_only_that_id() async {
        let queue = makeQueue(InMemoryOfflineQueueStore())
        await queue.enqueue(raw("a", at: 100))
        await queue.enqueue(decided("b", at: 200))
        await queue.remove("a")
        let ids = await queue.peekAll().map(\.clientEventId)
        XCTAssertEqual(ids, ["b"])
    }

    func test_survives_serialization_roundtrip_for_both_variants() async {
        let store = InMemoryOfflineQueueStore()
        let queue = makeQueue(store)
        await queue.enqueue(raw("r", at: 100, lat: 1.2345))
        await queue.enqueue(decided("d", at: 200))

        let reopened = await makeQueue(store).peekAll()  // fila NOVA sobre o mesmo store (reinício de processo)
        XCTAssertEqual(reopened.count, 2)
        guard case .raw(let r)? = reopened.first(where: { $0.clientEventId == "r" }) else { return XCTFail("expected raw r") }
        XCTAssertEqual(r.latitude, 1.2345, accuracy: 0.0)
        guard case .decided(let d)? = reopened.first(where: { $0.clientEventId == "d" }) else { return XCTFail("expected decided d") }
        XCTAssertEqual(d.action, "checkout")
        XCTAssertEqual(d.local, "Zona Mista")
    }

    func test_encode_failure_preserves_prior_queue() async {
        let queue = makeQueue(InMemoryOfflineQueueStore())
        await queue.enqueue(raw("a", at: 100))
        // accuracy não-finito → encode do blob falha; o blob anterior DEVE sobreviver (fiel ao Kotlin).
        await queue.enqueue(.raw(.init(chave: "HR70", projeto: "P80", capturedAtEpochMs: 200, clientEventId: "b",
                                       latitude: 1.0, longitude: 103.0, accuracyMeters: .infinity)))
        let ids = await queue.peekAll().map(\.clientEventId)
        XCTAssertEqual(ids, ["a"])                       // "a" preservado; "b" não persistido (não apagou tudo)
    }

    func test_caps_queue_dropping_oldest() async {
        let queue = makeQueue(InMemoryOfflineQueueStore())
        for i in 1...205 { await queue.enqueue(raw("e\(i)", at: Int64(i))) }
        let all = await queue.peekAll()
        XCTAssertEqual(all.count, 200)
        XCTAssertEqual(all.first?.clientEventId, "e6")   // e1..e5 (os 5 mais antigos) descartados
        XCTAssertEqual(all.first?.capturedAtEpochMs, 6)
    }

    func test_enqueueIfCurrent_rejectsRevokedEvaluationWithoutPersisting() async {
        let queue = makeQueue(InMemoryOfflineQueueStore())
        let evaluationValidity = AutomaticActivitiesEvaluationValidity()
        let effectGuard = AutomaticActivitiesEffectGuard(
            sessionGeneration: AuthSessionGeneration(value: 3),
            evaluationValidity: evaluationValidity
        )
        evaluationValidity.invalidate()

        let accepted = await queue.enqueueIfCurrent(
            raw("stale", at: 100),
            effectGuard: effectGuard
        )

        XCTAssertFalse(accepted)
        let size = await queue.size()
        XCTAssertEqual(size, 0)
    }

    func test_enqueueIfCurrent_linearizesRevocationWithSynchronousPersistence() async {
        let store = BlockingWriteStore()
        let queue = makeQueue(store)
        let evaluationValidity = AutomaticActivitiesEvaluationValidity()
        let effectGuard = AutomaticActivitiesEffectGuard(
            sessionGeneration: AuthSessionGeneration(value: 3),
            evaluationValidity: evaluationValidity
        )
        let event = raw("current", at: 100)
        let enqueue = Task.detached(priority: .userInitiated) {
            await queue.enqueueIfCurrent(
                event,
                effectGuard: effectGuard
            )
        }

        XCTAssertEqual(
            store.writeEntered.wait(timeout: .now() + 1),
            .success,
            "a escrita síncrona deveria iniciar sob o fence"
        )

        let invalidationStarted = DispatchSemaphore(value: 0)
        let invalidationFinished = DispatchSemaphore(value: 0)
        DispatchQueue(
            label: "offline-queue-effect-invalidation",
            qos: .userInitiated
        ).async {
            invalidationStarted.signal()
            evaluationValidity.invalidate()
            invalidationFinished.signal()
        }
        XCTAssertEqual(invalidationStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            invalidationFinished.wait(timeout: .now() + 0.1),
            .timedOut,
            "a revogação não pode ultrapassar uma escrita que já foi linearizada"
        )

        store.releaseWrite.signal()
        let enqueueAccepted = await enqueue.value
        XCTAssertTrue(enqueueAccepted)
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 1), .success)
        let persisted = await queue.peekAll()
        XCTAssertEqual(persisted.map(\.clientEventId), ["current"])

        let rejectedAfterRevocation = await queue.enqueueIfCurrent(
            raw("stale", at: 200),
            effectGuard: effectGuard
        )
        XCTAssertFalse(rejectedAfterRevocation)
        let finalIDs = await queue.peekAll().map(\.clientEventId)
        XCTAssertEqual(finalIDs, ["current"])
    }
}
