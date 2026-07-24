import SwiftUI

/// Header da tela principal — port do header de `CheckScreen` (§6.4): 64pt, fundo teal, `spacedBy 10`,
/// logo 36×28pt + texto da marca (`titleLarge` ExtraBold, tracking -0.5, branco).
struct CheckHeader: View {
    /// `t("auth.brand")` = "Checking".
    var brand: String = "Checking"

    var body: some View {
        HStack(spacing: 10) {
            CheckingLogoMark(color: CheckingColors.onPrimary)
                .frame(width: 36, height: 28)
            Text(brand)
                .checkingText(CheckingTypography.headerBrand)   // ExtraBold + tracking -0.5
                .foregroundStyle(CheckingColors.onPrimary)
        }
        // A safe area dos iPhones com Dynamic Island reserva espaço adicional abaixo da ilha.
        // O padding assimétrico compensa 4 pt e equilibra visualmente as margens superior/inferior.
        .padding(.top, 2)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, minHeight: Tokens.mainHeaderHeight)
        .background(CheckingColors.headerBg)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("check.header")
    }
}
