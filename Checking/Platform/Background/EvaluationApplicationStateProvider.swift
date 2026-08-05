/// Fonte coarse e injetável do estado atual da cena.
///
/// O contrato permanece livre de UIKit/SwiftUI para que cold launch, orquestrador e testes não dependam
/// da construção da interface. `unknown` é deliberadamente conservador: nunca equivale a foreground.
protocol EvaluationApplicationStateProviding: Sendable {
    func currentApplicationState() async -> EvaluationApplicationState
}

struct UnknownEvaluationApplicationStateProvider: EvaluationApplicationStateProviding {
    func currentApplicationState() async -> EvaluationApplicationState {
        .unknown
    }
}

/// Store compartilhável que recebe transições da fronteira de UI e oferece snapshots serializados aos
/// consumidores de background. Não persiste estado e não mantém referência a cenas ou objetos de UI.
actor EvaluationApplicationStateStore: EvaluationApplicationStateProviding {
    private var applicationState: EvaluationApplicationState
    private var issuedRevision: UInt64 = 0
    private var appliedRevision: UInt64 = 0

    init(initialState: EvaluationApplicationState = .unknown) {
        applicationState = initialState
    }

    func currentApplicationState() async -> EvaluationApplicationState {
        applicationState
    }

    /// Reserva uma ordem monotônica antes que a UI atravesse qualquer outro actor. Uma task de cena
    /// cancelada pode até retomar depois, mas sua revisão antiga não consegue sobrescrever a mais nova.
    func reserveUpdateRevision() -> UInt64 {
        issuedRevision &+= 1
        return issuedRevision
    }

    @discardableResult
    func update(
        _ state: EvaluationApplicationState,
        revision: UInt64
    ) -> Bool {
        guard revision > appliedRevision else { return false }
        issuedRevision = max(issuedRevision, revision)
        appliedRevision = revision
        applicationState = state
        return true
    }

    func update(_ state: EvaluationApplicationState) {
        issuedRevision &+= 1
        appliedRevision = issuedRevision
        applicationState = state
    }
}
