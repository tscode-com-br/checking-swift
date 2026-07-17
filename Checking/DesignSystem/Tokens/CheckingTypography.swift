import SwiftUI

/// Um estilo de texto — tamanho/peso/tracking EXATOS de Type.kt; `lineHeight` como metadado (o SwiftUI
/// aplica espaçamento ADICIONAL entre linhas, não altura total, então aproximamos `lineHeight - size`;
/// calibrar por snapshot, §4/§14). Fonte padrão do sistema (Material default); Arimo só no splash (§12).
struct CheckingTextStyle: Sendable, Equatable {
    let size: CGFloat
    let weight: Font.Weight
    let lineHeight: CGFloat
    let tracking: CGFloat
    var font: Font { .system(size: size, weight: weight) }
}

/// Escala tipográfica — port 1:1 de `CheckingTypography` (Type.kt). Ver port_spec_ui_design_system §4.
enum CheckingTypography {
    static let titleLarge = CheckingTextStyle(size: 22, weight: .bold, lineHeight: 28, tracking: 0)
    static let titleMedium = CheckingTextStyle(size: 18, weight: .semibold, lineHeight: 24, tracking: 0)
    static let titleSmall = CheckingTextStyle(size: 15, weight: .semibold, lineHeight: 20, tracking: 0)
    static let bodyLarge = CheckingTextStyle(size: 15, weight: .regular, lineHeight: 22, tracking: 0)
    static let bodyMedium = CheckingTextStyle(size: 14, weight: .regular, lineHeight: 20, tracking: 0)
    static let bodySmall = CheckingTextStyle(size: 13, weight: .regular, lineHeight: 18, tracking: 0)
    static let labelLarge = CheckingTextStyle(size: 14, weight: .bold, lineHeight: 20, tracking: 0.1)
    static let labelMedium = CheckingTextStyle(size: 12, weight: .semibold, lineHeight: 16, tracking: 0.5)
    static let labelSmall = CheckingTextStyle(size: 11, weight: .semibold, lineHeight: 16, tracking: 0.5)

    /// Override do brand no header: `titleLarge` mas ExtraBold + tracking -0.5 (fácil de perder, §4).
    static let headerBrand = CheckingTextStyle(size: 22, weight: .heavy, lineHeight: 28, tracking: -0.5)
}

extension View {
    /// Aplica um `CheckingTextStyle` (fonte + tracking + espaçamento de linha aproximado).
    func checkingText(_ style: CheckingTextStyle) -> some View {
        self.font(style.font)
            .tracking(style.tracking)
            .lineSpacing(max(0, style.lineHeight - style.size))
    }
}
