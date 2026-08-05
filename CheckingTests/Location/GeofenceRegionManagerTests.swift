import XCTest
@testable import Checking

/// Port implícito de GeofenceManager.kt (sem teste dedicado no Android): fetch → prioriza → arma; engole
/// erro; lista vazia não faz nada; `unregisterAll` limpa. Além disso, o comportamento iOS-only do cap 20
/// (log de omitidas + `lastSummary` p/ o painel de integridade). Monitor real (`CLLocationManager`) fakeado.
final class GeofenceRegionManagerTests: XCTestCase {

    private actor SpyMonitor: GeofenceRegionMonitoring {
        private(set) var syncedRegions: [GeofenceRegion]?
        private(set) var syncCount = 0
        private(set) var omittedCounts: [Int] = []
        private(set) var removeAllCount = 0
        func sync(_ regions: [GeofenceRegion]) async { syncedRegions = regions; syncCount += 1 }
        func sync(_ regions: [GeofenceRegion], omittedCount: Int) async {
            syncedRegions = regions
            syncCount += 1
            omittedCounts.append(omittedCount)
        }
        func removeAll() async { removeAllCount += 1 }
    }

    private final class RecordingLogger: ActivityLogging, @unchecked Sendable {
        private let lock = NSLock()
        private var systemLogs: [(message: String, severity: ActivitySeverity)] = []
        var system: [(message: String, severity: ActivitySeverity)] { lock.withLock { systemLogs } }
        func logSystem(_ message: String, _ severity: ActivitySeverity) {
            lock.withLock { systemLogs.append((message, severity)) }
        }
    }

    private actor ScriptedGeofenceFetches {
        struct Step: Sendable {
            let result: AppResult<[GeofenceCircle]>
            let gate: AsyncGate?
        }

        private var steps: [Step]
        private(set) var callCount = 0

        init(_ steps: [Step]) {
            self.steps = steps
        }

        func next() async -> AppResult<[GeofenceCircle]> {
            let index = callCount
            callCount += 1
            guard steps.indices.contains(index) else {
                return .failure(.unknown(description: nil))
            }
            let step = steps[index]
            await step.gate?.wait()
            return step.result
        }
    }

    private struct ScriptedGeofenceRepository: CheckRepository {
        let fetches: ScriptedGeofenceFetches

        init(_ steps: [ScriptedGeofenceFetches.Step]) {
            fetches = ScriptedGeofenceFetches(steps)
        }

        func matchLocation(
            _ lat: Double,
            _ lon: Double,
            _ accuracyMeters: Double?
        ) async -> AppResult<LocationMatch> {
            .failure(.network)
        }

        func getState(_ chave: String) async -> AppResult<HistoryState> {
            .failure(.network)
        }

        func getHistory(_ chave: String) async -> AppResult<[CheckHistoryEntry]> {
            .failure(.network)
        }

        func getLocations() async -> AppResult<LocationOptions> {
            .failure(.network)
        }

        func getGeofences(_ chave: String) async -> AppResult<[GeofenceCircle]> {
            await fetches.next()
        }

        func invalidateGeofenceCache() {}

        func submit(
            chave: String,
            projeto: String,
            action: CheckAction,
            local: String?,
            informe: InformeType,
            eventTime: Date,
            clientEventId: String,
            fillForms: Bool
        ) async -> AppResult<HistoryState> {
            .failure(.network)
        }
    }

