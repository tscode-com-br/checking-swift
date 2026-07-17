import SwiftUI

/// Geometria do logo do Checking — fonte ÚNICA compartilhada pelo splash (`AppSplashScreen`) e pelo header
/// (`CheckingLogoMark`). Port 1:1 de `ic_checking_logo.xml` (== geometria do splash): viewBox 220×170,
/// `translate(18,16)` externo + `rotate(-12°)` pivot (74,70). Ver port_spec_ui_design_system §6/§10.
enum CheckingLogoGeometry {
    static let card = Path(roundedRect: CGRect(x: 12, y: 8, width: 120, height: 120), cornerRadius: 18)
    static let photo = Path(roundedRect: CGRect(x: 28, y: 30, width: 34, height: 28), cornerRadius: 4)
    static let nameLine = line(from: CGPoint(x: 28, y: 74), to: CGPoint(x: 64, y: 74))
    static let roleLine = line(from: CGPoint(x: 28, y: 96), to: CGPoint(x: 56, y: 96))
    static let arc1 = curve(from: CGPoint(x: 154, y: 30), to: CGPoint(x: 180, y: 56),
                            c1: CGPoint(x: 167, y: 34), c2: CGPoint(x: 176, y: 43))
    static let arc2 = curve(from: CGPoint(x: 166, y: 18), to: CGPoint(x: 202, y: 56),
                            c1: CGPoint(x: 184, y: 24), c2: CGPoint(x: 197, y: 38))
    static let checkmark: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 92, y: 78))
        p.addLine(to: CGPoint(x: 118, y: 104))
        p.addLine(to: CGPoint(x: 162, y: 44))
        return p
    }()

    static func line(from: CGPoint, to: CGPoint) -> Path {
        var p = Path(); p.move(to: from); p.addLine(to: to); return p
    }
    static func curve(from: CGPoint, to: CGPoint, c1: CGPoint, c2: CGPoint) -> Path {
        var p = Path(); p.move(to: from); p.addCurve(to: to, control1: c1, control2: c2); return p
    }

    /// Escala p/ um dado tamanho: `min(w/220, h/170)`.
    static func scale(for size: CGSize) -> CGFloat { min(size.width / 220, size.height / 170) }

    /// Transformação viewBox→canvas aplicada a um `GraphicsContext` (mesma sequência do Canvas do Kotlin).
    static func applyTransform(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let s = scale(for: size)
        ctx.translateBy(x: (size.width - 220 * s) / 2, y: (size.height - 170 * s) / 2)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: 18, y: 16)
        ctx.translateBy(x: 74, y: 70)
        ctx.rotate(by: .degrees(-12))
        ctx.translateBy(x: -74, y: -70)
    }

    /// A MESMA transformação como `CGAffineTransform` — p/ um `Shape` casar com o Canvas.
    static func transform(for size: CGSize) -> CGAffineTransform {
        let s = scale(for: size)
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: (size.width - 220 * s) / 2, y: (size.height - 170 * s) / 2)
        t = t.scaledBy(x: s, y: s)
        t = t.translatedBy(x: 18, y: 16)
        t = t.translatedBy(x: 74, y: 70)
        t = t.rotated(by: -12 * .pi / 180)
        t = t.translatedBy(x: -74, y: -70)
        return t
    }

    /// Desenha o logo COMPLETO (checkmark inteiro) num `GraphicsContext` já dimensionado.
    static func drawFull(_ context: GraphicsContext, _ size: CGSize, color: Color) {
        var ctx = context
        applyTransform(&ctx, size)
        let shading = GraphicsContext.Shading.color(color)
        ctx.stroke(card, with: shading, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
        ctx.fill(photo, with: shading)
        ctx.stroke(nameLine, with: shading, style: StrokeStyle(lineWidth: 10, lineCap: .round))
        ctx.stroke(roleLine, with: shading, style: StrokeStyle(lineWidth: 10, lineCap: .round))
        ctx.stroke(arc1, with: shading, style: StrokeStyle(lineWidth: 8, lineCap: .round))
        ctx.stroke(arc2, with: shading, style: StrokeStyle(lineWidth: 8, lineCap: .round))
        ctx.stroke(checkmark, with: shading, style: StrokeStyle(lineWidth: 20, lineCap: .round, lineJoin: .round))
    }
}

/// O logo do Checking (estático, completo) — port de `ic_checking_logo.xml`. Usado no header (36×28pt).
struct CheckingLogoMark: View {
    var color: Color = CheckingColors.onPrimary

    var body: some View {
        Canvas { context, size in
            CheckingLogoGeometry.drawFull(context, size, color: color)
        }
        .accessibilityHidden(true)
    }
}
