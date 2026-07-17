import Foundation

/// Contrato de rede do módulo Check — port de domain/repository/CheckRepository.kt (fatia do motor).
/// Ver port_spec_network_contracts.md §5.
protocol CheckRepository: Sendable {
    func matchLocation(_ lat: Double, _ lon: Double, _ accuracyMeters: Double?) async -> AppResult<LocationMatch>
    func getState(_ chave: String) async -> AppResult<HistoryState>
    func getHistory(_ chave: String) async -> AppResult<[CheckHistoryEntry]>
    func getLocations() async -> AppResult<LocationOptions>
    func getGeofences(_ chave: String) async -> AppResult<[GeofenceCircle]>
    func submit(
        chave: String,
        projeto: String,
        action: CheckAction,
        local: String?,
        informe: InformeType,
        eventTime: Date,
        clientEventId: String,
        fillForms: Bool
    ) async -> AppResult<HistoryState>
}

extension CheckRepository {
    // fill_forms só é significativo quando false; live/recentes usam true (o servidor assume true).
    func submit(chave: String, projeto: String, action: CheckAction, local: String?,
                informe: InformeType, eventTime: Date, clientEventId: String) async -> AppResult<HistoryState> {
        await submit(chave: chave, projeto: projeto, action: action, local: local, informe: informe,
                     eventTime: eventTime, clientEventId: clientEventId, fillForms: true)
    }
}