    private actor OrderedGatedMonitor: GeofenceRegionMonitoring {
        enum Command: Sendable, Equatable {
            case sync([String])
            case removeAll
        }

        private var syncGates: [AsyncGate?]
        private(set) var startedCommands: [Command] = []
        private(set) var appliedCommands: [Command] = []
        private(set) var currentRegionIDs: [String]?
        private(set) var maximumConcurrentCommands = 0
        private var activeCommands = 0

        init(syncGates: [AsyncGate?] = []) {
            self.syncGates = syncGates
        }

        func sync(_ regions: [GeofenceRegion]) async {
            let command = Command.sync(regions.map(\.id))
            let index = startedCommands.reduce(into: 0) { count, command in
                if case .sync = command { count += 1 }
            }
            startedCommands.append(command)
            activeCommands += 1
            maximumConcurrentCommands = max(maximumConcurrentCommands, activeCommands)

            if syncGates.indices.contains(index), let gate = syncGates[index] {
                await gate.wait()
            }

            currentRegionIDs = regions.map(\.id)
            appliedCommands.append(command)
            activeCommands -= 1
        }

        func removeAll() async {
            let command = Command.removeAll
            startedCommands.append(command)
            activeCommands += 1
            maximumConcurrentCommands = max(maximumConcurrentCommands, activeCommands)
            currentRegionIDs = nil
            appliedCommands.append(command)
            activeCommands -= 1
        }
    }

    private func circle(_ id: Int, local: String = "L", lat: Double = 0, lng: Double = 0, radius: Double = 100) -> GeofenceCircle {
        GeofenceCircle(id: id, local: local, centerLat: lat, centerLng: lng, radiusMeters: radius)
    }

    private func makeSUT(_ geofences: AppResult<[GeofenceCircle]>) -> (GeofenceRegionManager, SpyMonitor, RecordingLogger) {
        let repo = FakeCheckRepository(); repo.getGeofencesResult = geofences
        let monitor = SpyMonitor(); let logger = RecordingLogger()
        return (GeofenceRegionManager(checkRepository: repo, monitor: monitor, activityLogger: logger), monitor, logger)
    }

    func test_register_success_syncsRegions_andLogsRegisteredCount() async {
        let (sut, monitor, logger) = makeSUT(.success([circle(1), circle(2), circle(3)]))
        await sut.register(chave: "STSM")
        let synced = await monitor.syncedRegions
        XCTAssertEqual(synced?.count, 3)
        XCTAssertEqual(logger.system.first?.message, "Geofences registered (3).")   // byte-exact com o Kotlin
        XCTAssertEqual(logger.system.first?.severity, .info)
        let summary = await sut.lastSummary
        XCTAssertEqual(summary, GeofenceRegistrationSummary(monitored: 3, omitted: 0))
    }

    func test_register_mapsCircleFieldsToRegion() async {
        let (sut, monitor, _) = makeSUT(.success([circle(42, lat: -23.5, lng: -46.6, radius: 150)]))
        await sut.register(chave: "STSM")
        let region = await monitor.syncedRegions?.first
        XCTAssertEqual(region?.id, "42")                     // id → String (setRequestId do Kotlin)
        XCTAssertEqual(region?.centerLat, -23.5)
        XCTAssertEqual(region?.centerLng, -46.6)
        XCTAssertEqual(region?.radiusMeters, 150)
    }

    func test_register_emptyList_clearsPreviouslyMonitoredRegions() async {
        let (sut, monitor, logger) = makeSUT(.success([]))
        await sut.register(chave: "STSM")
        let count = await monitor.syncCount
        let synced = await monitor.syncedRegions
        XCTAssertEqual(count, 1)
        XCTAssertEqual(synced, [])
        XCTAssertEqual(logger.system.first?.message, "Geofences registered (0).")
        let summary = await sut.lastSummary
        XCTAssertEqual(summary, GeofenceRegistrationSummary(monitored: 0, omitted: 0))
    }

    func test_register_failure_doesNothing() async {
        let (sut, monitor, logger) = makeSUT(.failure(.network))
        await sut.register(chave: "STSM")
        let count = await monitor.syncCount
        XCTAssertEqual(count, 0)                             // fiel ao Kotlin: engole o erro
        XCTAssertTrue(logger.system.isEmpty)
        let summary = await sut.lastSummary
        XCTAssertNil(summary)
    }

