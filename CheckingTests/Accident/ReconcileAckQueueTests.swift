import XCTest
@testable import Checking

// reconcileAckQueue — dedup de SESSÃO (novo acidente enfileira 1×; já-visto não re-enfileira; acidente
// não mais ativo é removido). §14.
final class ReconcileAckQueueTests: XCTestCase {

    func test_new_active_accident_enqueues_and_shows_immediately() {
        var state = AccidentUiState()
        state.accidentState = accidentStateWith([accidentItem(1)])
        let result = reconcileAckQueue(state)
        XCTAssertEqual(result.ackDialogShowing?.accidentId, 1)   // fila vazia → mostra direto
        XCTAssertTrue(result.ackDialogQueue.isEmpty)
        XCTAssertEqual(result.ackShownForAccidentIds, [1])
    }

    func test_already_seen_this_session_does_not_reenqueue() {
        var state = AccidentUiState()
        state.accidentState = accidentStateWith([accidentItem(1)])
        state.ackShownForAccidentIds = [1]
        let result = reconcileAckQueue(state)
        XCTAssertNil(result.ackDialogShowing)
        XCTAssertTrue(result.ackDialogQueue.isEmpty)
    }

    func test_second_new_accident_queues_behind_the_one_already_showing() {
        var state = AccidentUiState()
        state.ackDialogShowing = accidentItem(1)
        state.ackShownForAccidentIds = [1]
        state.accidentState = accidentStateWith([accidentItem(1), accidentItem(2)])
        let result = reconcileAckQueue(state)
        XCTAssertEqual(result.ackDialogShowing?.accidentId, 1)     // já mostrando — não troca
        XCTAssertEqual(result.ackDialogQueue.map(\.accidentId), [2])
        XCTAssertEqual(result.ackShownForAccidentIds, [1])          // 2 ainda não foi mostrado (só enfileirado)
    }

    func test_no_longer_active_accident_is_pruned_from_queue() {
        // ackDialogShowing já ocupado por outro item — assim a poda fica visível na FILA em vez de
        // ser imediatamente promovida a "showing" (que é o comportamento correto quando showing==nil).
        var state = AccidentUiState()
        state.ackDialogShowing = accidentItem(3)
        state.ackDialogQueue = [accidentItem(1), accidentItem(2)]
        state.ackShownForAccidentIds = [1, 2, 3]
        state.accidentState = accidentStateWith([accidentItem(2), accidentItem(3)])   // 1 não está mais ativo
        let result = reconcileAckQueue(state)
        XCTAssertEqual(result.ackDialogQueue.map(\.accidentId), [2])
        XCTAssertEqual(result.ackDialogShowing?.accidentId, 3)   // inalterado
    }

    func test_pruned_and_showing_together() {
        var state = AccidentUiState()
        state.ackDialogShowing = accidentItem(1)
        state.ackDialogQueue = [accidentItem(2)]
        state.ackShownForAccidentIds = [1, 2]
        state.accidentState = accidentStateWith([accidentItem(1)])   // 2 não está mais ativo → sai da fila
        let result = reconcileAckQueue(state)
        XCTAssertEqual(result.ackDialogShowing?.accidentId, 1)
        XCTAssertTrue(result.ackDialogQueue.isEmpty)
    }
}
