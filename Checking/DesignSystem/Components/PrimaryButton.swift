import SwiftUI

/// Botão principal da tela de check — teal, label bold, raio/altura derivados dos tokens do Compose.
struct PrimaryButton: View {
    let text: String
    let action: () -> Void
    var enabled = true

    var body: some View {
        Button(action: action) {
            Text(text)
                .checkingText(CheckingTypography.labelLarge)
                .foregroundStyle(CheckingColors.onPrimary)
                .padding(.horizontal, Tokens.buttonPaddingHorizontal)
                .frame(maxWidth: .infinity, minHeight: Tokens.controlHeight)
                // O formato visual também define a região interativa. Sem este contentShape,
                // algumas combinações de ScrollView/teclado tratavam somente o miolo do texto
                // como alvo confiável, apesar de o gradiente ocupar toda a largura.
                .contentShape(Rectangle())
                .background(
                    LinearGradient(
                        colors: enabled
                            ? [CheckingColors.primary, CheckingColors.primaryDark]
                            : [CheckingColors.primary.opacity(0.38), CheckingColors.primaryDark.opacity(0.38)],
                        startPoint: .leading,
                        endPoint: .trailing))
                .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: Tokens.controlHeight)
        .contentShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
        .disabled(!enabled)
        .accessibilityAddTraits(.isButton)
    }
}
