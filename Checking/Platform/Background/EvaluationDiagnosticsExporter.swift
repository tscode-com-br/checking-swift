#if DEBUG
import Foundation

/// Exportação deliberada para o ensaio físico. O tipo inteiro fica fora de Staging/Release e não conhece
/// transporte, analytics ou ActivityLog: ele só escreve um snapshot local temporário depois da ação humana.
actor EvaluationDiagnosticsExporter {
    static let schemaVersion = 1
    static let exportDirectoryName = "checking-evaluation-diagnostics"
    static let exportFilePrefix = "evaluation-diagnostics-"

    private let journal: any EvaluationJournaling
    private let recorder: BackgroundValidationRecorder
    private let clock: any Clock
    private let temporaryDirectory: URL

    init(
        journal: any EvaluationJournaling,
        recorder: BackgroundValidationRecorder = .shared,
        clock: any Clock = SystemClock(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.journal = journal
        self.recorder = recorder
        self.clock = clock
        self.temporaryDirectory = temporaryDirectory
    }

    /// Cria o arquivo somente para uma ação explícita da tela de validação. `recent` e o recorder já são
    /// bounded; os limites são repetidos neste boundary para manter o contrato mesmo com um fake defeituoso.
    func createTemporaryExport() async -> URL? {
        let evaluationRecords = await journal.recent(limit: DurableEvaluationJournal.maxRecords)
        let validationReport = await recorder.snapshot()
        let snapshot = EvaluationDiagnosticsExportSnapshot(
            exportedAt: clock.now(),
            evaluationRecords: evaluationRecords,
            validationReport: validationReport
        )
        let directory = Self.exportDirectory(in: temporaryDirectory)
        let fileURL = directory
            .appendingPathComponent("\(Self.exportFilePrefix)\(UUID().uuidString)")
            .appendingPathExtension("json")

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: DurableEvaluationJournal.fileProtection],
                ofItemAtPath: fileURL.path
            )
            return fileURL
        } catch {
            // Erros de I/O não carregam descrição, caminho nem dados de diagnóstico para OSLog.
            Self.removeTemporaryExport(at: fileURL, temporaryDirectory: temporaryDirectory)
            return nil
        }
    }

    /// Idempotente e restrito ao diretório/nome que este exportador controla; nunca apaga uma URL fornecida
    /// pelo usuário ou outro subsistema. A tela chama no término/cancelamento do share e ao desaparecer.
    nonisolated static func removeTemporaryExport(
        at fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        let directory = exportDirectory(in: temporaryDirectory).standardizedFileURL
        let candidate = fileURL.standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory,
              candidate.pathExtension == "json",
              candidate.lastPathComponent.hasPrefix(exportFilePrefix)
        else { return }
        try? FileManager.default.removeItem(at: candidate)
    }

    nonisolated private static func exportDirectory(in temporaryDirectory: URL) -> URL {
        temporaryDirectory.appendingPathComponent(exportDirectoryName, isDirectory: true)
    }
}

/// Schema de export separado do envelope persistente: omite `evaluationID`, `processID` e `sequence` para
/// que o arquivo compartilhável não contenha identificador/correlação de avaliação, mesmo que aleatórios.
private struct EvaluationDiagnosticsExportSnapshot: Codable, Sendable {
    let schemaVersion: Int
    let exportedAt: Date
    let evaluationRecords: [EvaluationDiagnosticsExportRecord]
    let validationReport: EvaluationDiagnosticsValidationReport

    init(
        exportedAt: Date,
        evaluationRecords: [EvaluationRecord],
        validationReport: BackgroundValidationReport
    ) {
        self.schemaVersion = EvaluationDiagnosticsExporter.schemaVersion
        self.exportedAt = exportedAt
        self.evaluationRecords = evaluationRecords
            .prefix(DurableEvaluationJournal.maxRecords)
            .map(EvaluationDiagnosticsExportRecord.init)
        self.validationReport = EvaluationDiagnosticsValidationReport(validationReport)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case exportedAt = "exported_at"
        case evaluationRecords = "evaluation_records"
        case validationReport = "validation_report"
    }
}

private struct EvaluationDiagnosticsExportRecord: Codable, Sendable {
    let startedAt: Date
    let finishedAt: Date?
    let trigger: EvaluationTrigger
    let wakes: EvaluationWakeCounts
    let stage: EvaluationStage
    let appState: EvaluationApplicationState
    let launchState: EvaluationLaunchState
    let permissionMode: EvaluationPermissionMode
    let accuracyMode: EvaluationAccuracyMode
    let backgroundRefresh: EvaluationBackgroundRefreshState
    let lowPowerMode: Bool
    let monitors: EvaluationMonitorFlags
    let locationSource: EvaluationLocationSource?
    let captureReused: Bool?
    let accuracyBucket: EvaluationAccuracyBucket?
    let ageBucket: EvaluationAgeBucket?
    let durationBucket: EvaluationDurationBucket?
    let terminal: EvaluationTerminalOutcome?
    let coreLocationError: EvaluationCoreLocationErrorCategory?
    let http: EvaluationHTTPDiagnostic?
    let notificationScheduled: Bool?
    let ownerExpirations: EvaluationOwnerExpirationDiagnostics?

    init(_ record: EvaluationRecord) {
        startedAt = record.startedAt
        finishedAt = record.finishedAt
        trigger = record.trigger
        wakes = record.wakes
        stage = record.stage
        appState = record.appState
        launchState = record.launchState
        permissionMode = record.permissionMode
        accuracyMode = record.accuracyMode
        backgroundRefresh = record.backgroundRefresh
        lowPowerMode = record.lowPowerMode
        monitors = record.monitors
        locationSource = record.locationSource
        captureReused = record.captureReused
        accuracyBucket = record.accuracyBucket
        ageBucket = record.ageBucket
        durationBucket = record.durationBucket
        terminal = record.terminal
        coreLocationError = record.coreLocationError
        http = record.http
        notificationScheduled = record.notificationScheduled
        ownerExpirations = record.ownerExpirations
    }

    private enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case trigger
        case wakes
        case stage
        case appState = "app_state"
        case launchState = "launch_state"
        case permissionMode = "permission_mode"
        case accuracyMode = "accuracy_mode"
        case backgroundRefresh = "background_refresh"
        case lowPowerMode = "low_power_mode"
        case monitors
        case locationSource = "location_source"
        case captureReused = "capture_reused"
        case accuracyBucket = "accuracy_bucket"
        case ageBucket = "age_bucket"
        case durationBucket = "duration_bucket"
        case terminal
        case coreLocationError = "core_location_error"
        case http
        case notificationScheduled = "notification_scheduled"
        case ownerExpirations = "owner_expirations"
    }
}

private struct EvaluationDiagnosticsValidationReport: Codable, Sendable {
    let startedAt: Date
    let events: [EvaluationDiagnosticsValidationEvent]

    init(_ report: BackgroundValidationReport) {
        startedAt = report.startedAt
        events = report.events
            .suffix(BackgroundValidationRecorder.maximumEvents)
            .map(EvaluationDiagnosticsValidationEvent.init)
    }

    private enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case events
    }
}

private struct EvaluationDiagnosticsValidationEvent: Codable, Sendable {
    let timestamp: Date
    let kind: String
    let details: [String: String]

    init(_ event: BackgroundValidationEvent) {
        timestamp = event.timestamp
        kind = event.kind
        details = event.details
    }
}
#endif
