import Foundation

/// Estado técnico da confirmação do conjunto nativo. Ele é deliberadamente separado da mensagem humana
/// histórica "Geofences registered (N).", que continua a significar apenas *requested*.
enum GeofenceMonitoringConfirmationState: String, Sendable, Equatable {
    case notRequested
    case requested
    case partiallyConfirmed
    case confirmed
    case failed
    case confirmationUncertain
}

/// Código fechado e serializável para o diagnóstico. A classificação de `CLError` ocorre no boundary de
/// Core Location; este tipo nunca carrega domínio, descrição ou payload bruto de um erro.
enum GeofenceMonitoringFailureCode: String, CaseIterable, Sendable, Hashable {
    case denied
    case regionMonitoringDenied
    case regionMonitoringFailure
    case other
}

/// Snapshot somente em memória do registro nativo. Não contém identificadores físicos, IDs lógicos,
/// locais, coordenadas, tokens ou erros brutos; ele é seguro para a tela técnica e o relatório Debug.
struct GeofenceMonitoringSnapshot: Sendable, Equatable {
    let syncGeneration: UInt64
    let requestedCount: Int
    let confirmedCount: Int
    let failedCount: Int
    let failedCodes: [GeofenceMonitoringFailureCode: Int]
    let omittedCount: Int
    let pendingCount: Int
    let confirmationState: GeofenceMonitoringConfirmationState
    let inheritedUnknownCount: Int

    static let empty = GeofenceMonitoringSnapshot(
        syncGeneration: 0,
        requestedCount: 0,
        confirmedCount: 0,
        failedCount: 0,
        failedCodes: [:],
        omittedCount: 0,
        pendingCount: 0,
        confirmationState: .notRequested,
        inheritedUnknownCount: 0
    )
}

/// Uma região circular desejada pelo domínio — o que o `GeofenceRegionManager` entrega ao monitor.
/// `id` é uma correlação lógica somente em memória. No caminho candidato, o monitor a traduz para um
/// identificador físico opaco próprio; ela nunca é copiada para journal, ActivityLog ou UserDefaults.
struct GeofenceRegion: Sendable, Equatable {
    var id: String
    var centerLat: Double
    var centerLng: Double
    var radiusMeters: Double
}

/// Seam sobre o region monitoring do `CLLocationManager` — impl viva é `CLLocationManagerGeofenceMonitor`
/// (integração, não testada por unidade). Permite testar o `GeofenceRegionManager` (fetch + priorização +
/// log) com um monitor fake. Port da parte "registrar/remover" de GeofenceManager.kt.
protocol GeofenceRegionMonitoring: Sendable {
    /// Reconcilia idempotentemente o conjunto monitorado com `regions` (para as que sumiram, inicia as
    /// novas) — mesma semântica do `addGeofences` do Kotlin, que substitui o set por request id.
    func sync(_ regions: [GeofenceRegion]) async
    /// Variante que recebe o diagnóstico de omitidas sem transportar as regiões omitidas ao monitor.
    /// Implementações legadas ignoram o campo e preservam o transporte histórico.
    func sync(_ regions: [GeofenceRegion], omittedCount: Int) async
    /// Remove tudo — port de `GeofenceManager.unregisterAll` (chamado no stop do automático/logout).
    func removeAll() async
    /// Snapshot técnico opcional. O monitor legado não consegue distinguir callbacks antigos e retorna nil;
    /// o monitor candidato expõe contagens requested/confirmed/failed/pending sem IDs ou coordenadas.
    func monitoringSnapshot() async -> GeofenceMonitoringSnapshot?
}

extension GeofenceRegionMonitoring {
    func sync(_ regions: [GeofenceRegion], omittedCount: Int) async {
        await sync(regions)
    }

    func monitoringSnapshot() async -> GeofenceMonitoringSnapshot? { nil }
}

/// Monitor inerte para previews/testes (não toca o `CLLocationManager`). Não é usado em produção.
struct NoopGeofenceRegionMonitor: GeofenceRegionMonitoring {
    func sync(_ regions: [GeofenceRegion]) async {}
    func removeAll() async {}
}
