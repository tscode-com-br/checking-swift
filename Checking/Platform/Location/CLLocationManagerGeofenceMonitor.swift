import CoreLocation

/// Impl viva de `GeofenceRegionMonitoring` — region monitoring do `CLLocationManager`. Port do lado nativo
/// de GeofenceManager.kt (registro) + GeofenceBroadcastReceiver.kt (recepção de ENTER/EXIT → orquestrador).
///
/// Integração com o CoreLocation real — NÃO coberta por teste unitário (mesmo padrão de
/// `CLLocationManagerLocationProvider`/`NWPathMonitorNetworkMonitor`); a lógica testável (priorização, cap,
/// log) vive em `GeofenceRegionPrioritizer`/`GeofenceRegionManager`, exercitados com um monitor fake.
///
/// `@MainActor`: o `CLLocationManager` entrega callbacks na run loop da thread que o criou; fixar na main
/// garante uma run loop ativa. O `init` é `nonisolated` (só guarda logger/closure) e o manager é criado
/// preguiçosamente no 1º `sync`, para poder ser construído a partir da composição não-isolada.
@MainActor
final class CLLocationManagerGeofenceMonitor: NSObject, GeofenceRegionMonitoring, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private let activityLogger: any ActivityLogging
    private let onGeofenceWake: @Sendable () -> Void

    /// `onGeofenceWake`: acorda o orquestrador (`runOnce(.geofence)`) — injetado p/ evitar acoplar o monitor
    /// ao actor do orquestrador. Port do `orchestrator.runOnce(GEOFENCE)` do BroadcastReceiver.
    nonisolated init(activityLogger: any ActivityLogging, onGeofenceWake: @escaping @Sendable () -> Void) {
        self.activityLogger = activityLogger
        self.onGeofenceWake = onGeofenceWake
        super.init()
    }

    private func ensureManager() -> CLLocationManager {
        if let manager { return manager }
        let mgr = CLLocationManager()
        mgr.delegate = self
        // Region monitoring pode entregar em background e RELANÇAR o app terminado sem `allowsBackgroundLocationUpdates`
        // — MAS, para receber o evento que relançou o app, um `CLLocationManager` com delegate precisa ser criado
        // cedo no launch. Hoje este monitor é criado só no 1º `sync` (via `register`, ainda sem call-site de
        // produção); armar o handler de launch é do slice do gatilho (foreground/login). Entrega em background exige
        // autorização "Always" — pedir a permissão é do slice de permissões, não daqui.
        manager = mgr
        return mgr
    }

    func sync(_ regions: [GeofenceRegion]) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            activityLogger.logWarning("Region monitoring unavailable on this device.")
            return
        }
        let mgr = ensureManager()
        let desiredById = Dictionary(regions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Para as regiões que sumiram do conjunto desejado.
        for region in mgr.monitoredRegions where desiredById[region.identifier] == nil {
            mgr.stopMonitoring(for: region)
        }
        // Inicia as novas / com geometria alterada; pula as já monitoradas idênticas (idempotente).
        let monitored = mgr.monitoredRegions
        for region in regions {
            if let existing = monitored.first(where: { $0.identifier == region.id }) as? CLCircularRegion,
               sameGeometry(existing, region) {
                continue
            }
            let clRegion = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: region.centerLat, longitude: region.centerLng),
                radius: region.radiusMeters, identifier: region.id)
            clRegion.notifyOnEntry = true      // ENTER|EXIT — paridade com o Kotlin
            clRegion.notifyOnExit = true
            mgr.startMonitoring(for: clRegion)
            // O `requestState` (INITIAL_TRIGGER_ENTER) NÃO vai aqui: chamado logo após `startMonitoring`, antes
            // da região ser confirmada, o CoreLocation costuma reportar `.unknown` e o ENTER inicial se perde.
            // Ele é feito em `didStartMonitoringFor` (abaixo), quando a região já está registrada.
        }
    }

    func removeAll() {
        // `ensureManager()` (não `guard let manager`): o region monitoring persiste no NÍVEL DO SISTEMA e
        // sobrevive à morte do processo. Num relançamento a frio que faz logout/stop SEM antes chamar `sync`,
        // `manager` seria nil e um `guard let` sairia sem limpar nada — deixando geofences de uma sessão
        // anterior armadas (bug de correção E privacidade). Criar o manager expõe as `monitoredRegions`
        // persistidas para removê-las. Fiel ao `unregisterAll` estático do Kotlin, que limpa em qualquer estado.
        let mgr = ensureManager()
        for region in mgr.monitoredRegions { mgr.stopMonitoring(for: region) }
    }

    private func sameGeometry(_ region: CLCircularRegion, _ target: GeofenceRegion) -> Bool {
        region.center.latitude == target.centerLat &&
            region.center.longitude == target.centerLng &&
            region.radius == target.radiusMeters
    }

    // MARK: - CLLocationManagerDelegate (callbacks nonisolated → hop p/ MainActor)

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor [weak self] in self?.handleTransition(entered: true) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor [weak self] in self?.handleTransition(entered: false) }
    }

    // INITIAL_TRIGGER_ENTER (parte 1): só depois de a região estar CONFIRMADA (este callback) pedimos o
    // estado — aí o `requestState` é confiável (evita o `.unknown` de pedir cedo demais no `sync`).
    nonisolated func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        manager.requestState(for: region)
    }

    // INITIAL_TRIGGER_ENTER (parte 2): `.inside` no registro = usuário já está na região → trata como ENTER
    // (o Android entrega esse ENTER inicial via GeofencingRequest.INITIAL_TRIGGER_ENTER).
    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard state == .inside else { return }
        Task { @MainActor [weak self] in self?.handleTransition(entered: true) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        let id = region?.identifier ?? "?"
        Task { @MainActor [weak self] in self?.activityLogger.logWarning("Geofence monitoring failed for region \(id).") }
    }

    private func handleTransition(entered: Bool) {
        // Port do GeofenceBroadcastReceiver: loga a travessia (location=nil — o match é server-side) e acorda o
        // orquestrador. Sem FGS no iOS; single-flight do `runOnce` deduplica um eventual ENTER inicial + ENTER real.
        activityLogger.logLocation(entered ? "Entered geofence." : "Exited geofence.", nil, .info)
        onGeofenceWake()
    }
}
