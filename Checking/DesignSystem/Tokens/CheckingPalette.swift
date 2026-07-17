import SwiftUI

/// Esquema de cores semântico — port de `lightColorScheme` (Theme.kt), com o swap de acidente (§5). O
/// resolvedor (`resolve(accidentActive:)`) é a lógica PURA e testável; a UI lê via `@Environment(\.checkingPalette)`.
struct CheckingPalette: Sendable, Equatable {
    let primary: Color
    let onPrimary: Color
    let primaryContainer: Color
    let onPrimaryContainer: Color
    let secondary: Color
    let onSecondary: Color
    let surface: Color
    let onSurface: Color
    let background: Color
    let onBackground: Color
    let error: Color
    let onError: Color
    let outline: Color
    let outlineVariant: Color

    /// Esquema normal (teal) — port de `CheckingColorScheme`.
    static let normal = CheckingPalette(
        primary: CheckingColors.primary,
        onPrimary: CheckingColors.onPrimary,
        primaryContainer: CheckingColors.accentBgSoft,
        onPrimaryContainer: CheckingColors.primaryDark,
        secondary: CheckingColors.teal,
        onSecondary: CheckingColors.onPrimary,
        surface: CheckingColors.surfaceStart,
        onSurface: CheckingColors.textStrong,
        background: CheckingColors.surfaceStart,
        onBackground: CheckingColors.textStrong,
        error: CheckingColors.error,
        onError: CheckingColors.onPrimary,
        outline: CheckingColors.inputBorder,
        outlineVariant: CheckingColors.divider)

    /// Esquema de acidente (vermelho) — port de `AccidentColorScheme`; troca primary/containers/secondary.
    /// ⚠️ O `AccidentColorScheme` do Kotlin NÃO seta `outline`/`outlineVariant`, então eles caem no **default
    /// baseline do Material 3** (`#79747E`/`#CAC4D0`) — NÃO nos valores do app (inputBorder/divider). Reproduzir
    /// o baseline M3 é o fiel (achado da revisão): a borda dos OutlinedTextField em modo acidente é a M3, não a teal.
    static let accident = CheckingPalette(
        primary: CheckingColors.accident,
        onPrimary: CheckingColors.onPrimary,
        primaryContainer: Color(hex: "#FDE7E9"),
        onPrimaryContainer: Color(hex: "#8C1A20"),
        secondary: CheckingColors.accident,
        onSecondary: CheckingColors.onPrimary,
        surface: CheckingColors.surfaceStart,
        onSurface: CheckingColors.textStrong,
        background: CheckingColors.surfaceStart,
        onBackground: CheckingColors.textStrong,
        error: CheckingColors.error,
        onError: CheckingColors.onPrimary,
        outline: Color(hex: "#79747E"),          // Material 3 baseline (NeutralVariant50) — não sobrescrito no Kotlin
        outlineVariant: Color(hex: "#CAC4D0"))   // Material 3 baseline (NeutralVariant80)

    static func resolve(accidentActive: Bool) -> CheckingPalette { accidentActive ? .accident : .normal }
}

private struct CheckingPaletteKey: EnvironmentKey {
    static let defaultValue = CheckingPalette.normal
}

extension EnvironmentValues {
    /// Paleta corrente (normal/acidente) — port do `LocalAccidentModeActive`/`MaterialTheme.colorScheme`.
    var checkingPalette: CheckingPalette {
        get { self[CheckingPaletteKey.self] }
        set { self[CheckingPaletteKey.self] = newValue }
    }
}

extension View {
    /// Envolve a subárvore com a paleta de acidente/normal — port de `CheckingTheme(accidentModeActive:)` /
    /// `ProvideAccidentTheme(active:)`. Coloque no topo da tela (§6).
    func provideAccidentTheme(active: Bool) -> some View {
        environment(\.checkingPalette, CheckingPalette.resolve(accidentActive: active))
    }
}
