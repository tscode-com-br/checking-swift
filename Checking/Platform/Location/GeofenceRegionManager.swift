import Foundation

/// Resumo da última registração — para o painel de integridade (slice de permissões/diagnóstico) reportar
/// "regiões monitoradas + quantidade omitida" (port_spec_permissions_diagnostics §84).
struct GeofenceRegistrationSummary: Sendable, Equatable {
    var monitored: Int
    var omitted: Int
}

/// Port de platform/background/GeofenceManager.kt (§23.2, T3B.9). Busca os círculos do projeto, prioriza
/// sob o cap de 20 do iOS (`GeofenceRegionPrioritizer` — lógica nova, sem contraparte Android) e entrega ao
/// monitor. Geofences são só GATILHOS de acordar; o match preciso é sempre no servidor (Approach A).
///
/// `actor`: `lastSummary` é estado mutável lido pelo diagnóstico de outra isolação. Erros são engolidos
/// (fiel ao Kotlin — o BGAppRefreshTask/foreground são o caminho primário; geofence é oportunista).
actor GeofenceRegionManager {
    private let checkRepository: any CheckRepository
    private let monitor: any GeofenceRegionMonitoring
    private let activityLogger: any ActivityLogging
    private(set) var lastSummary: GeofenceRegistrationSummary?

    init(checkRepository: any CheckRepository, monitor: any GeofenceRegionMonitoring, activityLogger: any ActivityLogging) {
        self.checkRepository = checkRepository
        self.monitor = monitor
        self.activityLogger = activityLogger
    }

    /// Busca os círculos e (re)registra o conjunto priorizado. Idempotente. `hints` prioriza a seleção
    /// quando há posição/local atual conhecidos; sem eles, cai na ordem por id (ainda determinística).
    func register(chave: String, hints: GeofencePriorityHints = GeofencePriorityHints()) async {
        let circles: [GeofenceCircle]
        switch await checkRepository.getGeofences(chave) {
        case .success(let c): circles = c
        case .failure: return                       // engole — fiel ao Kotlin (early return no Failure)
        }
        guard !circles.isEmpty else { return }       // fiel ao Kotlin (early return em lista vazia)

        let selection = GeofenceRegionPrioritizer.select(circles, hints: hints)
        let regions = selection.selected.map {
            GeofenceRegion(id: String($0.id), centerLat: $0.centerLat, centerLng: $0.centerLng, radiusMeters: $0.radiusMeters)
        }
        await monitor.sync(regions)
        lastSummary = GeofenceRegistrationSummary(monitored: regions.count, omitted: selection.omittedCount)

        // Mensagem byte-exact com o Kotlin, MAS a semântica de tempo difere: o Kotlin loga "registered" só no
        // `.onSuccess` do `addGeofences` do Play Services; aqui "registered" = ENTREGUE ao CoreLocation (o
        // `startMonitoring` retorna void e não confirma sucesso de forma síncrona/agregada). A falha por região
        // chega depois, assíncrona, via `monitoringDidFailFor` no monitor ("Geofence monitoring failed for …").
        activityLogger.logSystem("Geofences registered (\(regions.count)).", .info)
        if selection.omittedCount > 0 {
            // iOS-only: o cap de 20 forçou truncagem — NUNCA silenciosa (plano §9.2). O painel de
            // integridade também lê isso via `lastSummary`.
            activityLogger.logSystem(
                "Geofence cap: monitoring \(regions.count) of \(circles.count) region(s); \(selection.omittedCount) omitted (iOS 20-region limit).",
                .warning)
        }
    }

    /// Port de `GeofenceManager.unregisterAll` — remove tudo (stop do automático/logout).
    func unregisterAll() async {
        await monitor.removeAll()
        lastSummary = nil
    }
}
