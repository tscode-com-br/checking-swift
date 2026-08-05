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
            // O relatório é exportável; ele só precisa saber qual modo foi armado, nunca o identifier físico.
            "geofenceMode": includeSyntheticRegion ? "synthetic" : "production"
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
                "accuracyBucket": self?.accuracyBucket(location.horizontalAccuracy) ?? "unknown"
            ])
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor [weak self] in
            await self?.record("geofence_enter")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor [weak self] in
            await self?.record("geofence_exit")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        manager.requestState(for: region)
        Task { @MainActor [weak self] in
            await self?.record("geofence_monitoring_started")
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
        Task { @MainActor [weak self] in
            await self?.record("geofence_state", ["state": label])
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
        let code = GeofenceMonitoringFailureCode.sanitizeCoreLocationError(error).rawValue
        Task { @MainActor [weak self] in
            await self?.record("geofence_error", [
                "errorCode": code
            ])
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = GeofenceMonitoringFailureCode.sanitizeCoreLocationError(error).rawValue
        Task { @MainActor [weak self] in
            await self?.record("location_error", ["errorCode": code])
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

    private func accuracyBucket(_ accuracy: CLLocationAccuracy) -> String {
        guard accuracy.isFinite, accuracy >= 0 else { return "unknown" }
        return switch accuracy {
        case ..<20: "under20"
        case ..<100: "20to100"
        default: "over100"
        }
    }
}

struct BackgroundValidationEvent: Codable, Equatable, Sendable {
    let sequence: Int
    let timestamp: Date
    let kind: String
    let details: [String: String]
}

struct BackgroundValidationReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let startedAt: Date
    var events: [BackgroundValidationEvent]
}

actor BackgroundValidationRecorder {
    static let shared = BackgroundValidationRecorder()
    static let fileName = "background-validation.json"
    static let maximumEvents = DurableEvaluationJournal.maxRecords
    static let retentionInterval = DurableEvaluationJournal.retentionInterval
    static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication
    private static let currentSchemaVersion = 2

    private let fileURL: URL
    private let clock: any Clock
    private let maximumEvents: Int
    private let retentionInterval: TimeInterval
    private var report: BackgroundValidationReport
    /// Depois de um wipe, callbacks Debug que já estavam enfileirados não podem recriar o arquivo. Um novo
    /// ensaio passa por `reset()` e reabre explicitamente a gravação.
    private var isRecordingEnabled = true
    /// O nome do evento também é persistido; mantê-lo fechado impede que um call-site codifique por engano
    /// um identifier/local nele, contornando a barreira aplicada aos details.
    private static let allowedEventKinds: Set<String> = [
        "after_relaunch", "apns_device_token_received", "application_did_become_active",
        "application_did_enter_background", "application_launched", "authorization_changed",
        "automatic_activities_gate", "before_relaunch", "bg_app_refresh_completed",
        "bg_app_refresh_started", "bg_processing_completed", "bg_processing_started",
        "bg_task_pending_requests", "bg_task_registration", "geofence", "geofence_enter",
        "geofence_error", "geofence_exit", "geofence_monitoring_started", "geofence_state",
        "harness_started", "harness_stopped", "legacy", "location_error", "location_services_started",
        "location_update", "production_geofence_enter", "production_geofence_exit",
        "production_geofence_monitoring_snapshot", "production_significant_location",
        "production_significant_location_error", "production_significant_monitor_started",
        "production_significant_monitor_status", "production_significant_monitor_stopped",
        "recovered", "remote_notification_received", "scene_phase_active", "scene_phase_background",
        "scene_phase_future", "scene_phase_inactive"
    ]

    /// A barreira final do report Debug impede que um novo call-site volte a persistir correlação de região,
    /// coordenadas, local ou texto de erro. Códigos fechados como `errorCode` continuam permitidos.
    private static let forbiddenDetailKeys: Set<String> = [
        "region", "identifier", "local", "latitude", "longitude", "coordinate", "lat", "lng", "lon", "error"
    ]
    /// O report tem schema fechado: um call-site novo não consegue introduzir um campo arbitrário de
    /// correlação/diagnóstico sem também passar pela revisão deste boundary.
    private static let allowedDetailKeys: Set<String> = [
        "active", "accuracy", "accuracybucket", "applicationstate", "authorization", "bytecount",
        "confirmationstate", "confirmed", "continuous", "count", "enabled",
        "errorcode", "failed", "failurecodes", "geofencemode", "hasprocessing", "hasrefresh",
        "hasvalidationmarker", "inheritedunknown", "locationlaunch", "monitoringavailable", "omitted",
        "pending", "processing", "projectconfigured", "refresh", "refreshsubmission", "requested",
        "scenephase", "significantchanges", "state", "success", "syncgeneration"
    ]
    private static let booleanDetailKeys: Set<String> = [
        "active", "continuous", "enabled", "hasprocessing", "hasrefresh", "hasvalidationmarker",
        "locationlaunch", "monitoringavailable", "processing", "projectconfigured", "refresh",
        "significantchanges", "success"
    ]
    private static let unsignedIntegerDetailKeys: Set<String> = [
        "bytecount", "confirmed", "count", "failed", "inheritedunknown", "omitted", "pending",
        "requested", "syncgeneration"
    ]
    private static let allowedValuesByDetailKey: [String: Set<String>] = [
        "accuracy": ["full", "reduced", "future"],
        "accuracybucket": ["under20", "20to100", "over100", "unknown"],
        "applicationstate": ["active", "inactive", "background", "future"],
        "authorization": ["notDetermined", "restricted", "denied", "always", "whenInUse", "future"],
        "confirmationstate": [
            "notRequested", "requested", "partiallyConfirmed", "confirmed", "failed",
            "confirmationUncertain"
        ],
        "geofencemode": ["synthetic", "production"],
        "refreshsubmission": ["scheduled", "unavailable", "rejected"],
        "scenephase": ["active", "inactive", "background", "future"],
        "state": ["inside", "outside", "unknown", "future"]
    ]
    private static let allowedErrorCodes = Set(
        GeofenceMonitoringFailureCode.allCases.map(\.rawValue) +
            EvaluationCoreLocationErrorCategory.allCases.map(\.rawValue)
    )

    init(
        fileURL: URL = BackgroundValidationRecorder.reportURL(),
        clock: any Clock = SystemClock(),
        maximumEvents: Int = BackgroundValidationRecorder.maximumEvents,
        retentionInterval: TimeInterval = BackgroundValidationRecorder.retentionInterval
    ) {
        self.fileURL = fileURL
        self.clock = clock
        self.maximumEvents = max(1, maximumEvents)
        self.retentionInterval = max(0, retentionInterval)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let persisted = try? decoder.decode(BackgroundValidationReport.self, from: data) {
            // Um report de build anterior pode ter sido produzido antes da barreira de privacidade. Migra
            // todas as entradas no carregamento e regrava imediatamente, para que um relaunch nunca volte
            // a exportar identifiers, coordenadas, locais ou texto bruto de erro já presentes no disco.
            report = Self.sanitizedReport(
                persisted,
                now: clock.now(),
                maximumEvents: self.maximumEvents,
                retentionInterval: self.retentionInterval
            )
            Self.persist(report, to: fileURL)
        } else {
            report = Self.emptyReport(startedAt: clock.now())
        }
    }

    func reset() {
        report = Self.emptyReport(startedAt: clock.now())
        isRecordingEnabled = true
        persist()
    }

    func record(_ kind: String, details: [String: String] = [:]) {
        guard isRecordingEnabled else { return }
        let now = clock.now()
        report = Self.sanitizedReport(
            report,
            now: now,
            maximumEvents: maximumEvents,
            retentionInterval: retentionInterval
        )
        report.events.append(BackgroundValidationEvent(
            sequence: (report.events.last?.sequence ?? 0) + 1,
            timestamp: now,
            kind: Self.sanitizedKind(kind),
            details: Self.sanitizedDetails(details)
        ))
        report = Self.sanitizedReport(
            report,
            now: now,
            maximumEvents: maximumEvents,
            retentionInterval: retentionInterval
        )
        persist()
    }

    func snapshot() -> BackgroundValidationReport {
        let sanitized = Self.sanitizedReport(
            report,
            now: clock.now(),
            maximumEvents: maximumEvents,
            retentionInterval: retentionInterval
        )
        if sanitized != report {
            report = sanitized
            persist()
        }
        return report
    }

    /// O report Debug é diagnóstico local, não telemetria. Wipes removem o arquivo em vez de deixar um
    /// envelope vazio persistente; repetição e ausência do arquivo são seguras.
    func clear() {
        report = Self.emptyReport(startedAt: clock.now())
        isRecordingEnabled = false
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            // Não registrar a descrição do erro: pode carregar caminho ou detalhe do sistema.
            AppLog.background.error("Background validation report clear could not remove active file.")
            persist()
        }
    }

    private func persist() {
        Self.persist(report, to: fileURL)
    }

    private static func persist(_ report: BackgroundValidationReport, to fileURL: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: fileProtection],
                ofItemAtPath: fileURL.path
            )
        } catch {
            AppLog.background.error("Background validation report write failed.")
        }
    }

    private static func sanitizedDetails(_ details: [String: String]) -> [String: String] {
        details.filter { key, value in
            let normalized = key.lowercased()
            guard allowedDetailKeys.contains(normalized) else { return false }
            guard !forbiddenDetailKeys.contains(normalized) else { return false }
            guard isAllowedDetailValue(value, for: normalized) else { return false }
            // Estes dois campos já foram validados por whitelist de valores acima. O filtro textual abaixo
            // existe para outras chaves e, por definição, também encontraria a substring "error" em
            // `errorCode`; não o reaplicar depois da validação fechada.
            if normalized == "errorcode" || normalized == "failurecodes" { return true }
            return !normalized.contains("region") &&
                !normalized.contains("identifier") &&
                !normalized.contains("latitude") &&
                !normalized.contains("longitude") &&
                !normalized.contains("coordinate") &&
                !normalized.contains("error")
        }
    }

    /// Chave permitida não basta: valores livres sob `state`, `authorization` etc. também poderiam carregar
    /// um local/ID/erro. O report aceita somente booleanos, contagens e enumerações fechadas já produzidos
    /// pelos call-sites; qualquer valor novo precisa ser aprovado aqui.
    private static func isAllowedDetailValue(_ value: String, for key: String) -> Bool {
        if booleanDetailKeys.contains(key) { return value == "true" || value == "false" }
        if unsignedIntegerDetailKeys.contains(key) { return UInt64(value) != nil }
        if key == "errorcode" { return allowedErrorCodes.contains(value) }
        if key == "failurecodes" { return isWhitelistedFailureCodes(value) }
        return allowedValuesByDetailKey[key]?.contains(value) == true
    }

    private static func sanitizedReport(
        _ report: BackgroundValidationReport,
        now: Date,
        maximumEvents: Int,
        retentionInterval: TimeInterval
    ) -> BackgroundValidationReport {
        let cutoff = now.addingTimeInterval(-retentionInterval)
        let retained = report.events.filter { $0.timestamp >= cutoff }
        let bounded = Array(retained.suffix(max(1, maximumEvents)))
        return BackgroundValidationReport(
            schemaVersion: currentSchemaVersion,
            // A data inicial também não deve sobreviver à janela de retenção quando já não há evento
            // daquele ensaio. Timestamps continuam locais e só deixam o aparelho por ação explícita.
            startedAt: report.startedAt >= cutoff ? report.startedAt : (bounded.first?.timestamp ?? now),
            events: bounded.enumerated().map { index, event in
                BackgroundValidationEvent(
                    sequence: index + 1,
                    timestamp: event.timestamp,
                    kind: sanitizedKind(event.kind),
                    details: sanitizedDetails(event.details)
                )
            }
        )
    }

    private static func emptyReport(startedAt: Date) -> BackgroundValidationReport {
        BackgroundValidationReport(
            schemaVersion: currentSchemaVersion,
            startedAt: startedAt,
            events: []
        )
    }

    private static func sanitizedKind(_ kind: String) -> String {
        allowedEventKinds.contains(kind) ? kind : "sanitized"
    }

    private static func isWhitelistedFailureCodes(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }
        return value.split(separator: ",").allSatisfy { entry in
            let components = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2,
                  GeofenceMonitoringFailureCode(rawValue: String(components[0])) != nil,
                  let count = Int(components[1]), count >= 0
            else { return false }
            return true
        }
    }

    nonisolated static func reportURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }
}
#endif
