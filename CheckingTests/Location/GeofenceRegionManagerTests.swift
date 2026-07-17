import XCTest
@testable import Checking

/// Port implícito de GeofenceManager.kt (sem teste dedicado no Android): fetch → prioriza → arma; engole
/// erro; lista vazia não faz nada; `unregisterAll` limpa. Além disso, o comportamento iOS-only do cap 20
/// (log de omitidas + `lastSummary` p/ o painel de integridade). Monitor real (`CLLocationManager`) fakeado.
final class GeofenceRegionManagerTests: XCTestCase {

    private actor SpyMonitor: GeofenceRegionMonitoring {
        private(set) var syncedRegions: [GeofenceRegion]?
        private(set) var syncCount = 0
        private(set) var removeAllCount = 0
        func sync(_ regions: [GeofenceRegion]) async { syncedRegions = regions; syncCount += 1 }
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

    func test_register_emptyList_doesNothing() async {
        let (sut, monitor, logger) = makeSUT(.success([]))
        await sut.register(chave: "STSM")
        let count = await monitor.syncCount
        XCTAssertEqual(count, 0)                             // fiel ao Kotlin: early return em lista vazia
        XCTAssertTrue(logger.system.isEmpty)
        let summary = await sut.lastSummary
        XCTAssertNil(summary)
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
}
