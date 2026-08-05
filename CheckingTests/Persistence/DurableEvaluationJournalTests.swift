import Foundation
import XCTest
@testable import Checking

final class DurableEvaluationJournalTests: XCTestCase {
    private struct TemporaryJournal {
        let root: URL
        let file: URL
    }

    private func makeTemporaryJournal() throws -> TemporaryJournal {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evaluation-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return TemporaryJournal(root: root, file: root.appendingPathComponent("journal.json"))
    }

    private func makeStore(
        _ file: URL,
        at date: Date = iso("2026-07-30T00:00:00Z"),
        processID: EvaluationProcessID = EvaluationProcessID(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        ),
        maxRecords: Int = DurableEvaluationJournal.maxRecords,
        retentionInterval: TimeInterval = DurableEvaluationJournal.retentionInterval
    ) -> DurableEvaluationJournal {
        DurableEvaluationJournal(
            fileURL: file,
            clock: FixedClock(date),
            processID: processID,
            maxRecords: maxRecords,
            retentionInterval: retentionInterval
        )
    }

    private func start(
        id: EvaluationID = EvaluationID(),
        trigger: EvaluationTrigger = .timer,
        wake: EvaluationWakeKind = .timer,
        stage: EvaluationStage = .started
    ) -> EvaluationStart {
        EvaluationStart(id: id, trigger: trigger, primaryWake: wake, stage: stage)
    }

