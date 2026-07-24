import CoreGraphics

/// Tokens de dimensão — port 1:1 de presentation/theme/Tokens.kt. `dp`→`pt` (1:1, ambos independentes de
/// densidade). Ver port_spec_ui_design_system §3.
enum Tokens {
    // Layout
    static let headerHeight: CGFloat = 64
    static let mainHeaderHeight: CGFloat = 48
    static let cardMaxWidth: CGFloat = 680
    static let cardRadius: CGFloat = 16
    static let cardRadiusLarge: CGFloat = 22
    static let controlHeight: CGFloat = 40
    static let controlRadius: CGFloat = 12
    static let controlRadiusLarge: CGFloat = 14

    // Spacing
    static let sectionGap: CGFloat = 12
    static let sectionGapLarge: CGFloat = 16
    static let itemGap: CGFloat = 8
    static let cardPadding: CGFloat = 20
    static let cardPaddingSmall: CGFloat = 16
    static let inputPaddingHorizontal: CGFloat = 14
    static let inputPaddingVertical: CGFloat = 12
    static let buttonPaddingHorizontal: CGFloat = 20
    static let buttonPaddingVertical: CGFloat = 12

    // Elevation (sombra) — calibrar a sombra SwiftUI equivalente por snapshot (§3)
    static let cardElevation: CGFloat = 8
    static let dialogElevation: CGFloat = 8

    // Ícones
    static let iconDefault: CGFloat = 24
    static let iconSmall: CGFloat = 20
    static let iconLarge: CGFloat = 28
}
