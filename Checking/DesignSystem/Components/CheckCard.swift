import SwiftUI

/// O grande cartão branco que segura tudo — port de `CheckCard` (CheckCard.kt / §7).
/// maxWidth 680, corner 16, bg branco, sombra (elevation 8), borda 1pt teal@0.18, padding 20; centralizado.
struct CheckCard<Content: View>: View {
    var containerColor: Color = CheckingColors.cardBg
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(Tokens.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(containerColor)
            // `.circular` (não `.continuous`): o `RoundedCornerShape` do Compose desenha arcos circulares,
            // não o squircle da Apple (achado da revisão — fidelidade de canto).
            .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .circular))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .circular)
                    .stroke(CheckingColors.teal.opacity(0.18), lineWidth: 1))
            // Material elevation 8dp → sombra aproximada (calibrar por snapshot, §3).
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
            .frame(maxWidth: Tokens.cardMaxWidth)         // widthIn(max = 680)
            .frame(maxWidth: .infinity, alignment: .center)   // Box(fillMaxWidth, center)
    }
}

/// Painel interno tingido (history/notification/location) DENTRO do `CheckCard` — port de `TintedPanel`.
/// corner (controlRadius+2 = 14), bg #F8FAFC, borda 1pt teal@0.16, padding h12/v10.
struct TintedPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Tokens.controlRadius + 2, style: .circular)   // arco circular (Compose), não squircle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }   // Column (arranjo default = 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(CheckingColors.cardTint)
            .clipShape(shape)
            .overlay(shape.stroke(CheckingColors.teal.opacity(0.16), lineWidth: 1))
    }
}
