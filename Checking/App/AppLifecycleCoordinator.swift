import SwiftUI

/// Faz a RESTAURAÇÃO no retorno ao foreground (Camada D — a garantia mais forte que o iOS dá).
/// Ver port_spec_background_orchestrator §9 (Camada D) e port_spec_auth_lifecycle (onForegroundResume).
@MainActor
@Observable
final class AppLifecycleCoordinator {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Chamado a cada transição para `.active`. TODO: reavaliar permissões e precisão; reconciliar
    /// sessão/estado; reproduzir a fila offline; atualizar regiões; consultar acidentes/transporte;
    /// rodar avaliação automática se elegível e fora de pausa; reagendar BGTasks.
    func onBecameActive() {
        AppLog.lifecycle.debug("Foreground restore (TODO — ver Camada D).")
    }
}
