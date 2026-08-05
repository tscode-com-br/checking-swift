import CoreLocation

/// Fallback real de produção para deslocamentos que não resultem em callback de geofence. O manager e o
/// delegate nascem junto com `AppEnvironment`, antes do fim do launch, para que um relançamento frio possa
/// reinstalar o serviço e receber o primeiro evento pendente.
@MainActor
final class CLLocationManagerSignificantChangeMonitor: NSObject, SignificantLocationMonitoring, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private let activityLogger: any ActivityLogging
    private let clock: any Clock
    private let samplePolicy: LocationSamplePolicy
    private let monitoringAvailable: @MainActor () -> Bool
    private let startMonitoringAction: @MainActor (CLLocationManager) -> Void
    private let stopMonitoringAction: @MainActor (CLLocationManager) -> Void
    private let onSignificantLocationWake: SignificantLocationWakeHandler
    private var active = false

    init(
        activityLogger: any ActivityLogging,
        startsImmediately: Bool,
        clock: any Clock = SystemClock(),
        samplePolicy: LocationSamplePolicy = .candidateTrial,
        monitoringAvailable: @escaping @MainActor () -> Bool = {
            CLLocationManager.significantLocationChangeMonitoringAvailable()
        },
        startMonitoringAction: @escaping @MainActor (CLLocationManager) -> Void = {
            $0.startMonitoringSignificantLocationChanges()
        },
        stopMonitoringAction: @escaping @MainActor (CLLocationManager) -> Void = {
            $0.stopMonitoringSignificantLocationChanges()
        },
        onSignificantLocationWake: @escaping SignificantLocationWakeHandler
    ) {
        self.activityLogger = activityLogger
        self.clock = clock
        self.samplePolicy = samplePolicy
        self.monitoringAvailable = monitoringAvailable
        self.startMonitoringAction = startMonitoringAction
        self.stopMonitoringAction = stopMonitoringAction
        self.onSignificantLocationWake = onSignificantLocationWake
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
        if startsImmediately { startMonitoring() }
    }

    func start() async { startMonitoring() }

    func stop() async {
        guard active else { return }
        stopMonitoringAction(manager)
        active = false
#if DEBUG
        if BackgroundValidationHarness.isEnabled {
            Task { await BackgroundValidationRecorder.shared.record("production_significant_monitor_stopped") }
        }
#endif
    }

    func isActive() async -> Bool { active }

    var isDelegateActiveForTest: Bool { manager.delegate === self }

    private func startMonitoring() {
        guard !active else { return }
        guard monitoringAvailable() else {
            activityLogger.logWarning("Significant location monitoring unavailable on this device.")
            return
        }
        startMonitoringAction(manager)
        active = true
#if DEBUG
        if BackgroundValidationHarness.isEnabled {
            Task { await BackgroundValidationRecorder.shared.record("production_significant_monitor_started") }
        }
#endif
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // `CLLocation` não cruza o boundary de atores. Somente o valor imutável/Sendable do domínio segue
        // para o MainActor; matching e decisão continuam fora do delegate.
        let samples = locations.map(Self.makeSample)
        Task { @MainActor [weak self, samples] in
            self?.handleSignificantLocations(samples)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let errorCategory = Self.sanitizedCoreLocationErrorCategory(error)
        Task { @MainActor [weak self] in
            self?.activityLogger.logWarning("Significant location monitoring failed.")
#if DEBUG
            if BackgroundValidationHarness.isEnabled {
                await BackgroundValidationRecorder.shared.record(
                    "production_significant_location_error",
                    // O recorder aceita apenas categorias fechadas em `errorCode`, nunca texto bruto.
                    details: ["errorCode": errorCategory.rawValue]
                )
            }
#endif
        }
    }

    private func handleSignificantLocations(_ samples: [LocationSample]) {
        guard active else { return }
        guard !samples.isEmpty else {
#if DEBUG
            AppLog.location.debug("Significant location callback ignored: empty batch.")
#endif
            return
        }

        let receivedAt = clock.now()
        // O monitor ainda não conhece o threshold remoto. `Int.max` torna a seleção estritamente de
        // transporte: a policy elimina amostras inválidas/stale/futuras e ordena as demais por precisão e
        // timestamp. O threshold real é aplicado novamente pelo orquestrador/provider/use-case.
        let seed = samples.reduce(nil as LocationSample?) { current, candidate in
            samplePolicy.preferredSeed(
                current: current,
                candidate: candidate,
                now: receivedAt,
                requiredAccuracyMeters: .max
            )
        }

        activityLogger.logLocation("Significant location change received.", nil, .info)
#if DEBUG
        if BackgroundValidationHarness.isEnabled {
            Task { await BackgroundValidationRecorder.shared.record("production_significant_location") }
        }
#endif
        onSignificantLocationWake(seed)
    }

    nonisolated private static func makeSample(_ location: CLLocation) -> LocationSample {
        LocationSample(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracyMeters: location.horizontalAccuracy,
            capturedAt: location.timestamp,
            source: .significantChange
        )
    }

    nonisolated static func sanitizedCoreLocationErrorCategory(
        _ error: Error
    ) -> EvaluationCoreLocationErrorCategory {
        let nsError = error as NSError
        guard nsError.domain == kCLErrorDomain else { return .unknown }
        return EvaluationCoreLocationErrorCategory.classify(code: nsError.code)
    }

    func simulateSignificantLocationsForTest(_ locations: [CLLocation]) {
        handleSignificantLocations(locations.map(Self.makeSample))
    }
}
