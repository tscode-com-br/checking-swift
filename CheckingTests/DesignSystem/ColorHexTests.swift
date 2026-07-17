import SwiftUI
import XCTest
@testable import Checking

/// O parser hex é a fundação de todos os tokens de cor — se ele erra, toda a paleta erra. Testável puro.
final class ColorHexTests: XCTestCase {

    private func assertRGBA(_ hex: String, _ r: Double, _ g: Double, _ b: Double, _ a: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
        let c = Color.rgbaComponents(hex: hex)
        XCTAssertEqual(c.r, r, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(c.g, g, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(c.b, b, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(c.a, a, accuracy: 0.0001, file: file, line: line)
    }

    func test_primaryTeal() {
        assertRGBA("#0F766E", 15.0/255, 118.0/255, 110.0/255, 1)
    }

    func test_whiteAndBlackAndRed() {
        assertRGBA("#FFFFFF", 1, 1, 1, 1)
        assertRGBA("#000000", 0, 0, 0, 1)
        assertRGBA("#FF0000", 1, 0, 0, 1)
    }

    func test_withoutHashPrefix() {
        assertRGBA("0F766E", 15.0/255, 118.0/255, 110.0/255, 1)
    }

    func test_argb8Digits_alphaIsHighByte() {
        // AARRGGBB — alpha no byte mais alto (igual ao Color(0xAARRGGBB) do Kotlin).
        assertRGBA("#800F766E", 15.0/255, 118.0/255, 110.0/255, 128.0/255)
        assertRGBA("#FF0F766E", 15.0/255, 118.0/255, 110.0/255, 1)
    }

    func test_lowercaseAndWhitespace() {
        assertRGBA("  #0f766e  ", 15.0/255, 118.0/255, 110.0/255, 1)
    }

    func test_invalid_fallsBackToOpaqueBlack() {
        assertRGBA("#ZZZ", 0, 0, 0, 1)
        assertRGBA("#12", 0, 0, 0, 1)      // comprimento não suportado (nem 6 nem 8)
    }
}
