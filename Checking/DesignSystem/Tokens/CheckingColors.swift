import SwiftUI

/// Tokens de cor da marca — port 1:1 de presentation/theme/Color.kt (hex exatos). Ver port_spec_ui_design_system §2.
/// Alpha achatado no Kotlin mantido opaco (CardTint 0.9, ChoiceSelectedBg 0.08, LatestBg 0.76 — §2 nota).
enum CheckingColors {
    // Brand
    static let primary = Color(hex: "#0F766E")           // teal — primary/header/splash bg
    static let primaryDark = Color(hex: "#115E59")       // teal escuro — gradiente/onPrimaryContainer
    static let accentBgSoft = Color(hex: "#CCFBF1")      // primaryContainer / teal-light
    static let teal = Color(hex: "#0F766E")
    static let tealLight = Color(hex: "#CCFBF1")
    static let accident = Color(hex: "#C8222A")          // vermelho de acidente/emergência

    // Texto
    static let textStrong = Color(hex: "#0F172A")
    static let textStrongAlt = Color(hex: "#1F2937")
    static let textMuted = Color(hex: "#475569")
    static let textMutedLight = Color(hex: "#526176")
    static let textMutedSoft = Color(hex: "#94A3B8")

    // Estados
    static let success = Color(hex: "#166534")
    static let warning = Color(hex: "#92400E")
    static let error = Color(hex: "#B42318")
    static let errorVivid = Color(hex: "#FF0000")

    // Severidade do log de atividades
    static let activityWarning = Color(hex: "#EA580C")   // orange-600
    static let activityInfo = Color(hex: "#1E40AF")      // blue-800

    // Superfícies
    static let surfaceStart = Color(hex: "#F7F8FA")
    static let surfaceEnd = Color(hex: "#EEF2F7")
    static let headerBg = Color(hex: "#0F766E")
    static let onPrimary = Color(hex: "#FFFFFF")
    static let cardBg = Color(hex: "#FFFFFF")
    static let cardTint = Color(hex: "#F8FAFC")          // era rgba(248,250,252,0.9) — achatado
    static let divider = Color(hex: "#E2E8F0")
    static let inputBg = Color(hex: "#F8FAFC")
    static let inputBorder = Color(hex: "#CBD5E1")

    // Glow chave/senha (laranja=pendente, verde=autenticado)
    static let fieldPendingBorder = Color(hex: "#F97316")
    static let fieldPendingGlow = Color(hex: "#FB923C")
    static let fieldAuthedBorder = Color(hex: "#16A34A")
    static let fieldAuthedGlow = Color(hex: "#22C55E")

    // Escolha / transporte
    static let choiceSelectedBg = Color(hex: "#E6F2F0")  // era rgba(15,118,110,0.08)
    static let transportChoiceBgStart = Color(hex: "#9ED8FF")
    static let transportChoiceBgEnd = Color(hex: "#6BBDFF")
    static let transportChoiceBorder = Color(hex: "#7DC8FF")

    // Destaque "última atividade"
    static let latestBorder = Color(hex: "#16A34A")
    static let latestBg = Color(hex: "#DCFCE7")          // era rgba(220,252,231,0.76)

    // Valor de localização
    static let locationSuccess = Color(hex: "#0F766E")
    static let locationError = Color(hex: "#B42318")
    static let locationMuted = Color(hex: "#94A3B8")

    // Acentos de linha de acidente (se a tabela de situação aparecer)
    static let accidentRowRed = Color(hex: "#FF0000")
    static let accidentRowYellow = Color(hex: "#FFFF00")
    static let accidentRowTurquoise = Color(hex: "#00CED1")
    static let accidentRowLightGreen = Color(hex: "#90EE90")
    static let accidentRowLightGray = Color(hex: "#D3D3D3")
    static let accidentRowLightBlue = Color(hex: "#ADD8E6")
}
