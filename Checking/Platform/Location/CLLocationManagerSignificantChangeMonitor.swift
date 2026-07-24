import CoreLocation

/// Fallback real de produção para deslocamentos que não resultem em callback de geofence. O manager e o
/// delegate nascem junto com `AppEnvironment`, antes do fim do launch, para que um relançamento frio possa
/// reinstalar o serviço e receber o primeiro evento pendente.
@MainActor
final class CLLocationManagerSignificantChangeMonitor: NSObject, SignificantLocationMonitoring, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private let activityLogger: any ActivityLogging
    private let onSignificantLocationWake: @Sendable () -> Void
    private var active = false

    init(
        activityLogger: any ActivityLogging,
        startsImmediately: Bool,
        onSignificantLocationWake: @escaping @Sendable () -> Void
    ) {
        self.activityLogger = activityLogger
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
        manager.stopMonitoringSignificantLocationChanges()
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
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else {
            activityLogger.logWarning("Significant location monitoring unavailable on this device.")
            return
        }
        manager.startMonitoringSignificantLocationChanges()
        active = true
#if DEBUG
        if BackgroundValidationHarness.isEnabled {
            Task { await BackgroundValidationRecorder.shared.record("production_significant_monitor_started") }
        }
#endif
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !locations.isEmpty else { return }
        Task { @MainActor [weak self] in self?.handleSignificantLocation() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.activityLogger.logWarning("Significant location monitoring failed.")
#if DEBUG
            if BackgroundValidationHarness.isEnabled {
                await BackgroundValidationRecorder.shared.record(
                    "production_significant_location_error",
                    details: ["error": String(describing: error)]
                )
            }
#endif
        }
    }

    private func handleSignificantLocation() {
        guard active else { return }
        activityLogger.logLocation("Significant location change received.", nil, .info)
#if DEBUG
        if BackgroundValidationHarness.isEnabled {
            Task { await BackgroundValidationRecorder.shared.record("production_significant_location") }
        }
#endif
        onSignificantLocationWake()
    }

    func simulateSignificantLocationForTest() { handleSignificantLocation() }
}
