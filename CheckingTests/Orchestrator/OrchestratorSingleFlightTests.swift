import XCTest
@testable import Checking

// Divergência iOS intencional por perfil: o legado conserva o drop histórico; o candidate mantém um
// pending normal bounded, coberto por PendingNormalWakeTests.
final class OrchestratorSingleFlightTests: XCTestCase {

    func test_legacyProfile_concurrentRunOnce_keepsHistoricalDrop() async {
        let gate = AsyncGate()
        let prefs = FakeAppPreferences()
        prefs.chaveGate = gate; prefs.chaveValue = ""          // run1 trava no chave() segurando isRunning
        let spy = SpyAutoActivities()
        let checkRepo = FakeCheckRepository()
        let orchestrator = makeOrchestrator(
            prefs: prefs,
            checkRepository: checkRepo,
            autoActivities: spy,
            automaticEvaluationPipeline: .legacy
        )

        let run1 = Task { await orchestrator.runOnce(.timer) }
        await waitUntil { await orchestrator.isRunningForTest }  // run1 travou (isRunning = true)

        await orchestrator.runOnce(.geofence)                    // 2ª chamada: tryLock falha → RETORNA imediato
        XCTAssertEqual(spy.callCount, 0)                         // run2 não fez trabalho

        await gate.release()                                     // libera run1 → chave "" → return no passo 1
        _ = await run1.value
        XCTAssertEqual(spy.callCount, 0)
        XCTAssertEqual(checkRepo.submitCount, 0)
    }
}
