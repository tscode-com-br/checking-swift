#if DEBUG
import CoreLocation
import Foundation
import UIKit

/// Instrumentação exclusiva de Debug para a prova técnica da Fase 2 no iOS Simulator.
///
/// Ela não participa da lógica de produção. O script `scripts/validate_background_simulator.sh` ativa
/// o harness com `--background-validation`, move a localização simulada e lê o relatório JSON gravado
/// no container do app.
@MainActor
final class BackgroundValidationHarness: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundValidationHarness()
    static let enableArgument = "--background-validation"
    static let disableArgument = "--disable-background-validation"
    private static let enabledPreference = "debug.background_validation.enabled"
    private static let syntheticRegionPreference = "debug.background_validation.synthetic_region"
    private static let continuousLocationPreference = "debug.background_validation.continuous_location"

    static let regionIdentifier = "debug.background-validation.singapore"
    static let regionCenter = CLLocationCoordinate2D(latitude: 1.3521, longitude: 103.8198)
    static let regionRadius: CLLocationDistance = 250

    private let manager = CLLocationManager()

    static func configure(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        let defaults = UserDefaults.standard
        if arguments.contains(disableArgument) {
            defaults.set(false, forKey: enabledPreference)
            return false
        }
        if arguments.contains(enableArgument) {
            defaults.set(true, forKey: enabledPreference)
            return true
        }
        return defaults.bool(forKey: enabledPreference)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledPreference)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledPreference)
    }

    /// Mantém o tipo do ensaio entre relançamentos. O default `true` preserva o fluxo do Simulator;
    /// a tela de aparelho físico grava `false` antes de iniciar a sessão.
    static var includesSyntheticRegion: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: syntheticRegionPreference) != nil else { return true }
        return defaults.bool(forKey: syntheticRegionPreference)
    }

    static var usesContinuousLocation: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: continuousLocationPreference) != nil else { return true }
        return defaults.bool(forKey: continuousLocationPreference)
    }

    override init() {
        super.init()
        manager.delegate = self
    }

    func start(
        resetReport: Bool,
        includeSyntheticRegion: Bool = true,
        useContinuousLocation: Bool = true
    ) async {
        Self.setEnabled(true)
        UserDefaults.standard.set(includeSyntheticRegion, forKey: Self.syntheticRegionPreference)
        UserDefaults.standard.set(useContinuousLocation, forKey: Self.continuousLocationPreference)
        if resetReport {
            await BackgroundValidationRecorder.shared.reset()
        }
        await record("harness_started", [
            "authorization": authorizationLabel(manager.authorizationStatus),
            "accuracy": accuracyLabel(manager.accuracyAuthorization),
            "monitoringAvailable": String(CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self))
        ])

        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 1
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true

        for monitored in manager.monitoredRegions where monitored.identifier == Self.regionIdentifier {
            manager.stopMonitoring(for: monitored)
        }
        if includeSyntheticRegion {
            let region = CLCircularRegion(
                center: Self.regionCenter,
                radius: Self.regionRadius,
                identifier: Self.regionIdentifier
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
        manager.startMonitoringSignificantLocationChanges()
        if useContinuousLocation {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
        UIApplication.shared.registerForRemoteNotifications()

        await record("location_services_started", [
            "continuous": String(useContinuousLocation),
            "significantChanges": "true",
            "geofence": includeSyntheticRegion ? Self.regionIdentifier : "production-regions"
        ])
    }

    func stop() async {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        for region in manager.monitoredRegions where region.identifier == Self.regionIdentifier {
            manager.stopMonitoring(for: region)
        }
        Self.setEnabled(false)
        await record("harness_stopped")
    }

    func recordLifecycle(_ kind: String) {
        Task { await record(kind) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in
            await self?.record("location_update", [
                "latitude": String(format: "%.6f", location.coordinate.latitude),
                "longitude": String(format: "%.6f", location.coordinate.longitude),
                "accuracyMeters": String(format: "%.2f", location.horizontalAccuracy)
            ])
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let identifier = region.identifier
        Task { @MainActor [weak self] in
            await self?.record("geofence_enter", ["region": identifier])
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let identifier = region.identifier
        Task { @MainActor [weak self] in
            await self?.record("geofence_exit", ["region": identifier])
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        manager.requestState(for: region)
        let identifier = region.identifier
        Task { @MainActor [weak self] in
            await self?.record("geofence_monitoring_started", ["region": identifier])
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didDetermineState state: CLRegionState,
        for region: CLRegion
    ) {
        let label: String
        switch state {
        case .inside: label = "inside"
        case .outside: label = "outside"
        case .unknown: label = "unknown"
        @unknown default: label = "future"
        }
        let identifier = region.identifier
        Task { @MainActor [weak self] in
            await self?.record("geofence_state", ["region": identifier, "state": label])
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = authorizationLabel(manager.authorizationStatus)
        let accuracy = accuracyLabel(manager.accuracyAuthorization)
        Task { @MainActor [weak self] in
            await self?.record("authorization_changed", ["authorization": authorization, "accuracy": accuracy])
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        monitoringDidFailFor region: CLRegion?,
        withError error: Error
    ) {
        let identifier = region?.identifier ?? "none"
        let errorDescription = String(describing: error)
        Task { @MainActor [weak self] in
            await self?.record("geofence_error", [
                "region": identifier,
                "error": errorDescription
            ])
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            await self?.record("location_error", ["error": String(describing: error)])
        }
    }

    private func record(_ kind: String, _ details: [String: String] = [:]) async {
        var enriched = details
        enriched["applicationState"] = applicationStateLabel(UIApplication.shared.applicationState)
        await BackgroundValidationRecorder.shared.record(kind, details: enriched)
    }

    private nonisolated func authorizationLabel(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedAlways: "always"
        case .authorizedWhenInUse: "whenInUse"
        @unknown default: "future"
        }
    }

    private nonisolated func accuracyLabel(_ authorization: CLAccuracyAuthorization) -> String {
        switch authorization {
        case .fullAccuracy: "full"
        case .reducedAccuracy: "reduced"
        @unknown default: "future"
        }
    }

    private func applicationStateLabel(_ state: UIApplication.State) -> String {
        switch state {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "future"
        }
    }
}

struct BackgroundValidationEvent: Codable, Sendable {
    let sequence: Int
    let timestamp: Date
    let kind: String
    let details: [String: String]
}

struct BackgroundValidationReport: Codable, Sendable {
    let schemaVersion: Int
    let startedAt: Date
    var events: [BackgroundValidationEvent]
}

actor BackgroundValidationRecorder {
    static let shared = BackgroundValidationRecorder()
    static let fileName = "background-validation.json"

    private let fileURL: URL
    private var report: BackgroundValidationReport

    init(fileURL: URL = BackgroundValidationRecorder.reportURL()) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let persisted = try? decoder.decode(BackgroundValidationReport.self, from: data) {
            report = persisted
        } else {
            report = BackgroundValidationReport(schemaVersion: 1, startedAt: Date(), events: [])
        }
    }

    func reset() {
        report = BackgroundValidationReport(schemaVersion: 1, startedAt: Date(), events: [])
        persist()
    }

    func record(_ kind: String, details: [String: String] = [:]) {
        report.events.append(BackgroundValidationEvent(
            sequence: report.events.count + 1,
            timestamp: Date(),
            kind: kind,
            details: details
        ))
        persist()
    }

    func snapshot() -> BackgroundValidationReport { report }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.background.error("Background validation report write failed: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated static func reportURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }
}
#endif
