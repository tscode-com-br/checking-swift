import SwiftUI

/// Header da tela principal — port do header de `CheckScreen` (§6.4): 64pt, fundo teal, `spacedBy 10`,
/// logo 36×28pt + texto da marca (`titleLarge` ExtraBold, tracking -0.5, branco).
struct CheckHeader: View {
    /// `t("auth.brand")` = "Checking".
    var brand: String = "Checking"

    var body: some View {
        ZStack {
            CheckingColors.headerBg
            HStack(spacing: 10) {
                CheckingLogoMark(color: CheckingColors.onPrimary)
                    .frame(width: 36, height: 28)
                Text(brand)
                    .checkingText(CheckingTypography.headerBrand)   // ExtraBold + tracking -0.5
                    .foregroundStyle(CheckingColors.onPrimary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Tokens.headerHeight)
    }
}
