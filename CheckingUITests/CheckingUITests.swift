import XCTest

/// Smoke test de UI — prova que o app lança e mostra a raiz. Expandir com os fluxos das specs
/// (cadastro/login, check manual, transporte, acidente) conforme forem implementados.
final class CheckingUITests: XCTestCase {

    func test_appLaunches_showsBrand() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Checking"].waitForExistence(timeout: 5))
    }
}
