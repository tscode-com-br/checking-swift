import XCTest
@testable import Checking

// Port de CheckViewModelForegroundTest.kt (1). §9.4.
@MainActor
final class CheckViewModelForegroundTests: XCTestCase {

    func test_onForegroundResume_when_not_authenticated_does_not_run_orchestrator() async {
        let h = VMHarness()                                        // chave "" → não autenticado
        let vm = h.build()
        await settle { !vm.uiState.isInitializing }

        vm.onForegroundResume()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(h.orchestrator.runOnceCalls.isEmpty)
        h.teardown()
    }
}
