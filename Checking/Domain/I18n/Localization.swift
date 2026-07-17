import Foundation

/// i18n MÍNIMO dos slices de auth/acidente — port parcial de `t()`/`i18nText`. O catálogo completo (6
/// idiomas, fallback per-key, `KnownApiMessages`) vem no slice de i18n. Chaves desconhecidas retornam a
/// própria chave (determinístico: ViewModel e teste usam a MESMA função, então batem). Ver port_spec_i18n.
private let ptStrings: [String: String] = [
    "auth.awaitingApproval": "Aguardando aprovação de cadastro.",
    "auth.registrationQueueFull": "Fila de cadastro cheia. Informe ao administrador do sistema.",
    "accident.notification.bannerTemplate": "Acidente ativo em {project}.",
    "accident.wizard.conflictAlreadyActive": "Já existe um acidente ativo.",
    "accident.emergency.callInitiated": "Chamada de emergência iniciada: {label}.",
    "accident.emergency.alreadyCalled": "Chamada de emergência já acionada.",
    "accident.emergency.callFailed": "Falha ao acionar a chamada de emergência.",
    "accident.video.sending": "Enviando vídeo…",
    "accident.video.sent": "Vídeo enviado.",
    "accident.video.error": "Falha ao enviar o vídeo.",
    "autoActivities.notification.brandTitle": "Checking",
    "autoActivities.notification.checkinMessage": "Check-In realizado.",
    "autoActivities.notification.checkoutMessage": "Check-Out realizado.",
    "autoActivities.notification.pauseStartMessage": "Checking em pausa.",
    "autoActivities.notification.pauseEndMessage": "Checking em atividade.",
    "autoActivities.notification.accidentMessage": "Checking: acidente reportado!",
    "autoActivities.notification.reauthTitle": "Checking — Reautenticação necessária",
    "autoActivities.notification.reauthBody": "Abra o aplicativo para entrar novamente.",
]

func t(_ key: String, lang: String = "pt") -> String {
    ptStrings[key] ?? key
}

/// Variante com interpolação `{token}` — port de `t(key, mapOf(...))`. Só interpola se a chave existir
/// no catálogo (fallback-to-key não tem template pra interpolar).
func t(_ key: String, _ tokens: [String: String], lang: String = "pt") -> String {
    guard var text = ptStrings[key] else { return key }
    for (token, value) in tokens { text = text.replacingOccurrences(of: "{\(token)}", with: value) }
    return text
}

/// Localiza uma mensagem crua do servidor — port de `KnownApiMessages.localizeApiMessage` (match byte-exato
/// no slice de i18n). Aqui passthrough (não asserido pelos testes de auth).
func localizeApiMessage(_ message: String, lang: String = "pt") -> String { message }

/// Resolve o idioma inicial (port mínimo de `resolveInitialLanguageCode`): guardado, senão "pt" (device no i18n slice).
func resolveInitialLanguageCode(_ stored: String?) -> String {
    let s = stored ?? ""
    return s.isEmpty ? "pt" : s
}