    func test_register_failurePreservesPreviouslyAppliedRegionsAndSummary() async {
        let repository = ScriptedGeofenceRepository([
            .init(result: .success([circle(1), circle(2)]), gate: nil),
            .init(result: .failure(.network), gate: nil)
        ])
        let monitor = SpyMonitor()
        let logger = RecordingLogger()
        let sut = GeofenceRegionManager(
            checkRepository: repository,
            monitor: monitor,
            activityLogger: logger
        )

        await sut.register(chave: "STSM")
        let beforeRegions = await monitor.syncedRegions
        let beforeSummary = await sut.lastSummary

        await sut.register(chave: "STSM", forceRefresh: true)

        let syncCount = await monitor.syncCount
        let afterRegions = await monitor.syncedRegions
        let afterSummary = await sut.lastSummary
        XCTAssertEqual(syncCount, 1)
        XCTAssertEqual(afterRegions, beforeRegions)
        XCTAssertEqual(afterSummary, beforeSummary)
        XCTAssertEqual(logger.system.map(\.message), ["Geofences registered (2)."])
    }

    func test_register_overCap_syncs20_andLogsOmittedWarning() async {
        let (sut, monitor, logger) = makeSUT(.success((1...25).map { circle($0) }))
        await sut.register(chave: "STSM")
        let synced = await monitor.syncedRegions
        XCTAssertEqual(synced?.count, 20)                    // cap 20
        let summary = await sut.lastSummary
        XCTAssertEqual(summary, GeofenceRegistrationSummary(monitored: 20, omitted: 5))
        // A truncagem NÃO é silenciosa: há um WARNING dedicado (plano §9.2).
        let warn = logger.system.first { $0.severity == .warning }
        XCTAssertNotNil(warn)
        XCTAssertTrue(warn?.message.contains("5 omitted") == true, "esperava contagem de omitidas na mensagem")
        let omittedCounts = await monitor.omittedCounts
        XCTAssertEqual(omittedCounts, [5])
    }

    func test_register_underCap_noOmittedWarning() async {
        let (sut, _, logger) = makeSUT(.success((1...10).map { circle($0) }))
        await sut.register(chave: "STSM")
        XCTAssertFalse(logger.system.contains { $0.severity == .warning })
    }

    func test_register_appliesHints_currentAreaFirstInSyncedOrder() async {
        let circles = [circle(1, local: "Outro"), circle(2, local: "Atual"), circle(3, local: "Outro")]
        let (sut, monitor, _) = makeSUT(.success(circles))
        await sut.register(chave: "STSM", hints: GeofencePriorityHints(currentLocalName: "Atual"))
        let synced = await monitor.syncedRegions
        XCTAssertEqual(synced?.first?.id, "2")               // área atual em 1º na ordem entregue ao monitor
    }

    func test_unregisterAll_callsRemoveAll_andClearsSummary() async {
        let (sut, monitor, _) = makeSUT(.success([circle(1)]))
        await sut.register(chave: "STSM")
        await sut.unregisterAll()
        let removeCount = await monitor.removeAllCount
        XCTAssertEqual(removeCount, 1)
        let summary = await sut.lastSummary
        XCTAssertNil(summary)
    }

    func test_registerResponseArrivingAfterUnregister_doesNotSyncOrRestoreSummary() async {
        let fetchGate = AsyncGate()
        let repository = ScriptedGeofenceRepository([
            .init(result: .success([circle(1)]), gate: fetchGate)
        ])
        let monitor = OrderedGatedMonitor()
        let logger = RecordingLogger()
        let sut = GeofenceRegionManager(
            checkRepository: repository,
            monitor: monitor,
            activityLogger: logger
        )

        let oldRegister = Task {
            await sut.register(chave: "OLD")
        }
        await waitUntil {
            await repository.fetches.callCount == 1
        }
        let fetchCount = await repository.fetches.callCount
        XCTAssertEqual(fetchCount, 1)

        await sut.unregisterAll()
        await fetchGate.release()
        await oldRegister.value

        let startedCommands = await monitor.startedCommands
        let appliedCommands = await monitor.appliedCommands
        let currentRegionIDs = await monitor.currentRegionIDs
        let summary = await sut.lastSummary
        XCTAssertEqual(startedCommands, [.removeAll])
        XCTAssertEqual(appliedCommands, [.removeAll])
        XCTAssertNil(currentRegionIDs)
        XCTAssertNil(summary)
        XCTAssertTrue(logger.system.isEmpty)
    }

