import SwiftUI
import XCTest
@testable import Checking

/// Guarda de regressão contra dígito trocado e contraste insuficiente. O único desvio deliberado do
/// Android é `textMutedLight`, escurecido no iOS para manter folga sobre WCAG AA com antialiasing.
final class CheckingColorsTests: XCTestCase {

    func test_everyTokenMatchesKotlinHex() {
        // (token, hex esperado) — 1:1 com presentation/theme/Color.kt.
        let table: [(Color, String)] = [
            (CheckingColors.primary, "#0F766E"),
            (CheckingColors.primaryDark, "#115E59"),
            (CheckingColors.accentBgSoft, "#CCFBF1"),
            (CheckingColors.teal, "#0F766E"),
            (CheckingColors.tealLight, "#CCFBF1"),
            (CheckingColors.accident, "#C8222A"),
            (CheckingColors.textStrong, "#0F172A"),
            (CheckingColors.textStrongAlt, "#1F2937"),
            (CheckingColors.textMuted, "#475569"),
            (CheckingColors.textMutedLight, "#526176"),
            (CheckingColors.textMutedSoft, "#94A3B8"),
            (CheckingColors.success, "#166534"),
            (CheckingColors.warning, "#92400E"),
            (CheckingColors.error, "#B42318"),
            (CheckingColors.errorVivid, "#FF0000"),
            (CheckingColors.activityWarning, "#EA580C"),
            (CheckingColors.activityInfo, "#1E40AF"),
            (CheckingColors.surfaceStart, "#F7F8FA"),
            (CheckingColors.surfaceEnd, "#EEF2F7"),
            (CheckingColors.headerBg, "#0F766E"),
            (CheckingColors.onPrimary, "#FFFFFF"),
            (CheckingColors.cardBg, "#FFFFFF"),
            (CheckingColors.cardTint, "#F8FAFC"),
            (CheckingColors.divider, "#E2E8F0"),
            (CheckingColors.inputBg, "#F8FAFC"),
            (CheckingColors.inputBorder, "#CBD5E1"),
            (CheckingColors.fieldPendingBorder, "#F97316"),
            (CheckingColors.fieldPendingGlow, "#FB923C"),
            (CheckingColors.fieldAuthedBorder, "#16A34A"),
            (CheckingColors.fieldAuthedGlow, "#22C55E"),
            (CheckingColors.choiceSelectedBg, "#E6F2F0"),
            (CheckingColors.transportChoiceBgStart, "#9ED8FF"),
            (CheckingColors.transportChoiceBgEnd, "#6BBDFF"),
            (CheckingColors.transportChoiceBorder, "#7DC8FF"),
            (CheckingColors.latestBorder, "#16A34A"),
            (CheckingColors.latestBg, "#DCFCE7"),
            (CheckingColors.locationSuccess, "#0F766E"),
            (CheckingColors.locationError, "#B42318"),
            (CheckingColors.locationMuted, "#94A3B8"),
            (CheckingColors.accidentRowRed, "#FF0000"),
            (CheckingColors.accidentRowYellow, "#FFFF00"),
            (CheckingColors.accidentRowTurquoise, "#00CED1"),
            (CheckingColors.accidentRowLightGreen, "#90EE90"),
            (CheckingColors.accidentRowLightGray, "#D3D3D3"),
            (CheckingColors.accidentRowLightBlue, "#ADD8E6"),
        ]
        for (token, hex) in table {
            XCTAssertEqual(token, Color(hex: hex), "token deveria ser \(hex)")
        }
    }

    func test_everyPaletteFieldMatchesExpectedHex() {
        let n = CheckingPalette.normal
        XCTAssertEqual(n.primary, Color(hex: "#0F766E"))
        XCTAssertEqual(n.onPrimary, Color(hex: "#FFFFFF"))
        XCTAssertEqual(n.primaryContainer, Color(hex: "#CCFBF1"))
        XCTAssertEqual(n.onPrimaryContainer, Color(hex: "#115E59"))
        XCTAssertEqual(n.secondary, Color(hex: "#0F766E"))
        XCTAssertEqual(n.onSecondary, Color(hex: "#FFFFFF"))
        XCTAssertEqual(n.surface, Color(hex: "#F7F8FA"))
        XCTAssertEqual(n.onSurface, Color(hex: "#0F172A"))
        XCTAssertEqual(n.background, Color(hex: "#F7F8FA"))
        XCTAssertEqual(n.onBackground, Color(hex: "#0F172A"))
        XCTAssertEqual(n.error, Color(hex: "#B42318"))
        XCTAssertEqual(n.onError, Color(hex: "#FFFFFF"))
        XCTAssertEqual(n.outline, Color(hex: "#CBD5E1"))
        XCTAssertEqual(n.outlineVariant, Color(hex: "#E2E8F0"))
    }

    func test_textBackgroundPairsMeetWCAGAA() {
        let pairs = [
            ("0F172A", "FFFFFF"), // texto principal / card
            ("526176", "FFFFFF"), // texto secundário / card
            ("0F172A", "E6F2F0"), // escolha selecionada
            ("FFFFFF", "0F766E"), // botão primário
            ("FFFFFF", "115E59"), // gradiente primário escuro
            ("FFFFFF", "C8222A"), // botão de acidente
        ]
        for (foreground, background) in pairs {
            XCTAssertGreaterThanOrEqual(
                contrastRatio(foreground, background), 4.5,
                "contraste insuficiente #\(foreground) / #\(background)")
        }
    }

    func test_splashMotionPolicyRemovesAnimationAndLongWait() {
        XCTAssertEqual(SplashMotionPolicy.animationDuration(reduceMotion: true), 0)
        XCTAssertEqual(SplashMotionPolicy.finishDelay(reduceMotion: true), 0.2)
        XCTAssertEqual(SplashMotionPolicy.animationDuration(reduceMotion: false), 1)
        XCTAssertEqual(SplashMotionPolicy.finishDelay(reduceMotion: false), 1.45)
    }

    private func contrastRatio(_ first: String, _ second: String) -> Double {
        let values = [relativeLuminance(first), relativeLuminance(second)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }

    private func relativeLuminance(_ hex: String) -> Double {
        let components = Color.rgbaComponents(hex: hex)
        let channels = [components.r, components.g, components.b].map { channel in
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}
