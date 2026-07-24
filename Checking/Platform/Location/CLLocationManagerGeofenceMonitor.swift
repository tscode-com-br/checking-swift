import CoreLocation

/// Impl viva de `GeofenceRegionMonitoring` — region monitoring do `CLLocationManager`. Port do lado nativo
/// de GeofenceManager.kt (registro) + GeofenceBroadcastReceiver.kt (recepção de ENTER/EXIT → orquestrador).
///
/// Integração com o CoreLocation real — NÃO coberta por teste unitário (mesmo padrão de
/// `CLLocationManagerLocationProvider`/`NWPathMonitorNetworkMonitor`); a lógica testável (priorização, cap,
/// log) vive em `GeofenceRegionPrioritizer`/`GeofenceRegionManager`, exercitados com um monitor fake.
///
/// `@MainActor`: o `CLLocationManager` entrega callbacks na run loop da thread que o criou; fixar na main
/// garante uma run loop ativa. O manager e seu delegate são criados IMEDIATAMENTE na composição do app:
/// regiões persistem no sistema entre processos e o evento que relança o app pode chegar antes de qualquer
/// `sync`. Criação preguiçosa perde exatamente esse primeiro ENTER/EXIT em background.
@MainActor
final class CLLocationManagerGeofenceMonitor: NSObject, GeofenceRegionMonitoring, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private var transitionDeduplicator = GeofenceTransitionDeduplicator()
    private let activityLogger: any ActivityLogging
    private let onGeofenceWake: @Sendable () -> Void

    /// `onGeofenceWake`: acorda o orquestrador (`runOnce(.geofence)`) — injetado p/ evitar acoplar o monitor
    /// ao actor do orquestrador. Port do `orchestrator.runOnce(GEOFENCE)` do BroadcastReceiver.
    init(activityLogger: any ActivityLogging, onGeofenceWake: @escaping @Sendable () -> Void) {
        self.activityLogger = activityLogger
        self.onGeofenceWake = onGeofenceWake
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
    }

    private func ensureManager() -> CLLocationManager {
        manager
    }

    var isDelegateActiveForTest: Bool { manager.delegate === self }

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
        let identifier = region.identifier
        Task { @MainActor [weak self] in self?.handleTransition(entered: true, identifier: identifier) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let identifier = region.identifier
        Task { @MainActor [weak self] in self?.handleTransition(entered: false, identifier: identifier) }
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
        let identifier = region.identifier
        Task { @MainActor [weak self] in self?.handleTransition(entered: true, identifier: identifier) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        let id = region?.identifier ?? "?"
        Task { @MainActor [weak self] in self?.activityLogger.logWarning("Geofence monitoring failed for region \(id).") }
    }

    private func handleTransition(entered: Bool, identifier: String) {
        // Port do GeofenceBroadcastReceiver: loga a travessia (location=nil — o match é server-side) e acorda o
        // orquestrador. Sem FGS no iOS; single-flight do `runOnce` deduplica um eventual ENTER inicial + ENTER real.
        // O Core Location pode entregar `didDetermineState(.inside)` e `didEnterRegion` para a mesma entrada.
        // Suprimimos somente a mesma direção/região numa janela curta; EXIT após ENTER continua imediato.
        guard transitionDeduplicator.shouldHandle(identifier: identifier, entered: entered, at: Date()) else { return }
        activityLogger.logLocation(entered ? "Entered geofence." : "Exited geofence.", nil, .info)
#if DEBUG
        if BackgroundValidationHarness.isEnabled {
            Task {
                await BackgroundValidationRecorder.shared.record(
                    entered ? "production_geofence_enter" : "production_geofence_exit",
                    details: ["region": identifier]
                )
            }
        }
#endif
        onGeofenceWake()
    }
}

/// Filtro mínimo para o par `didDetermineState(.inside)` + `didEnterRegion` que o Core Location pode emitir
/// para a mesma travessia. Não mistura regiões e não bloqueia inversão de direção.
struct GeofenceTransitionDeduplicator: Sendable {
    static let defaultWindow: TimeInterval = 3

    private struct Transition: Sendable {
        let entered: Bool
        let at: Date
    }

    private var latestByRegion: [String: Transition] = [:]

    mutating func shouldHandle(
        identifier: String,
        entered: Bool,
        at: Date,
        window: TimeInterval = Self.defaultWindow
    ) -> Bool {
        if let latest = latestByRegion[identifier], latest.entered == entered {
            let elapsed = at.timeIntervalSince(latest.at)
            if elapsed >= 0, elapsed < window { return false }
        }
        latestByRegion[identifier] = Transition(entered: entered, at: at)
        return true
    }
}
