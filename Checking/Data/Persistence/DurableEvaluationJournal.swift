import Foundation

/// Journal técnico separado de `checking_activity.sqlite`. O initializer não toca o disco; todo I/O ocorre
/// de forma serializada dentro do actor, no primeiro comando aguardado.
actor DurableEvaluationJournal: EvaluationJournaling {
    static let schemaVersion = 1
    static let maxRecords = 500
    static let retentionDays = 30
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication
    static let directoryName = "BackgroundReliability"
    static let fileName = "evaluation-journal-v1.json"
    static let maximumFileSizeBytes: UInt64 = 2 * 1_024 * 1_024

    private struct Envelope: Codable, Equatable, Sendable {
        let schemaVersion: Int
        var nextSequence: UInt64
        var records: [EvaluationRecord]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case nextSequence = "next_sequence"
            case records
        }
    }

    private struct SchemaProbe: Decodable {
        let schemaVersion: Int

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
        }
    }

    private let fileURL: URL
    private let clock: any Clock
    private let processID: EvaluationProcessID
    private let maxRecords: Int
    private let retentionInterval: TimeInterval
    private var envelope: Envelope?
    private var needsPersistenceRetry = false

    init(
        fileURL: URL,
        clock: any Clock,
        processID: EvaluationProcessID = EvaluationProcessID(),
        maxRecords: Int = DurableEvaluationJournal.maxRecords,
        retentionInterval: TimeInterval = DurableEvaluationJournal.retentionInterval
    ) {
        self.fileURL = fileURL
        self.clock = clock
        self.processID = processID
        self.maxRecords = max(1, maxRecords)
        self.retentionInterval = max(0, retentionInterval)
    }

    nonisolated static func liveFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    func begin(_ start: EvaluationStart) async {
        guard ensureLoaded() else { return }
        retryPersistenceIfNeeded()
        guard var current = envelope else { return }
        let now = clock.now()
        var changed = applyRetention(to: &current, now: now)

        if let index = current.records.firstIndex(where: { $0.evaluationID == start.id }) {
            guard current.records[index].isStarted else {
                AppLog.background.error("Evaluation journal ignored begin after terminal.")
                envelope = current
                if changed { persistCurrentEnvelope() }
                return
            }
            let previous = current.records[index]
            current.records[index].merge(start)
            changed = changed || current.records[index] != previous
        } else {
            guard current.nextSequence < UInt64.max else {
                AppLog.background.error("Evaluation journal sequence exhausted.")
                envelope = current
                if changed { persistCurrentEnvelope() }
                return
            }
            let record = EvaluationRecord(
                schemaVersion: Self.schemaVersion,
                evaluationID: start.id,
                processID: processID,
                sequence: current.nextSequence,
                startedAt: now,
                finishedAt: nil,
                trigger: start.trigger,
                wakes: EvaluationWakeCounts(primary: start.primaryWake),
                stage: start.stage,
                appState: start.appState,
                launchState: start.launchState,
                permissionMode: start.permissionMode,
                accuracyMode: start.accuracyMode,
                backgroundRefresh: start.backgroundRefresh,
                lowPowerMode: start.lowPowerMode,
                monitors: start.monitors,
                locationSource: start.locationSource,
                captureReused: start.captureReused,
                accuracyBucket: start.accuracyBucket,
                ageBucket: start.ageBucket,
                durationBucket: nil,
                terminal: nil,
                coreLocationError: nil,
                http: nil,
                notificationScheduled: nil,
                ownerExpirations: nil
            )
            current.records.append(record)
            current.nextSequence += 1
            changed = true
        }

        changed = applyRetention(to: &current, now: now) || changed
        envelope = current
        if changed { persistCurrentEnvelope() }
    }

    func coalesce(_ event: EvaluationCoalescence) async {
        guard ensureLoaded() else { return }
        retryPersistenceIfNeeded()
        guard var current = envelope,
              let index = current.records.firstIndex(where: { $0.evaluationID == event.evaluationID })
        else {
            AppLog.background.error("Evaluation journal ignored coalescence for missing evaluation.")
            return
        }
        guard current.records[index].isStarted else {
            AppLog.background.error("Evaluation journal ignored coalescence after terminal.")
            return
        }

        let didIncrement: Bool
        if let targetCount = event.targetCount {
            didIncrement = current.records[index].wakes.ensureCount(
                event.wake,
                atLeast: targetCount
            )
        } else {
            didIncrement = current.records[index].wakes.increment(
                event.wake,
                by: event.count
            )
        }
        let previousStage = current.records[index].stage
        let previousTrigger = current.records[index].trigger
        if let effectiveTrigger = event.effectiveTrigger {
            current.records[index].trigger =
                current.records[index].trigger.promoted(with: effectiveTrigger)
        }
        if let stage = event.stage {
            current.records[index].stage = .furthest(previousStage, stage)
        }
        guard didIncrement
                || current.records[index].stage != previousStage
                || current.records[index].trigger != previousTrigger else { return }
        envelope = current
        persistCurrentEnvelope()
    }

    func advance(_ progress: EvaluationProgress) async {
        guard ensureLoaded() else { return }
        retryPersistenceIfNeeded()
        guard var current = envelope,
              let index = current.records.firstIndex(where: {
                  $0.evaluationID == progress.evaluationID
              })
        else {
            AppLog.background.error("Evaluation journal ignored progress for missing evaluation.")
            return
        }
        guard current.records[index].isStarted else {
            AppLog.background.error("Evaluation journal ignored progress after terminal.")
            return
        }

        let previousStage = current.records[index].stage
        let previousTrigger = current.records[index].trigger
        current.records[index].stage = .furthest(previousStage, progress.stage)
        if let effectiveTrigger = progress.effectiveTrigger {
            current.records[index].trigger =
                current.records[index].trigger.promoted(with: effectiveTrigger)
        }
        guard current.records[index].stage != previousStage
                || current.records[index].trigger != previousTrigger else { return }
        envelope = current
        persistCurrentEnvelope()
    }

    func recordOwnerExpiration(
        evaluationID: EvaluationID,
        owner: EvaluationJournalOwnerKind,
        cancelledCanonicalWork: Bool
    ) async {
        guard ensureLoaded() else { return }
        retryPersistenceIfNeeded()
        guard var current = envelope,
              let index = current.records.firstIndex(where: {
                  $0.evaluationID == evaluationID
              })
        else {
            AppLog.background.error("Evaluation journal ignored owner expiration for missing evaluation.")
            return
        }

        // Expiração pode vencer a corrida imediatamente antes ou depois de `finish`; por isso o update
        // é aceito também em record terminal. Flags monotônicos tornam chamadas repetidas idempotentes.
        guard current.records[index].recordOwnerExpiration(
            owner: owner,
            cancelledCanonicalWork: cancelledCanonicalWork
        ) else { return }
        envelope = current
        persistCurrentEnvelope()
    }

    func finish(id: EvaluationID, terminal: EvaluationTerminal) async {
        guard ensureLoaded() else { return }
        retryPersistenceIfNeeded()
        guard var current = envelope,
              let index = current.records.firstIndex(where: { $0.evaluationID == id })
        else {
            AppLog.background.error("Evaluation journal ignored terminal for missing evaluation.")
            return
        }
        guard current.records[index].isStarted else {
            AppLog.background.error("Evaluation journal ignored duplicate terminal.")
            return
        }

        current.records[index].apply(terminal, finishedAt: clock.now())
        envelope = current
        persistCurrentEnvelope()
    }

    func reconcileOrphans() async {
        guard ensureLoaded() else { return }
        retryPersistenceIfNeeded()
        guard var current = envelope else { return }
        let now = clock.now()
        var changed = applyRetention(to: &current, now: now)
        for index in current.records.indices
        where current.records[index].isStarted && current.records[index].processID != processID {
            current.records[index].apply(
                EvaluationTerminal(outcome: .abandoned, durationBucket: .unknown),
                finishedAt: now
            )
            changed = true
        }
        envelope = current
        if changed { persistCurrentEnvelope() }
    }

    func recent(limit: Int) async -> [EvaluationRecord] {
        guard ensureLoaded() else { return [] }
        retryPersistenceIfNeeded()
        guard var current = envelope else { return [] }
        let changed = applyRetention(to: &current, now: clock.now())
        envelope = current
        if changed { persistCurrentEnvelope() }
        let boundedLimit = min(max(0, limit), maxRecords)
        guard boundedLimit > 0 else { return [] }
        return Array(current.records.sorted(by: Self.isOlder).suffix(boundedLimit).reversed())
    }

    func clear() async {
        envelope = Envelope(schemaVersion: Self.schemaVersion, nextSequence: 1, records: [])
        needsPersistenceRetry = false
        let fileManager = FileManager.default
        var activeRemovalFailed = false

        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                activeRemovalFailed = true
                AppLog.background.error("Evaluation journal clear could not remove active file.")
            }
        }

        // Se a remoção falhou, uma substituição atômica vazia é a segunda tentativa best-effort de wipe.
        if activeRemovalFailed { persistCurrentEnvelope() }
    }

    // MARK: - Loading and validation

    /// `false` representa leitura temporariamente indisponível (por exemplo, antes do primeiro unlock).
    /// Nesse estado não sobrescrevemos o arquivo protegido e a próxima chamada tenta novamente.
    private func ensureLoaded() -> Bool {
        if envelope != nil { return true }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            envelope = Envelope(schemaVersion: Self.schemaVersion, nextSequence: 1, records: [])
            return true
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            if let size = attributes[.size] as? NSNumber,
               size.uint64Value > Self.maximumFileSizeBytes {
                return recoverInvalidFile(reason: .oversized)
            }
        } catch {
            AppLog.background.error("Evaluation journal metadata unavailable; preserving existing file.")
            return false
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            AppLog.background.error("Evaluation journal read unavailable; preserving existing file.")
            return false
        }

        let decoder = Self.makeDecoder()
        guard let probe = try? decoder.decode(SchemaProbe.self, from: data) else {
            return recoverInvalidFile(reason: .corrupt)
        }
        guard probe.schemaVersion == Self.schemaVersion else {
            return recoverInvalidFile(reason: .unsupportedSchema)
        }
        guard var decoded = try? decoder.decode(Envelope.self, from: data),
              validate(decoded)
        else {
            return recoverInvalidFile(reason: .corrupt)
        }

        let changed = applyRetention(to: &decoded, now: clock.now())
        envelope = decoded
        if changed { persistCurrentEnvelope() }
        return true
    }

    private enum RecoveryReason {
        case corrupt
        case unsupportedSchema
        case oversized
    }

    private func recoverInvalidFile(reason: RecoveryReason) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            // Não sobrescreve um blob desconhecido quando a remoção segura falha.
            AppLog.background.error("Evaluation journal could not replace invalid representation.")
            return false
        }

        switch reason {
        case .corrupt:
            AppLog.background.error("Evaluation journal replaced corrupt schema.")
        case .unsupportedSchema:
            AppLog.background.error("Evaluation journal replaced unsupported schema.")
        case .oversized:
            AppLog.background.error("Evaluation journal replaced oversized representation.")
        }
        envelope = Envelope(schemaVersion: Self.schemaVersion, nextSequence: 1, records: [])
        persistCurrentEnvelope()
        return true
    }

    private func validate(_ candidate: Envelope) -> Bool {
        guard candidate.schemaVersion == Self.schemaVersion,
              candidate.nextSequence > 0,
              candidate.records.count <= maxRecords
        else { return false }

        let ids = Set(candidate.records.map(\.evaluationID))
        let sequences = Set(candidate.records.map(\.sequence))
        guard ids.count == candidate.records.count,
              sequences.count == candidate.records.count,
              candidate.records.allSatisfy({
                  $0.schemaVersion == Self.schemaVersion
                      && $0.sequence > 0
                      && $0.wakes.isValid
                      && (($0.terminal == nil) == ($0.finishedAt == nil))
                      && ($0.http?.status.map { (100 ... 599).contains($0) } ?? true)
                      && ($0.ownerExpirations?.isValid ?? true)
              })
        else { return false }

        let maximumSequence = candidate.records.map(\.sequence).max() ?? 0
        return candidate.nextSequence > maximumSequence
    }

    // MARK: - Retention and persistence

    @discardableResult
    private func applyRetention(to candidate: inout Envelope, now: Date) -> Bool {
        let original = candidate.records
        let cutoff = now.addingTimeInterval(-retentionInterval)
        candidate.records.removeAll { $0.startedAt < cutoff }
        candidate.records.sort(by: Self.isOlder)
        if candidate.records.count > maxRecords {
            candidate.records = Array(candidate.records.suffix(maxRecords))
        }
        return candidate.records != original
    }

    private nonisolated static func isOlder(_ lhs: EvaluationRecord, _ rhs: EvaluationRecord) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.sequence < rhs.sequence
    }

    private func persistCurrentEnvelope() {
        guard var current = envelope else { return }
        _ = applyRetention(to: &current, now: clock.now())
        envelope = current
        needsPersistenceRetry = true
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            applyProtectionBestEffort(to: directory)
            let data = try Self.makeEncoder().encode(current)
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            // A escrita atômica pode trocar o inode; reaplicar a proteção em toda substituição.
            applyProtectionBestEffort(to: fileURL)
            needsPersistenceRetry = false
        } catch {
            AppLog.background.error("Evaluation journal write failed.")
        }
    }

    private func retryPersistenceIfNeeded() {
        if needsPersistenceRetry { persistCurrentEnvelope() }
    }

    private func applyProtectionBestEffort(to url: URL) {
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: Self.fileProtection],
                ofItemAtPath: url.path
            )
        } catch {
            // Simulator e alguns filesystems de teste não expõem file protection.
            AppLog.background.error("Evaluation journal file protection unavailable.")
        }
    }

    private nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
