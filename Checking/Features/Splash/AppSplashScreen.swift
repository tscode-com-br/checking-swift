import SwiftUI

/// Splash — o logo do Checking sobre fundo teal, com UMA animação: o "V" do checkmark desenhado
/// progressivamente, como à mão. Port 1:1 de presentation/splash/AppSplashScreen.kt (§10). Coordenadas no
/// viewBox 220×170; `translate(18,16)` externo + `rotate(-12°)` pivot (74,70). Reduce Motion → estado final.
///
/// Os elementos estáticos vão num `Canvas` (uma renderização). O checkmark é um `Shape` separado com
/// `.trim` — o SwiftUI SÓ anima atributos animáveis (o `animatableData` do trim), não re-invoca um render
/// closure de `Canvas` por frame; por isso o trim fica no `Shape`, não no `Canvas` (achado HIGH da revisão).
struct AppSplashScreen: View {
    let onFinished: () -> Void

    @State private var progress: CGFloat = 0
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Frame fixo (300×232) → escala constante `min(w/220, h/170)`. O stroke do checkmark é em pontos de
    /// view, então escala explícita (o `Canvas` estático escala via contexto).
    static let canvasSize = CGSize(width: 300, height: 232)
    static let logoScale = min(canvasSize.width / 220, canvasSize.height / 170)

    var body: some View {
        ZStack {
            CheckingColors.headerBg.ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    Canvas { context, size in drawStatic(context, size) }
                    SplashCheckmark()
                        .trim(from: 0, to: progress)
                        .stroke(style: StrokeStyle(lineWidth: 20 * Self.logoScale, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(.white)
                }
                .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
                .accessibilityHidden(true)

                Text(Self.appVersion)
                    .font(.custom("Arimo-Regular", size: 12)).tracking(1)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, 8)
            }

            VStack {
                Spacer()
                VStack(spacing: 2) {
                    ForEach(Self.credits, id: \.self) { name in
                        Text(name)
                            .font(.custom("Arimo-Regular", size: 13.75)).tracking(1.5)   // labelSmall 11 + 25%
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 28)
            }
        }
        .onAppear(perform: start)
    }

    private func start() {
        if reduceMotion {
            progress = 1                                    // §13: Reduce Motion cai no estado final
        } else {
            // tween(1000ms, FastOutSlowInEasing) → curva Material exata cubic-bezier(0.4, 0, 0.2, 1).
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 1)) { progress = 1 }
        }
        // delay 450ms após a animação → onFinished (navega p/ CHECK). Guard contra dupla-chamada.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) {
            guard !finished else { return }
            finished = true
            onFinished()
        }
    }

    /// Elementos estáticos (branco) — desenhados uma vez SEM o checkmark (que é o `Shape` animado). Usa a
    /// geometria compartilhada (`CheckingLogoGeometry`), a mesma do header, p/ garantir fonte única.
    private func drawStatic(_ context: GraphicsContext, _ size: CGSize) {
        var ctx = context
        CheckingLogoGeometry.applyTransform(&ctx, size)
        let white = GraphicsContext.Shading.color(.white)
        ctx.stroke(CheckingLogoGeometry.card, with: white, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
        ctx.fill(CheckingLogoGeometry.photo, with: white)
        ctx.stroke(CheckingLogoGeometry.nameLine, with: white, style: StrokeStyle(lineWidth: 10, lineCap: .round))
        ctx.stroke(CheckingLogoGeometry.roleLine, with: white, style: StrokeStyle(lineWidth: 10, lineCap: .round))
        ctx.stroke(CheckingLogoGeometry.arc1, with: white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
        ctx.stroke(CheckingLogoGeometry.arc2, with: white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
    }

    /// Versão do app — espelha `BuildConfig.VERSION_NAME` (`CFBundleShortVersionString`).
    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }
    static let credits = ["Dilnei Schmidt", "Tamer Salmem", "Thiago Soares do Nascimento"]
}

/// O checkmark como `Shape` (viewBox `M92,78 L118,104 L162,44`, transformado) — `.trim` no Shape ANIMA (o
/// `animatableData` do trim), ao contrário de um trim dentro de um `Canvas`.
private struct SplashCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        CheckingLogoGeometry.checkmark.applying(CheckingLogoGeometry.transform(for: rect.size))
    }
}
