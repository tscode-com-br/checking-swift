import SwiftUI
import XCTest
@testable import Checking

/// O resolvedor de paleta é o swap de tema de acidente (§5) — a lógica pura por trás do `provideAccidentTheme`.
final class CheckingPaletteTests: XCTestCase {

    func test_resolve_normalWhenInactive() {
        XCTAssertEqual(CheckingPalette.resolve(accidentActive: false), .normal)
    }

    func test_resolve_accidentWhenActive() {
        XCTAssertEqual(CheckingPalette.resolve(accidentActive: true), .accident)
    }

    func test_normalPrimaryIsTeal() {
        XCTAssertEqual(CheckingPalette.normal.primary, Color(hex: "#0F766E"))
        XCTAssertEqual(CheckingPalette.normal.primaryContainer, Color(hex: "#CCFBF1"))
        XCTAssertEqual(CheckingPalette.normal.onPrimaryContainer, Color(hex: "#115E59"))
    }

    func test_accidentPrimaryIsRed() {
        XCTAssertEqual(CheckingPalette.accident.primary, Color(hex: "#C8222A"))
        XCTAssertEqual(CheckingPalette.accident.primaryContainer, Color(hex: "#FDE7E9"))
        XCTAssertEqual(CheckingPalette.accident.onPrimaryContainer, Color(hex: "#8C1A20"))
        XCTAssertEqual(CheckingPalette.accident.secondary, Color(hex: "#C8222A"))
    }

    func test_sharedTokensUnchangedBySwap() {
        // surface/background/error coincidem nos DOIS esquemas Kotlin (ambos setam explicitamente iguais).
        XCTAssertEqual(CheckingPalette.normal.surface, CheckingPalette.accident.surface)
        XCTAssertEqual(CheckingPalette.normal.background, CheckingPalette.accident.background)
        XCTAssertEqual(CheckingPalette.normal.error, CheckingPalette.accident.error)
    }

    func test_accidentOutlineFallsBackToMaterial3Baseline() {
        // O AccidentColorScheme do Kotlin NÃO seta outline/outlineVariant → default M3 (NÃO os valores do app).
        XCTAssertEqual(CheckingPalette.accident.outline, Color(hex: "#79747E"))
        XCTAssertEqual(CheckingPalette.accident.outlineVariant, Color(hex: "#CAC4D0"))
        XCTAssertNotEqual(CheckingPalette.normal.outline, CheckingPalette.accident.outline)
        // O modo normal usa os valores do app.
        XCTAssertEqual(CheckingPalette.normal.outline, Color(hex: "#CBD5E1"))
        XCTAssertEqual(CheckingPalette.normal.outlineVariant, Color(hex: "#E2E8F0"))
    }
}