    func test_olderRegisterResponseArrivingLast_neverReplacesNewestRegistration() async {
        let oldFetchGate = AsyncGate()
        let repository = ScriptedGeofenceRepository([
            .init(result: .success([circle(1)]), gate: oldFetchGate),
            .init(result: .success([circle(2)]), gate: nil)
        ])
        let monitor = OrderedGatedMonitor()
        let logger = RecordingLogger()
        let sut = GeofenceRegionManager(
            checkRepository: repository,
            monitor: monitor,
            activityLogger: logger
        )

        let oldRegister = Task {
            await sut.register(chave: "OLD")
        }
        await waitUntil {
            await repository.fetches.callCount == 1
        }
        let firstFetchCount = await repository.fetches.callCount
        XCTAssertEqual(firstFetchCount, 1)

        let newRegister = Task {
            await sut.register(chave: "NEW")
        }
        await newRegister.value
        await oldFetchGate.release()
        await oldRegister.value

        let startedCommands = await monitor.startedCommands
        let appliedCommands = await monitor.appliedCommands
        let currentRegionIDs = await monitor.currentRegionIDs
        let summary = await sut.lastSummary
        XCTAssertEqual(startedCommands, [.sync(["2"])])
        XCTAssertEqual(appliedCommands, [.sync(["2"])])
        XCTAssertEqual(currentRegionIDs, ["2"])
        XCTAssertEqual(summary, GeofenceRegistrationSummary(monitored: 1, omitted: 0))
        XCTAssertEqual(logger.system.map { $0.message }, ["Geofences registered (1)."])
    }

    func test_monitorCommandsAreSerialized_andLatestIntentWinsWhileFirstSyncIsSuspended() async {
        let firstSyncGate = AsyncGate()
        let repository = ScriptedGeofenceRepository([
            .init(result: .success([circle(1)]), gate: nil),
            .init(result: .success([circle(2)]), gate: nil)
        ])
        let monitor = OrderedGatedMonitor(syncGates: [firstSyncGate])
        let logger = RecordingLogger()
        let sut = GeofenceRegionManager(
            checkRepository: repository,
            monitor: monitor,
            activityLogger: logger
        )

        let firstRegister = Task {
            await sut.register(chave: "FIRST")
        }
        await waitUntil {
            await monitor.startedCommands == [.sync(["1"])]
        }
        let firstStartedCommands = await monitor.startedCommands
        XCTAssertEqual(firstStartedCommands, [.sync(["1"])])

        let secondRegister = Task {
            await sut.register(chave: "SECOND")
        }
        await waitUntil {
            await repository.fetches.callCount == 2
        }
        let fetchCount = await repository.fetches.callCount
        let commandsBeforeRelease = await monitor.startedCommands
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(commandsBeforeRelease, [.sync(["1"])])

        await firstSyncGate.release()
        await firstRegister.value
        await secondRegister.value

        let maximumConcurrentCommands = await monitor.maximumConcurrentCommands
        let appliedCommands = await monitor.appliedCommands
        let currentRegionIDs = await monitor.currentRegionIDs
        let summary = await sut.lastSummary
        XCTAssertEqual(maximumConcurrentCommands, 1)
        XCTAssertEqual(
            appliedCommands,
            [.sync(["1"]), .sync(["2"])]
        )
        XCTAssertEqual(currentRegionIDs, ["2"])
        XCTAssertEqual(summary, GeofenceRegistrationSummary(monitored: 1, omitted: 0))
        // A intenção antiga não publica resumo/log depois de a nova intenção já existir.
        XCTAssertEqual(logger.system.map { $0.message }, ["Geofences registered (1)."])
    }
}
