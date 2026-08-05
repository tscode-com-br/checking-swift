import Foundation

/// Contrato de rede do módulo Check — port de domain/repository/CheckRepository.kt (fatia do motor).
/// Ver port_spec_network_contracts.md §5.
protocol CheckRepository: Sendable {
    func matchLocation(_ lat: Double, _ lon: Double, _ accuracyMeters: Double?) async -> AppResult<LocationMatch>
    func matchLocation(
        _ lat: Double,
        _ lon: Double,
        _ accuracyMeters: Double?,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> GuardedOperationResult<AppResult<LocationMatch>>
    func getState(_ chave: String) async -> AppResult<HistoryState>
    func getHistory(_ chave: String) async -> AppResult<[CheckHistoryEntry]>
    func getLocations() async -> AppResult<LocationOptions>
    func getGeofences(_ chave: String) async -> AppResult<[GeofenceCircle]>
    func invalidateGeofenceCache()
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
    func submit(
        chave: String,
        projeto: String,
        action: CheckAction,
        local: String?,
        informe: InformeType,
        eventTime: Date,
        clientEventId: String,
        fillForms: Bool,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> GuardedOperationResult<AppResult<HistoryState>>
}

extension CheckRepository {
    /// Fakes e implementações sem cache não precisam fazer nada.
    func invalidateGeofenceCache() {}

    /// Compatibilidade para fakes/adapters. O trabalho nasce dentro do fence, portanto um fake que grava
    /// sua chamada no início do método antigo observa zero dispatch quando o token já foi revogado.
    /// A implementação live sobrescreve este overload e leva o mesmo fence até `URLSessionTask.resume()`.
    func matchLocation(
        _ lat: Double,
        _ lon: Double,
        _ accuracyMeters: Double?,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> GuardedOperationResult<AppResult<LocationMatch>> {
        let authorization = HTTPRequestDispatchAuthorization(
            performIfAuthorized: { operation in
                effectGuard.performIfCurrent(operation)
            }
        )
        do {
            return try await runGuardedAsyncOperation(
                authorization: authorization,
                operation: {
                    await self.matchLocation(lat, lon, accuracyMeters)
                }
            )
        } catch {
            // A operação antiga não lança; este branch existe apenas pela assinatura genérica do
            // helper e nunca é alcançado por um conformer correto.
            return .dispatched(.failure(.unknown(description: nil)))
        }
    }

    func submit(
        chave: String,
        projeto: String,
        action: CheckAction,
        local: String?,
        informe: InformeType,
        eventTime: Date,
        clientEventId: String,
        fillForms: Bool,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> GuardedOperationResult<AppResult<HistoryState>> {
        let authorization = HTTPRequestDispatchAuthorization(
            performIfAuthorized: { operation in
                effectGuard.performIfCurrent(operation)
            }
        )
        do {
            return try await runGuardedAsyncOperation(
                authorization: authorization,
                operation: {
                    await self.submit(
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
            )
        } catch {
            return .dispatched(.failure(.unknown(description: nil)))
        }
    }

    // fill_forms só é significativo quando false; live/recentes usam true (o servidor assume true).
    func submit(chave: String, projeto: String, action: CheckAction, local: String?,
                informe: InformeType, eventTime: Date, clientEventId: String) async -> AppResult<HistoryState> {
        await submit(chave: chave, projeto: projeto, action: action, local: local, informe: informe,
                     eventTime: eventTime, clientEventId: clientEventId, fillForms: true)
    }
}