    func test_beginThenFinish_persistsOneTerminalRecordAndProtectionPolicy() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let processID = EvaluationProcessID(
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        let id = EvaluationID(UUID(uuidString: "20000000-0000-0000-0000-000000000001")!)
        let store = makeStore(temp.file, processID: processID)

        await store.begin(start(id: id, trigger: .geofence, wake: .geofence, stage: .admitted))
        await store.finish(
            id: id,
            terminal: EvaluationTerminal(
                outcome: .submittedCheckIn,
                stage: .submitted,
                durationBucket: .oneTo5Seconds,
                notificationScheduled: true
            )
        )

        let records = await store.recent(limit: 10)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.schemaVersion, DurableEvaluationJournal.schemaVersion)
        XCTAssertEqual(record.evaluationID, id)
        XCTAssertEqual(record.processID, processID)
        XCTAssertEqual(record.sequence, 1)
        XCTAssertEqual(record.trigger, .geofence)
        XCTAssertEqual(record.wakes.geofence, 1)
        XCTAssertEqual(record.stage, .submitted)
        XCTAssertEqual(record.terminal, .submittedCheckIn)
        XCTAssertEqual(record.durationBucket, .oneTo5Seconds)
        XCTAssertEqual(record.notificationScheduled, true)
        XCTAssertNotNil(record.finishedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.file.path))
        XCTAssertEqual(
            DurableEvaluationJournal.fileProtection,
            .completeUntilFirstUserAuthentication
        )
        for protectedURL in [temp.root, temp.file] {
            let attributes = try FileManager.default.attributesOfItem(atPath: protectedURL.path)
            if let protection = attributes[.protectionKey] as? FileProtectionType {
                XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
            }
        }

        let reopened = makeStore(temp.file, processID: processID)
        let reopenedRecords = await reopened.recent(limit: 10)
        XCTAssertEqual(reopenedRecords, records)
    }

    func test_repeatedBegin_updatesOneStartedRecordAndNeverResurrectsTerminal() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let id = EvaluationID()
        let store = makeStore(temp.file)

        let initialMonitors = EvaluationMonitorFlags(
            geofence: .active,
            significantLocation: .active,
            backgroundTask: .active
        )
        await store.begin(EvaluationStart(
            id: id,
            trigger: .timer,
            primaryWake: .timer,
            stage: .admitted,
            appState: .background,
            launchState: .cold,
            permissionMode: .always,
            accuracyMode: .full,
            backgroundRefresh: .available,
            lowPowerMode: true,
            monitors: initialMonitors
        ))
        await store.begin(start(id: id, trigger: .foreground, wake: .foreground, stage: .captured))
        var records = await store.recent(limit: 10)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sequence, 1)
        XCTAssertEqual(records[0].trigger, .timer)
        XCTAssertEqual(records[0].stage, .captured)
        XCTAssertEqual(records[0].wakes.timer, 1)
        XCTAssertEqual(records[0].wakes.foreground, 1)
        XCTAssertEqual(records[0].appState, .background)
        XCTAssertEqual(records[0].launchState, .cold)
        XCTAssertEqual(records[0].permissionMode, .always)
        XCTAssertEqual(records[0].accuracyMode, .full)
        XCTAssertEqual(records[0].backgroundRefresh, .available)
        XCTAssertTrue(records[0].lowPowerMode)
        XCTAssertEqual(records[0].monitors, initialMonitors)

        await store.finish(id: id, terminal: EvaluationTerminal(outcome: .noAction))
        let bytesAfterFinish = try Data(contentsOf: temp.file)
        await store.begin(start(id: id, trigger: .geofence, wake: .geofence))
        records = await store.recent(limit: 10)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].terminal, .noAction)
        XCTAssertEqual(records[0].trigger, .timer)
        XCTAssertEqual(try Data(contentsOf: temp.file), bytesAfterFinish)
    }

    func test_duplicateFinish_firstTerminalWinsWithoutRewrite() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let id = EvaluationID()
        let store = makeStore(temp.file)

        await store.begin(start(id: id))
        await store.finish(id: id, terminal: EvaluationTerminal(outcome: .submittedCheckOut))
        let firstBytes = try Data(contentsOf: temp.file)
        let firstSnapshot = await store.recent(limit: 1)
        let firstRecord = try XCTUnwrap(firstSnapshot.first)

        await store.finish(id: id, terminal: EvaluationTerminal(outcome: .internalFailure))

        let finalSnapshot = await store.recent(limit: 1)
        let finalRecord = try XCTUnwrap(finalSnapshot.first)
        XCTAssertEqual(finalRecord.terminal, .submittedCheckOut)
        XCTAssertEqual(finalRecord.finishedAt, firstRecord.finishedAt)
        XCTAssertEqual(try Data(contentsOf: temp.file), firstBytes)
    }

    func test_ownerExpiration_beforeAndAfterFinish_isMonotonicIdempotentAndSurvivesReopen() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let processID = EvaluationProcessID()
        let id = EvaluationID()
        let missingID = EvaluationID()
        let store = makeStore(temp.file, processID: processID)

        await store.begin(start(id: id, stage: .admitted))
        let bytesBeforeMissing = try Data(contentsOf: temp.file)
        await store.recordOwnerExpiration(
            evaluationID: missingID,
            owner: .bgProcessing,
            cancelledCanonicalWork: true
        )
        XCTAssertEqual(try Data(contentsOf: temp.file), bytesBeforeMissing)

        await store.recordOwnerExpiration(
            evaluationID: id,
            owner: .bgAppRefresh,
            cancelledCanonicalWork: false
        )
        let bytesAfterFirstExpiration = try Data(contentsOf: temp.file)
        await store.recordOwnerExpiration(
            evaluationID: id,
            owner: .bgAppRefresh,
            cancelledCanonicalWork: false
        )
        XCTAssertEqual(try Data(contentsOf: temp.file), bytesAfterFirstExpiration)

        await store.finish(id: id, terminal: EvaluationTerminal(outcome: .noAction))
        await store.recordOwnerExpiration(
            evaluationID: id,
            owner: .uiBackgroundTask,
            cancelledCanonicalWork: true
        )
        let bytesAfterTerminalExpiration = try Data(contentsOf: temp.file)
        // Uma observação atrasada menos informativa nunca apaga o flag first-wins nem reescreve o JSON.
        await store.recordOwnerExpiration(
            evaluationID: id,
            owner: .uiBackgroundTask,
            cancelledCanonicalWork: false
        )
        XCTAssertEqual(try Data(contentsOf: temp.file), bytesAfterTerminalExpiration)

        let records = await store.recent(limit: 1)
        let record = try XCTUnwrap(records.first)
        let diagnostics = try XCTUnwrap(record.ownerExpirations)
        XCTAssertEqual(record.terminal, .noAction)
        XCTAssertTrue(diagnostics.isValid)
        XCTAssertTrue(diagnostics.didExpire(.bgAppRefresh))
        XCTAssertFalse(diagnostics.cancelledCanonicalWork(for: .bgAppRefresh))
        XCTAssertTrue(diagnostics.didExpire(.uiBackgroundTask))
        XCTAssertTrue(diagnostics.cancelledCanonicalWork(for: .uiBackgroundTask))
        XCTAssertFalse(diagnostics.didExpire(.bgProcessing))
        XCTAssertFalse(diagnostics.cancelledCanonicalWork(for: .bgProcessing))

        let reopened = makeStore(temp.file, processID: processID)
        let reopenedRecords = await reopened.recent(limit: 1)
        let reopenedRecord = try XCTUnwrap(reopenedRecords.first)
        XCTAssertEqual(reopenedRecord, record)
    }

    func test_schemaV1RecordWithoutOwnerExpirations_remainsReadable() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let processID = EvaluationProcessID()
        let id = EvaluationID()
        let store = makeStore(temp.file, processID: processID)

        await store.begin(start(id: id))
        await store.finish(id: id, terminal: EvaluationTerminal(outcome: .noAction))

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: temp.file)) as? [String: Any]
        )
        let serializedRecords = try XCTUnwrap(root["records"] as? [[String: Any]])
        let serializedRecord = try XCTUnwrap(serializedRecords.first)
        XCTAssertNil(serializedRecord["owner_expirations"])

        let reopened = makeStore(temp.file, processID: processID)
        let reopenedRecords = await reopened.recent(limit: 1)
        let reopenedRecord = try XCTUnwrap(reopenedRecords.first)
        XCTAssertEqual(reopenedRecord.evaluationID, id)
        XCTAssertEqual(reopenedRecord.terminal, .noAction)
        XCTAssertNil(reopenedRecord.ownerExpirations)
    }

    func test_coalesce_aggregatesOnlyTypedWakesAndStopsAfterTerminal() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let id = EvaluationID()
        let store = makeStore(temp.file)

        await store.begin(start(id: id, trigger: .geofence, wake: .geofence))
        await store.coalesce(EvaluationCoalescence(evaluationID: id, wake: .geofence))
        await store.coalesce(
            EvaluationCoalescence(
                evaluationID: id,
                wake: .significantLocation,
                stage: .captureStarted
            )
        )
        var snapshot = await store.recent(limit: 1)
        var record = try XCTUnwrap(snapshot.first)
        XCTAssertEqual(record.wakes.geofence, 2)
        XCTAssertEqual(record.wakes.significantLocation, 1)
        XCTAssertEqual(record.wakes.total, 3)
        XCTAssertEqual(record.stage, .captureStarted)

        await store.finish(id: id, terminal: EvaluationTerminal(outcome: .timeout))
        let terminalBytes = try Data(contentsOf: temp.file)
        await store.coalesce(EvaluationCoalescence(evaluationID: id, wake: .timer, stage: .submitted))
        snapshot = await store.recent(limit: 1)
        record = try XCTUnwrap(snapshot.first)
        XCTAssertEqual(record.wakes.timer, 0)
        XCTAssertEqual(record.stage, .captureStarted)
        XCTAssertEqual(try Data(contentsOf: temp.file), terminalBytes)
    }

    func test_coalescenceSnapshots_areIdempotentAndNeverDowngradeEffectiveTrigger() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let id = EvaluationID()
        let processID = EvaluationProcessID()
        let store = makeStore(temp.file, processID: processID)

        await store.begin(start(id: id, trigger: .timer, wake: .timer, stage: .admitted))
        await store.coalesce(EvaluationCoalescence(
            evaluationID: id,
            wake: .geofence,
            stage: .admitted,
            count: 1,
            targetCount: 1,
            effectiveTrigger: .geofence
        ))
        await store.coalesce(EvaluationCoalescence(
            evaluationID: id,
            wake: .significantLocation,
            stage: .admitted,
            count: 1,
            targetCount: 1,
            effectiveTrigger: .significantLocation
        ))
        // Escrita atrasada menos prioritária: aumenta seu próprio contador, mas não rebaixa o trigger.
        await store.coalesce(EvaluationCoalescence(
            evaluationID: id,
            wake: .geofence,
            stage: .admitted,
            count: 1,
            targetCount: 2,
            effectiveTrigger: .geofence
        ))
        // Repetição do snapshot do drain não duplica o wake.
        await store.coalesce(EvaluationCoalescence(
            evaluationID: id,
            wake: .significantLocation,
            stage: .admitted,
            count: 1,
            targetCount: 1,
            effectiveTrigger: .significantLocation
        ))
        await store.advance(EvaluationProgress(
            evaluationID: id,
            stage: .drained,
            effectiveTrigger: .significantLocation
        ))

        let records = await store.recent(limit: 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.trigger, .significantLocation)
        XCTAssertEqual(record.wakes.timer, 1)
        XCTAssertEqual(record.wakes.geofence, 2)
        XCTAssertEqual(record.wakes.significantLocation, 1)
        XCTAssertEqual(record.wakes.total, 4)
        XCTAssertEqual(record.stage, .drained)

        let reopened = makeStore(temp.file, processID: processID)
        let reopenedRecords = await reopened.recent(limit: 1)
        XCTAssertEqual(reopenedRecords.first, record)
    }

    func test_multipleEvaluations_areNewestFirstAndSequenceContinuesAfterReopen() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let processID = EvaluationProcessID()
        let firstID = EvaluationID()
        let secondID = EvaluationID()
        let thirdID = EvaluationID()

        await makeStore(
            temp.file,
            at: iso("2026-07-30T01:00:00Z"),
            processID: processID
        ).begin(start(id: firstID))
        await makeStore(
            temp.file,
            at: iso("2026-07-30T02:00:00Z"),
            processID: processID
        ).begin(start(id: secondID))
        let reopened = makeStore(
            temp.file,
            at: iso("2026-07-30T03:00:00Z"),
            processID: processID
        )
        await reopened.begin(start(id: thirdID))

        let records = await reopened.recent(limit: 10)
        XCTAssertEqual(records.map(\.evaluationID), [thirdID, secondID, firstID])
        XCTAssertEqual(records.map(\.sequence), [3, 2, 1])
    }

    func test_quantityRetention_keepsExactlyNewest500AndSequenceRemainsMonotonic() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let processID = EvaluationProcessID()
        let store = makeStore(temp.file, processID: processID)

        for _ in 0 ... DurableEvaluationJournal.maxRecords {
            await store.begin(start())
        }

        var records = await store.recent(limit: DurableEvaluationJournal.maxRecords + 50)
        XCTAssertEqual(records.count, 500)
        XCTAssertEqual(records.first?.sequence, 501)
        XCTAssertEqual(records.last?.sequence, 2)
        XCTAssertFalse(records.contains { $0.sequence == 1 })

        let reopened = makeStore(temp.file, processID: processID)
        await reopened.begin(start())
        records = await reopened.recent(limit: DurableEvaluationJournal.maxRecords)
        XCTAssertEqual(records.count, 500)
        XCTAssertEqual(records.first?.sequence, 502)
        XCTAssertEqual(records.last?.sequence, 3)
    }

    func test_ageRetention_usesStrictThirtyDayBoundary() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let now = iso("2026-07-30T12:00:00Z")
        let boundary = now.addingTimeInterval(-DurableEvaluationJournal.retentionInterval)
        let tooOldID = EvaluationID()
        let boundaryID = EvaluationID()
        let processID = EvaluationProcessID()

        await makeStore(
            temp.file,
            at: boundary.addingTimeInterval(-1),
            processID: processID
        ).begin(start(id: tooOldID))
        await makeStore(
            temp.file,
            at: boundary,
            processID: processID
        ).begin(start(id: boundaryID))

        let records = await makeStore(temp.file, at: now, processID: processID).recent(limit: 10)
        XCTAssertEqual(records.map(\.evaluationID), [boundaryID])
        XCTAssertFalse(records.contains { $0.evaluationID == tooOldID })
    }

    func test_reconcileOrphans_marksOnlyOtherProcessStartedAndIsIdempotent() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let processA = EvaluationProcessID()
        let processB = EvaluationProcessID()
        let orphanID = EvaluationID()
        let currentID = EvaluationID()
        let completedID = EvaluationID()
        let firstProcess = makeStore(temp.file, processID: processA)

        await firstProcess.begin(start(id: orphanID))
        await firstProcess.begin(start(id: completedID))
        await firstProcess.finish(
            id: completedID,
            terminal: EvaluationTerminal(outcome: .submittedCheckIn)
        )

        let secondProcess = makeStore(temp.file, processID: processB)
        await secondProcess.begin(start(id: currentID))
        await secondProcess.reconcileOrphans()
        let firstReconciliation = await secondProcess.recent(limit: 10)
        let bytes = try Data(contentsOf: temp.file)
        await secondProcess.reconcileOrphans()

        let byID = Dictionary(uniqueKeysWithValues: firstReconciliation.map { ($0.evaluationID, $0) })
        XCTAssertEqual(byID[orphanID]?.terminal, .abandoned)
        XCTAssertEqual(byID[orphanID]?.durationBucket, .unknown)
        XCTAssertNil(byID[currentID]?.terminal)
        XCTAssertEqual(byID[completedID]?.terminal, .submittedCheckIn)
        XCTAssertEqual(try Data(contentsOf: temp.file), bytes)
    }

    func test_missingFile_startsEmptyAndCreatesOnlyOnFirstBegin() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let store = makeStore(temp.file)

        let initiallyEmpty = await store.recent(limit: 10)
        XCTAssertTrue(initiallyEmpty.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.file.path))

        await store.begin(start())
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.file.path))
        let firstRecords = await store.recent(limit: 10)
        XCTAssertEqual(firstRecords.count, 1)
    }

    func test_unavailableRead_preservesRepresentationAndSameActorRetriesLoading() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        try FileManager.default.createDirectory(at: temp.file, withIntermediateDirectories: false)
        let store = makeStore(temp.file)

        await store.begin(start())
        XCTAssertTrue(
            try XCTUnwrap(
                temp.file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory
            )
        )

        let sourceFile = temp.root.appendingPathComponent("valid-source.json")
        let sourceStore = makeStore(sourceFile)
        let sourceID = EvaluationID()
        await sourceStore.begin(start(id: sourceID, stage: .captured))
        await sourceStore.finish(
            id: sourceID,
            terminal: EvaluationTerminal(outcome: .noAction)
        )
        let validData = try Data(contentsOf: sourceFile)

        try FileManager.default.removeItem(at: temp.file)
        try validData.write(to: temp.file, options: .atomic)

        let retriedRecords = await store.recent(limit: 10)
        XCTAssertEqual(retriedRecords.map(\.evaluationID), [sourceID])
        XCTAssertEqual(retriedRecords.first?.terminal, .noAction)
    }

    func test_corruptAndOversizedFiles_recoverWithoutRetainingRawBackups() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }

        for index in 1 ... 3 {
            try Data("CORRUPT_JOURNAL_SENTINEL_\(index)".utf8).write(
                to: temp.file,
                options: .atomic
            )
            let store = makeStore(temp.file)
            let recoveredRecords = await store.recent(limit: 10)
            XCTAssertTrue(recoveredRecords.isEmpty)

            let files = try FileManager.default.contentsOfDirectory(
                at: temp.root,
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(files.map(\.lastPathComponent), [temp.file.lastPathComponent])
            XCTAssertTrue(FileManager.default.fileExists(atPath: temp.file.path))
            let activeText = try String(contentsOf: temp.file, encoding: .utf8)
            XCTAssertFalse(activeText.contains("CORRUPT_JOURNAL_SENTINEL"))
        }

        try Data(
            repeating: 0x41,
            count: Int(DurableEvaluationJournal.maximumFileSizeBytes + 1)
        ).write(to: temp.file, options: .atomic)
        let oversized = makeStore(temp.file)
        let oversizedRecords = await oversized.recent(limit: 10)
        XCTAssertTrue(oversizedRecords.isEmpty)
        let activeSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: temp.file.path)[.size] as? NSNumber
        )
        XCTAssertLessThanOrEqual(
            activeSize.uint64Value,
            DurableEvaluationJournal.maximumFileSizeBytes
        )

        let recovered = makeStore(temp.file)
        await recovered.begin(start())
        let finalRecords = await recovered.recent(limit: 10)
        XCTAssertEqual(finalRecords.count, 1)
        let activeText = try String(contentsOf: temp.file, encoding: .utf8)
        XCTAssertFalse(activeText.contains("CORRUPT_JOURNAL_SENTINEL"))
    }

    func test_futureSchema_isReplacedWithoutRetainingUnknownRawBytes() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let future = """
        {"schema_version":\(DurableEvaluationJournal.schemaVersion + 1),"next_sequence":88,"records":[]}
        """
        try Data(future.utf8).write(to: temp.file)

        let store = makeStore(temp.file)
        let records = await store.recent(limit: 10)
        XCTAssertTrue(records.isEmpty)

        let active = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: temp.file)) as? [String: Any]
        )
        XCTAssertEqual(active["schema_version"] as? Int, DurableEvaluationJournal.schemaVersion)
        let files = try FileManager.default.contentsOfDirectory(
            at: temp.root,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.map(\.lastPathComponent), [temp.file.lastPathComponent])
    }

    func test_ioFailure_isBestEffortAndRetriesTerminalAfterStorageRecovers() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let blocker = temp.root.appendingPathComponent("parent-is-a-file")
        try Data("blocker".utf8).write(to: blocker)
        let impossibleFile = blocker.appendingPathComponent("journal.json")
        let store = makeStore(impossibleFile)
        let id = EvaluationID()

        await store.begin(start(id: id))
        await store.finish(id: id, terminal: EvaluationTerminal(outcome: .noAction))
        let inMemoryRecords = await store.recent(limit: 10)
        XCTAssertEqual(inMemoryRecords.first?.terminal, .noAction)
        XCTAssertFalse(FileManager.default.fileExists(atPath: impossibleFile.path))

        try FileManager.default.removeItem(at: blocker)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        let flushedRecords = await store.recent(limit: 10)
        XCTAssertEqual(flushedRecords.first?.terminal, .noAction)
        XCTAssertTrue(FileManager.default.fileExists(atPath: impossibleFile.path))
        let reopenedAfterRecovery = makeStore(impossibleFile)
        let persistedRecords = await reopenedAfterRecovery.recent(limit: 10)
        XCTAssertEqual(persistedRecords.first?.terminal, .noAction)

        await store.clear()
        let clearedRecords = await store.recent(limit: 10)
        XCTAssertTrue(clearedRecords.isEmpty)
        let reopened = makeStore(impossibleFile)
        let reopenedRecords = await reopened.recent(limit: 10)
        XCTAssertTrue(reopenedRecords.isEmpty)
    }

    func test_clear_removesActiveFileAndMemory_andIsIdempotent() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let store = makeStore(temp.file)

        await store.begin(start())
        await store.clear()
        await store.clear()

        let clearedRecords = await store.recent(limit: 10)
        XCTAssertTrue(clearedRecords.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.file.path))
        let reopened = makeStore(temp.file)
        let reopenedRecords = await reopened.recent(limit: 10)
        XCTAssertTrue(reopenedRecords.isEmpty)
    }

    func test_concurrentBeginFinish_isSerializedAndFileReopensCleanly() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let processID = EvaluationProcessID()
        let store = makeStore(temp.file, processID: processID)
        let ids = (0 ..< 50).map { _ in EvaluationID() }

        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    await store.begin(EvaluationStart(
                        id: id,
                        trigger: .significantLocation,
                        primaryWake: .significantLocation
                    ))
                    await Task.yield()
                    await store.finish(
                        id: id,
                        terminal: EvaluationTerminal(outcome: .noAction)
                    )
                }
            }
        }

        let records = await store.recent(limit: 100)
        XCTAssertEqual(records.count, ids.count)
        XCTAssertEqual(Set(records.map(\.evaluationID)), Set(ids))
        XCTAssertEqual(Set(records.map(\.sequence)), Set(1 ... UInt64(ids.count)))
        XCTAssertTrue(records.allSatisfy { $0.terminal == .noAction })

        let reopened = makeStore(temp.file, processID: processID)
        let reopenedRecords = await reopened.recent(limit: 100)
        XCTAssertEqual(reopenedRecords, records)
    }

    func test_bucketBoundariesAndInvalidValuesAreSanitized() {
        XCTAssertEqual(EvaluationAccuracyBucket.classify(meters: 0), .zeroTo10Meters)
        XCTAssertEqual(EvaluationAccuracyBucket.classify(meters: 10), .zeroTo10Meters)
        XCTAssertEqual(EvaluationAccuracyBucket.classify(meters: 10.1), .elevenTo25Meters)
        XCTAssertEqual(EvaluationAccuracyBucket.classify(meters: 25), .elevenTo25Meters)
        XCTAssertEqual(EvaluationAccuracyBucket.classify(meters: 50), .twentySixTo50Meters)
        XCTAssertEqual(EvaluationAccuracyBucket.classify(meters: 100), .fiftyOneTo100Meters)
        XCTAssertEqual(EvaluationAccuracyBucket.classify(meters: 100.1), .over100Meters)
        XCTAssertEqual(EvaluationAccuracyBucket.classify(meters: -.infinity), .unknown)
        XCTAssertEqual(EvaluationAccuracyBucket.classify(meters: .nan), .unknown)

        XCTAssertEqual(EvaluationAgeBucket.classify(seconds: 0.9), .under1Second)
        XCTAssertEqual(EvaluationAgeBucket.classify(seconds: 1), .oneTo5Seconds)
        XCTAssertEqual(EvaluationAgeBucket.classify(seconds: 5), .oneTo5Seconds)
        XCTAssertEqual(EvaluationAgeBucket.classify(seconds: 15), .sixTo15Seconds)
        XCTAssertEqual(EvaluationAgeBucket.classify(seconds: 15.1), .over15Seconds)
        XCTAssertEqual(EvaluationAgeBucket.classify(seconds: -1), .unknown)

        XCTAssertEqual(EvaluationDurationBucket.classify(seconds: 0), .under1Second)
        XCTAssertEqual(EvaluationDurationBucket.classify(seconds: 1), .oneTo5Seconds)
        XCTAssertEqual(EvaluationDurationBucket.classify(seconds: 6), .sixTo15Seconds)
        XCTAssertEqual(EvaluationDurationBucket.classify(seconds: .infinity), .unknown)
        XCTAssertEqual(EvaluationDurationBucket.classify(seconds: nil), .unknown)

        let invalidHTTP = EvaluationHTTPDiagnostic(status: 999)
        XCTAssertNil(invalidHTTP.status)
        XCTAssertEqual(invalidHTTP.classification, .unknown)
        let roundTrip = try? JSONDecoder().decode(
            EvaluationHTTPDiagnostic.self,
            from: JSONEncoder().encode(invalidHTTP)
        )
        XCTAssertEqual(roundTrip, invalidHTTP)
        XCTAssertNil(EvaluationHTTPDiagnostic.sanitized(
            from: .unknown(description: "ERROR_DESCRIPTION_MUST_BE_DROPPED")
        ))
        XCTAssertNil(EvaluationHTTPDiagnostic.sanitized(from: .unauthorized))
        XCTAssertEqual(
            EvaluationHTTPDiagnostic.sanitized(from: .conflict),
            EvaluationHTTPDiagnostic(status: 409)
        )
    }

    func test_noopJournal_acceptsAllCommandsAndNeverRetainsRecords() async {
        let journal = NoopEvaluationJournal()
        let id = EvaluationID()
        await journal.begin(start(id: id))
        await journal.coalesce(EvaluationCoalescence(evaluationID: id, wake: .geofence))
        await journal.recordOwnerExpiration(
            evaluationID: id,
            owner: .bgAppRefresh,
            cancelledCanonicalWork: true
        )
        await journal.finish(id: id, terminal: EvaluationTerminal(outcome: .noAction))
        await journal.reconcileOrphans()
        await journal.clear()
        let records = await journal.recent(limit: 10)
        XCTAssertTrue(records.isEmpty)
    }

    func test_serializedJournal_hasExactWhitelistAndNoSensitiveSentinels() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let bodySentinel = "BODY_SENTINEL_PRIVATE_31"
        let errorDescriptionSentinel = "ERROR_SENTINEL_KEY_TOKEN_93"
        let http = try XCTUnwrap(EvaluationHTTPDiagnostic.sanitized(
            from: .http(status: 422, detail: bodySentinel)
        ))
        let externalError = NSError(
            domain: "kCLErrorDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: errorDescriptionSentinel]
        )
        let coreLocationCategory = EvaluationCoreLocationErrorCategory.classify(
            code: externalError.code
        )
        let id = EvaluationID()
        let store = makeStore(temp.file)
        await store.begin(EvaluationStart(
            id: id,
            trigger: .significantLocation,
            primaryWake: .significantLocation,
            stage: .captured,
            appState: .background,
            launchState: .cold,
            permissionMode: .always,
            accuracyMode: .full,
            backgroundRefresh: .available,
            lowPowerMode: true,
            monitors: EvaluationMonitorFlags(
                geofence: .active,
                significantLocation: .active,
                backgroundTask: .active
            ),
            locationSource: .seed,
            captureReused: true,
            accuracyBucket: .elevenTo25Meters,
            ageBucket: .oneTo5Seconds
        ))
        await store.coalesce(EvaluationCoalescence(evaluationID: id, wake: .geofence))
        await store.recordOwnerExpiration(
            evaluationID: id,
            owner: .bgAppRefresh,
            cancelledCanonicalWork: false
        )
        await store.recordOwnerExpiration(
            evaluationID: id,
            owner: .uiBackgroundTask,
            cancelledCanonicalWork: true
        )
        await store.finish(
            id: id,
            terminal: EvaluationTerminal(
                outcome: .httpRejected,
                durationBucket: .sixTo15Seconds,
                locationSource: .seed,
                captureReused: true,
                accuracyBucket: .elevenTo25Meters,
                ageBucket: .oneTo5Seconds,
                coreLocationError: coreLocationCategory,
                http: http,
                notificationScheduled: false
            )
        )

        let data = try Data(contentsOf: temp.file)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(root.keys), ["schema_version", "next_sequence", "records"])
        let records = try XCTUnwrap(root["records"] as? [[String: Any]])
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(Set(record.keys), [
            "schema_version", "evaluation_id", "process_id", "sequence",
            "started_at", "finished_at", "trigger", "wakes", "stage", "app_state",
            "launch_state", "permission_mode", "accuracy_mode", "background_refresh",
            "low_power_mode", "monitors", "location_source", "capture_reused",
            "accuracy_bucket", "age_bucket", "duration_bucket", "terminal",
            "core_location_error", "http", "notification_scheduled", "owner_expirations",
        ])
        XCTAssertEqual(
            Set(try XCTUnwrap(record["wakes"] as? [String: Any]).keys),
            [
                "timer", "geofence", "significant_location", "foreground",
                "accuracy_retry", "pause_activation", "pause_transition",
            ]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(record["monitors"] as? [String: Any]).keys),
            ["geofence", "significant_location", "background_task"]
        )
        let persistedHTTP = try XCTUnwrap(record["http"] as? [String: Any])
        XCTAssertEqual(Set(persistedHTTP.keys), ["status", "classification"])
        XCTAssertEqual(persistedHTTP["status"] as? Int, 422)
        XCTAssertEqual(persistedHTTP["classification"] as? String, "client_error")
        let ownerExpirations = try XCTUnwrap(record["owner_expirations"] as? [String: Any])
        XCTAssertEqual(Set(ownerExpirations.keys), [
            "bg_app_refresh_expired",
            "ui_background_task_expired",
            "bg_processing_expired",
            "bg_app_refresh_cancelled_canonical_work",
            "ui_background_task_cancelled_canonical_work",
            "bg_processing_cancelled_canonical_work",
        ])
        XCTAssertEqual(ownerExpirations["bg_app_refresh_expired"] as? Bool, true)
        XCTAssertEqual(
            ownerExpirations["bg_app_refresh_cancelled_canonical_work"] as? Bool,
            false
        )
        XCTAssertEqual(ownerExpirations["ui_background_task_expired"] as? Bool, true)
        XCTAssertEqual(
            ownerExpirations["ui_background_task_cancelled_canonical_work"] as? Bool,
            true
        )
        XCTAssertEqual(ownerExpirations["bg_processing_expired"] as? Bool, false)
        XCTAssertEqual(
            ownerExpirations["bg_processing_cancelled_canonical_work"] as? Bool,
            false
        )

        let allKeys = collectKeys(root).map {
            $0.lowercased().replacingOccurrences(of: "_", with: "")
        }
        let forbiddenKeys: Set<String> = [
            "latitude", "longitude", "altitude", "speed", "course", "location",
            "project", "user", "chave", "password", "cookie", "token", "headers",
            "clienteventid", "requestbody", "responsebody", "url", "regionid", "rawerror",
            "ownerid", "ownertoken", "expirationreason", "cancellationreason",
        ]
        XCTAssertTrue(forbiddenKeys.isDisjoint(with: Set(allKeys)))

        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        let forbiddenSentinels = [
            "LAT_SENTINEL_1_352100",
            "LON_SENTINEL_103_819800",
            "KEY_SENTINEL_HR70",
            "COOKIE_SENTINEL_SESSION_93A",
            "PASSWORD_SENTINEL_W7",
            "TOKEN_SENTINEL_APNS_77",
            "REGION_SENTINEL_P80_42",
            "LOCATION_SENTINEL_UNIDADE_P80",
            "PROJECT_SENTINEL_P80",
            "CLIENT_EVENT_SENTINEL_19",
            bodySentinel,
            "URL_SENTINEL_CHECK_27",
            errorDescriptionSentinel,
            "OWNER_TOKEN_SENTINEL_BG_91",
            "EXPIRATION_REASON_SENTINEL_FREE_TEXT_17",
        ]
        for sentinel in forbiddenSentinels {
            XCTAssertFalse(serialized.contains(sentinel), "Serialized forbidden sentinel: \(sentinel)")
        }
    }

    func test_benchmark_beginFinish_recordsOrderOfMagnitudeWithoutThreshold() async throws {
        let temp = try makeTemporaryJournal()
        defer { try? FileManager.default.removeItem(at: temp.root) }
        let store = makeStore(temp.file)
        let pairCount = 25
        let benchmarkClock = ContinuousClock()
        let started = benchmarkClock.now

        for _ in 0 ..< pairCount {
            let id = EvaluationID()
            await store.begin(start(id: id))
            await store.finish(id: id, terminal: EvaluationTerminal(outcome: .noAction))
        }

        let elapsed = started.duration(to: benchmarkClock.now)
        let components = elapsed.components
        let totalSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let fileSize = (try? Data(contentsOf: temp.file).count) ?? 0
        let report = String(
            format: "journal benchmark: %d begin/finish pairs, %.6f s total, %.3f ms/pair, %d bytes",
            pairCount,
            totalSeconds,
            totalSeconds * 1_000 / Double(pairCount),
            fileSize
        )
        let attachment = XCTAttachment(string: report)
        attachment.lifetime = .keepAlways
        add(attachment)

        let records = await store.recent(limit: pairCount)
        XCTAssertEqual(records.count, pairCount)
    }

    private func collectKeys(_ value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return Array(dictionary.keys) + dictionary.values.flatMap(collectKeys)
        }
        if let array = value as? [Any] {
            return array.flatMap(collectKeys)
        }
        return []
    }
}
