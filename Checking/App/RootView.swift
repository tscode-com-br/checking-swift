import SwiftUI

/// Raiz de navegação — port do fluxo `MainActivity`/`CheckingNavHost`: Splash animado → CHECK (§6/§10/§15).
/// Transporte e Acidente NÃO são rotas — são overlays dentro do Check (preservam o estado por baixo, §9).
struct RootView: View {
    @Environment(\.appEnvironment) private var env
    @State private var showSplash = true

    var body: some View {
        Group {
            if showSplash {
                AppSplashScreen(onFinished: { showSplash = false })
                    .transition(.opacity)
            } else {
                // Shell do CheckScreen (§6). As SEÇÕES reais (§8) e o wiring do `CheckViewModel` vêm nas
                // próximas sub-slices; por ora o corpo do card é um placeholder.
                CheckScreenShell(accidentActive: false, banner: { EmptyView() }, cardBody: { CardBodyPlaceholder() })
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showSplash)
    }
}

/// Placeholder do corpo do `CheckCard` até as seções (§8) serem portadas. Usa tokens reais p/ validar o
/// design system; NÃO é o conteúdo final.
private struct CardBodyPlaceholder: View {
    @Environment(\.appEnvironment) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.sectionGap) {
            Text("Checking")
                .checkingText(CheckingTypography.titleMedium)
                .foregroundStyle(CheckingColors.textStrong)
            Text(env.apiConfig.baseURL.absoluteString)
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.textMutedLight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Splash") {
    AppSplashScreen(onFinished: {})
}

#Preview("Shell") {
    CheckScreenShell(accidentActive: false, banner: { EmptyView() }, cardBody: { CardBodyPlaceholder() })
        .environment(\.appEnvironment, .preview)
}

#Preview("Root") {
    RootView().environment(\.appEnvironment, .preview)
}
