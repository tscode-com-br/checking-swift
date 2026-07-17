import SwiftUI

extension Color {
    /// Cor a partir de hex `#RRGGBB` / `RRGGBB` / `#AARRGGBB` (sRGB) — espelha os tokens ARGB de Color.kt
    /// (o Kotlin usa `Color(0xFFRRGGBB)`, alpha no byte mais alto).
    init(hex: String) {
        let c = Color.rgbaComponents(hex: hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    /// Componentes 0...1 — função PURA e testável (o `Color` do SwiftUI não expõe componentes p/ asserção).
    static func rgbaComponents(hex: String) -> (r: Double, g: Double, b: Double, a: Double) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return (0, 0, 0, 1) }
        func channel(_ shift: UInt64) -> Double { Double((value >> shift) & 0xFF) / 255 }
        switch s.count {
        case 8:  return (channel(16), channel(8), channel(0), channel(24))   // AARRGGBB
        case 6:  return (channel(16), channel(8), channel(0), 1)              // RRGGBB
        default: return (0, 0, 0, 1)
        }
    }
}
