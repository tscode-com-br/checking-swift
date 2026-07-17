import SwiftUI

/// Shell da tela principal — port da estrutura de `CheckScreen` (§6, de fora p/ dentro):
/// `ProvideAccidentTheme` → gradiente `#F7F8FA→#EEF2F7` → watermark Petrobras (0.06, 78%, centro) → header →
/// `AccidentBanner` (slot) → corpo rolável com um único `CheckCard` (slot das seções, §8).
///
/// Genérico nos slots (`banner`/`cardBody`) — o wiring do `CheckViewModel` real e as seções vêm nas próximas
/// sub-slices; aqui é o esqueleto de layout, fiel ao Compose.
struct CheckScreenShell<Banner: View, CardBody: View>: View {
    var accidentActive: Bool = false
    @ViewBuilder var banner: () -> Banner
    @ViewBuilder var cardBody: () -> CardBody

    var body: some View {
        ZStack {
            // Fundo: gradiente vertical (surfaceStart → surfaceEnd), sob a status bar.
            LinearGradient(colors: [CheckingColors.surfaceStart, CheckingColors.surfaceEnd],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            // Watermark Petrobras — centralizada, 78% da largura, opacity 0.06 (sensível a marca — §6.3).
            Image("PetrobrasWatermark")
                .resizable()
                .scaledToFit()
                .opacity(0.06)
                .containerRelativeFrame(.horizontal) { width, _ in width * 0.78 }
                .accessibilityHidden(true)

            // Header + banner + corpo rolável (respeitam a safe area = `systemBarsPadding` do Kotlin).
            VStack(spacing: 0) {
                CheckHeader()
                banner()
                ScrollView {
                    CheckCard { cardBody() }
                        .padding(Tokens.sectionGap)
                }
            }
        }
        .provideAccidentTheme(active: accidentActive)
        .contentShape(Rectangle())
        .onTapGesture { Self.dismissKeyboard() }   // tap no fundo limpa o foco (§6.2)
    }

    /// Fecha o teclado (equivalente ao `focusManager.clearFocus()`). Sem campos ainda; o foco por-campo
    /// (`@FocusState`) entra com o `AuthRow`/fieldsets na próxima sub-slice.
    private static func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
