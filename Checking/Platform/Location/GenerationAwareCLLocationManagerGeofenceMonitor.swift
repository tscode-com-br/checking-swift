import CoreLocation

/// Monitor de region monitoring do perfil candidato. Ao contrário do handler legado, ele não usa o ID
/// lógico como `CLCircularRegion.identifier`: o `GeofenceGenerationAdapter` cria uma identidade física
/// aleatória por geração e só confirma callbacks cujo token e geometria ainda são esperados.
@MainActor
final class GenerationAwareCLLocationManagerGeofenceMonitor: NSObject, GeofenceRegionMonitoring, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private let nativeAdapter: CoreLocationGeofenceNativeAdapter
    private let generationAdapter: GeofenceGenerationAdapter
    private var transitionDeduplicator = GeofenceTransitionDeduplicator()
    private let activityLogger: any ActivityLogging
    private let onGeofenceWake: @Sendable () -> Void

    init(
        activityLogger: any ActivityLogging,
        onGeofenceWake: @escaping @Sendable () -> Void
    ) {
        let manager = CLLocationManager()
        self.manager = manager
        nativeAdapter = CoreLocationGeofenceNativeAdapter(manager: manager)
        generationAdapter = GeofenceGenerationAdapter(native: nativeAdapter)
        self.activityLogger = activityLogger
        self.onGeofenceWake = onGeofenceWake
        super.init()
        manager.delegate = self
    }

    var isDelegateActiveForTest: Bool { manager.delegate === self }

    func sync(_ regions: [GeofenceRegion]) {
        sync(regions, omittedCount: 0)
    }

    func sync(_ regions: [GeofenceRegion], omittedCount: Int) {
        let monitoringAvailable = CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
        if !monitoringAvailable {
            // Registra requested/pending honestamente, mas não faz uma tentativa nativa sabidamente inválida.
            activityLogger.logWarning("Region monitoring unavailable on this device.")
        }
        generationAdapter.sync(
            regions,
            omittedCount: omittedCount,
            issueNativeRequests: monitoringAvailable
        )
        recordSnapshotForValidation()
    }

    func removeAll() {
        generationAdapter.removeAll()
        recordSnapshotForValidation()
    }

    func monitoringSnapshot() async -> GeofenceMonitoringSnapshot? {
        generationAdapter.snapshot
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let nativeRegion = GeofenceNativeRegion(region: region)
        Task { @MainActor [weak self] in
            self?.handleTransition(entered: true, nativeRegion: nativeRegion)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let nativeRegion = GeofenceNativeRegion(region: region)
        Task { @MainActor [weak self] in
            self?.handleTransition(entered: false, nativeRegion: nativeRegion)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        let nativeRegion = GeofenceNativeRegion(region: region)
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = generationAdapter.didStartMonitoring(for: nativeRegion)
            recordSnapshotForValidation()
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didDetermineState state: CLRegionState,
        for region: CLRegion
    ) {
        guard state == .inside else { return }
        let nativeRegion = GeofenceNativeRegion(region: region)
        Task { @MainActor [weak self] in
            self?.handleTransition(entered: true, nativeRegion: nativeRegion)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        monitoringDidFailFor region: CLRegion?,
        withError error: Error
    ) {
        let nativeRegion = region.map(GeofenceNativeRegion.init(region:))
        Task { @MainActor [weak self] in
            guard let self else { return }
            if generationAdapter.monitoringDidFail(for: nativeRegion, error: error) {
                // Não incluir ID/token nem texto bruto do erro no ActivityLog. O snapshot técnico conserva
                // apenas a contagem e o código fechado para o relatório de validação.
                activityLogger.logWarning("Geofence monitoring failed.")
                recordSnapshotForValidation()
            }
        }
    }

    private func handleTransition(entered: Bool, nativeRegion: GeofenceNativeRegion?) {
        guard let nativeRegion,
              let deduplicationKey = generationAdapter.wakeDeduplicationKey(for: nativeRegion.identifier),
              transitionDeduplicator.shouldHandle(
                identifier: deduplicationKey,
                entered: entered,
                at: Date()
              )
        else { return }

        // Continua sendo apenas wake-only: não há sample/ID lógico no callback e o match permanece server-side.
        activityLogger.logLocation(entered ? "Entered geofence." : "Exited geofence.", nil, .info)
#if DEBUG
        if BackgroundValidationHarness.isEnabled {
            Task {
                await BackgroundValidationRecorder.shared.record(
                    entered ? "production_geofence_enter" : "production_geofence_exit"
                )
            }
        }
#endif
        onGeofenceWake()
    }

    private func recordSnapshotForValidation() {
#if DEBUG
        guard BackgroundValidationHarness.isEnabled else { return }
        let snapshot = generationAdapter.snapshot
        let codes = snapshot.failedCodes
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\($0.value)" }
            .joined(separator: ",")
        Task {
            await BackgroundValidationRecorder.shared.record(
                "production_geofence_monitoring_snapshot",
                details: [
                    "syncGeneration": String(snapshot.syncGeneration),
                    "requested": String(snapshot.requestedCount),
                    "confirmed": String(snapshot.confirmedCount),
                    "failed": String(snapshot.failedCount),
                    "failureCodes": codes,
                    "omitted": String(snapshot.omittedCount),
                    "pending": String(snapshot.pendingCount),
                    "confirmationState": snapshot.confirmationState.rawValue,
                    "inheritedUnknown": String(snapshot.inheritedUnknownCount)
                ]
            )
        }
#endif
    }
}

/// Boundary mínimo para o `CLLocationManager` real. O adapter de geração só enxerga esta representação
/// efêmera e pode ser testado com um fake; o `CLLocationManager` continua criado cedo no launch candidato.
@MainActor
private final class CoreLocationGeofenceNativeAdapter: GeofenceNativeRegionMonitoring {
    private let manager: CLLocationManager
    private var startedByIdentifier: [String: CLCircularRegion] = [:]

    init(manager: CLLocationManager) {
        self.manager = manager
    }

    func monitoredRegions() -> [GeofenceNativeRegion] {
        manager.monitoredRegions.map(GeofenceNativeRegion.init(region:))
    }

    func stopMonitoring(identifier: String) {
        if let monitored = manager.monitoredRegions.first(where: { $0.identifier == identifier }) {
            manager.stopMonitoring(for: monitored)
        } else if let started = startedByIdentifier[identifier] {
            manager.stopMonitoring(for: started)
        }
        startedByIdentifier.removeValue(forKey: identifier)
    }

    func startMonitoring(_ region: GeofenceNativeRegion) {
        guard let centerLat = region.centerLat,
              let centerLng = region.centerLng,
              let radius = region.radiusMeters
        else { return }
        let nativeRegion = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
            radius: radius,
            identifier: region.identifier
        )
        nativeRegion.notifyOnEntry = true
        nativeRegion.notifyOnExit = true
        startedByIdentifier[region.identifier] = nativeRegion
        manager.startMonitoring(for: nativeRegion)
    }

    func requestState(for identifier: String) {
        if let monitored = manager.monitoredRegions.first(where: { $0.identifier == identifier }) {
            manager.requestState(for: monitored)
        } else if let started = startedByIdentifier[identifier] {
            // O callback `didStart` pode chegar antes de `monitoredRegions` refletir o novo registro; a mesma
            // instância circular ainda é válida para pedir INITIAL_TRIGGER_ENTER após a confirmação.
            manager.requestState(for: started)
        }
    }
}

private extension GeofenceNativeRegion {
    init(region: CLRegion) {
        if let circularRegion = region as? CLCircularRegion {
            self.init(
                identifier: circularRegion.identifier,
                centerLat: circularRegion.center.latitude,
                centerLng: circularRegion.center.longitude,
                radiusMeters: circularRegion.radius
            )
        } else {
            self.init(identifier: region.identifier, centerLat: nil, centerLng: nil, radiusMeters: nil)
        }
    }
}
