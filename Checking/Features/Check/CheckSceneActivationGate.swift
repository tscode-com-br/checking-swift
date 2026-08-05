enum CheckSceneTransition: Sendable, Equatable {
    case becameActive
    case becameInactive
    case unchanged
}

/// Gate puro que transforma notificações potencialmente repetidas da cena em transições autoritativas.
///
/// `.unknown` representa ausência de evidência positiva de foreground. Como o pipeline remoto só pode
/// trabalhar sob `.active`, um estado futuro/desconhecido encerra conservadoramente uma ativação.
struct CheckSceneActivationGate: Sendable, Equatable {
    private(set) var currentState: EvaluationApplicationState = .unknown

    mutating func transition(to newState: EvaluationApplicationState) -> CheckSceneTransition {
        switch newState {
        case .active:
            let wasActive = currentState == .active
            currentState = .active
            return wasActive ? .unchanged : .becameActive

        case .inactive, .background:
            let wasActive = currentState == .active
            currentState = newState
            return wasActive ? .becameInactive : .unchanged

        case .unknown:
            let wasActive = currentState == .active
            currentState = .unknown
            return wasActive ? .becameInactive : .unchanged
        }
    }
}
