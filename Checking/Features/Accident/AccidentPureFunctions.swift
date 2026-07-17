import Foundation

/// Fila de ciência — port de `reconcileAckQueue` (dedup de SESSÃO). Chamada a cada `refreshState`/`open`
/// bem-sucedido: enfileira acidentes ativos ainda não vistos NESTA sessão; remove os não mais ativos.
/// Ver port_spec_accident_video.md §4.
func reconcileAckQueue(_ state: AccidentUiState) -> AccidentUiState {
    let activeIds = Set(state.activeAccidents.map(\.accidentId))
    let pruned = state.ackDialogQueue.filter { activeIds.contains($0.accidentId) }        // remove os não mais ativos
    let new = state.activeAccidents.filter { accident in                                  // novos ainda não vistos/enfileirados/exibindo
        !state.ackShownForAccidentIds.contains(accident.accidentId)
        && !pruned.contains { $0.accidentId == accident.accidentId }
        && state.ackDialogShowing?.accidentId != accident.accidentId
    }
    let queue = pruned + new
    let showing = (state.ackDialogShowing == nil && !queue.isEmpty) ? queue.first : state.ackDialogShowing
    let queueAfter = (state.ackDialogShowing == nil && !queue.isEmpty) ? Array(queue.dropFirst()) : queue
    var shownIds = state.ackShownForAccidentIds
    if let showing { shownIds.insert(showing.accidentId) }

    var next = state
    next.ackDialogQueue = queueAfter
    next.ackDialogShowing = showing
    next.ackShownForAccidentIds = shownIds
    return next
}
