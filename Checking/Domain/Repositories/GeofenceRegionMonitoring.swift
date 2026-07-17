import Foundation

/// Uma região circular a ser monitorada nativamente — o que o `GeofenceRegionManager` entrega ao monitor.
/// `id` = `String(GeofenceCircle.id)` (determinístico e versionado, igual ao `setRequestId` do Kotlin).
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
    /// Remove tudo — port de `GeofenceManager.unregisterAll` (chamado no stop do automático/logout).
    func removeAll() async
}

/// Monitor inerte para previews/testes (não toca o `CLLocationManager`). Não é usado em produção.
struct NoopGeofenceRegionMonitor: GeofenceRegionMonitoring {
    func sync(_ regions: [GeofenceRegion]) async {}
    func removeAll() async {}
}
