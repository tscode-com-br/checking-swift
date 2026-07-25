import Foundation

/// Overrides nativos do iOS em português. Os catálogos canônicos dos seis idiomas são gerados a partir
/// das mesmas fontes usadas pelo Android (`LocalizationCatalogs.generated.swift`). Overrides vencem o
/// catálogo portado para preservar terminologia e funcionalidades específicas desta interface.
private let ptStrings: [String: String] = [
    "auth.brand": "Checking",
    "auth.keyLabel": "Chave",
    "auth.passwordLabel": "Senha",
    "auth.keyPlaceholder": "Ex.: HR70",
    "auth.passwordPlaceholder": "3 a 10 caracteres",
    "auth.requestRegistrationButton": "Solicitar cadastro",
    "auth.openSettingsAria": "Abrir ajustes",
    "auth.showPasswordAria": "Mostrar senha",
    "auth.hidePasswordAria": "Ocultar senha",
    "auth.savedPasswordAria": "Senha salva e protegida",
    "auth.enterPasswordPrompt": "Digite sua senha para iniciar.",
    "auth.createPasswordPrompt": "Digite sua chave e crie uma senha.",
    "auth.awaitingApproval": "Aguardando aprovação de cadastro.",
    "auth.registrationQueueFull": "Fila de cadastro cheia. Informe ao administrador do sistema.",
    "history.lastCheckinLabel": "Último Check-In",
    "history.lastCheckoutLabel": "Último Check-Out",
    "history.today": "Hoje",
    "history.yesterday": "Ontem",
    "history.dialogTitleCheckin": "Histórico de Check-In",
    "history.dialogTitleCheckout": "Histórico de Check-Out",
    "history.colDate": "Data",
    "history.colTime": "Hora",
    "history.colActivity": "Atividade",
    "history.colLocal": "Local",
    "history.activityCheckin": "Check-In",
    "history.activityCheckout": "Check-Out",
    "history.loadingMessage": "Consultando histórico...",
    "history.loadError": "Não foi possível carregar o histórico.",
    "history.retry": "Tentar novamente",
    "history.empty": "Nenhum registro encontrado.",
    "history.back": "Voltar",
    "status.passwordVerifying": "Senha sendo verificada.",
    "status.authenticationCompleted": "Autenticação concluída.",
    "status.apiCommunicationFailure": "Não foi possível comunicar com o servidor.",
    "status.updatingApp": "Atualizando a aplicação...",
    "status.checkinCompleted": "Check-In concluído.",
    "status.checkoutCompleted": "Check-Out concluído.",
    "status.savedOffline": "Salvo offline. Será sincronizado quando houver conexão.",
    "status.submitFailed": "Não foi possível registrar o check-in/out neste momento.",
    "status.runningAutomaticActivitySequence": "Executando sequência de atividade automática...",
    "registration.sectionTitle": "Registro",
    "registration.checkinLabel": "Check-In",
    "registration.checkoutLabel": "Check-Out",
    "registration.transportLabel": "Transporte",
    "registration.informeTitle": "Assiduidade",
    "registration.informeNormalLabel": "Normal",
    "registration.informeRetroativoLabel": "Retroativo",
    "registration.submitButton": "Registrar",
    "registration.disableAutomaticActivitiesForManualSubmit": "Desative Atividades Automáticas para registrar manualmente.",
    "location.title": "Local",
    "location.waitingLabel": "Aguardando localização.",
    "location.refreshLabel": "Atualizar localização",
    "location.accuracyTemplate": "Precisão {accuracy}",
    "location.manualSelectPlaceholder": "Selecione um local",
    "location.selectManualLocation": "Selecione uma localização antes de registrar.",
    "projects.label": "Projetos",
    "projects.loadingProjects": "Carregando projetos...",
    "projects.noneAvailableShort": "Nenhum projeto disponível",
    "projects.noneAvailableSentence": "Nenhum projeto disponível.",
    "projects.noActiveProject": "O usuário não está cadastrado em nenhum projeto.",
    "passwordDialog.titleChange": "Alterar Senha",
    "passwordDialog.titleRegister": "Cadastrar Senha",
    "passwordDialog.oldPasswordLabel": "Senha Antiga",
    "passwordDialog.newPasswordLabel": "Nova Senha",
    "passwordDialog.confirmPasswordLabel": "Confirme Senha",
    "passwordDialog.backButton": "Voltar",
    "passwordDialog.submitChangeButton": "Alterar",
    "passwordDialog.submitRegisterButton": "Salvar",
    "passwordDialog.changingStatus": "Alterando senha...",
    "passwordDialog.savingStatus": "Salvando senha...",
    "passwordDialog.oldPasswordInvalid": "A senha antiga deve ter entre 3 e 10 caractéres.",
    "passwordDialog.newPasswordInvalid": "A nova senha deve ter entre 3 e 10 caractéres.",
    "passwordDialog.confirmMismatch": "A confirmação da nova senha não confere.",
    "passwordDialog.changeFailed": "Não foi possível alterar a senha.",
    "registrationDialog.title": "Solicitar Cadastro",
    "registrationDialog.keyLabel": "Chave",
    "registrationDialog.fullNameLabel": "Nome Completo",
    "registrationDialog.projectsLabel": "Projetos",
    "registrationDialog.emailLabel": "E-Mail",
    "registrationDialog.emailPlaceholder": "Opcional",
    "registrationDialog.passwordLabel": "Senha",
    "registrationDialog.confirmPasswordLabel": "Confirma Senha",
    "registrationDialog.backButton": "Voltar",
    "registrationDialog.submitButton": "Enviar",
    "registrationDialog.loadingProjects": "Carregando projetos...",
    "registrationDialog.noProjectsAvailable": "Nenhum projeto está disponível no momento.",
    "registrationDialog.fullNameRequired": "Informe o nome completo.",
    "registrationDialog.emailInvalid": "Informe um e-mail válido ou deixe o campo em branco.",
    "registrationDialog.passwordInvalid": "A senha deve ter entre 3 e 10 caracteres.",
    "registrationDialog.confirmMismatch": "A confirmação da nova senha não confere.",
    "registrationDialog.submittingStatus": "Enviando solicitação de cadastro...",
    "registrationDialog.submitFailed": "Não foi possível enviar a solicitação de cadastro.",
    "projects.selectAtLeastOne": "Selecione ao menos um projeto.",
    "settings.title": "Ajustes",
    "settings.groupAutoActivities": "Atividades Automáticas",
    "settings.groupPreferences": "Preferências",
    "settings.groupHelp": "Ajuda",
    "settings.groupAccount": "Conta",
    "settings.statusOn": "Ativadas",
    "settings.statusAttention": "Atenção",
    "settings.statusOff": "Desativadas",
    "settings.notificationsLabel": "Notificações",
    "settings.activitiesLabel": "Atividades",
    "settings.resetPasswordLabel": "Alterar Senha",
    "settings.backButton": "Voltar",
    "settings.deleteAccountLabel": "Remover Cadastro",
    "settings.deleteAccountBlocked": "Não foi possível remover pelo aplicativo. Solicite pelo canal de privacidade.",
    "settings.deleteAccountFailed": "Não foi possível remover o cadastro. Verifique sua conexão e tente novamente.",
    "settings.deleteAccountConfirmTitle": "Remover Cadastro",
    "settings.deleteAccountConfirmBody": "Isto remove sua conta e apaga seus dados dos nossos servidores e deste dispositivo. Esta ação não pode ser desfeita. Deseja continuar?",
    "settings.deleteAccountConfirm": "Remover",
    "settings.deleteAccountCancel": "Cancelar",
    "autoActivities.title": "Atividades Automáticas",
    "autoActivities.explanation": "Quando habilitado, o Checking realiza check-in e check-out em segundo plano com base na localização. As coordenadas são usadas somente para identificar uma localização cadastrada do projeto.",
    "autoActivities.enable": "Habilitar Atividades Automáticas",
    "autoActivities.nudgeQuestion": "Quer que o Checking faça check-in e check-out automaticamente, com base na sua localização?",
    "autoActivities.nudgeActivate": "Ativar agora",
    "autoActivities.nudgeLater": "Agora não",
    "autoActivities.reviewPermissions": "Revisar permissões",
    "autoActivities.close": "Fechar",
    "autoActivities.enableFailed": "Não foi possível alterar as Atividades Automáticas.",
    "autoActivities.insufficientPermissions": "Conceda Notificações e Localização Precisa para ativar as atividades automáticas.",
    "autoActivities.reducedReliability": "Atividades ativas, mas a confiabilidade em segundo plano está reduzida. Conceda Localização Sempre e habilite a Atualização em 2º Plano.",
    "autoActivities.permNotifications": "Notificações",
    "autoActivities.permPreciseLocation": "Localização precisa",
    "autoActivities.permAlwaysLocation": "Localização Sempre",
    "autoActivities.permBackgroundRefresh": "Atualização em 2º Plano",
    "autoActivities.allowed": "Permitido",
    "autoActivities.notAllowed": "Não permitido",
    "autoActivities.openSettings": "Abrir Ajustes",
    "autoActivities.request": "Solicitar",
    "autoActivities.bgDisclosureTitle": "Uso de localização em segundo plano",
    "autoActivities.bgDisclosureBody": "O Checking usa sua localização mesmo em segundo plano para realizar automaticamente check-in e check-out nos locais cadastrados. Você pode recusar e continuar usando o registro manual.",
    "autoActivities.bgDisclosureAccept": "Entendi e permito",
    "autoActivities.bgDisclosureDecline": "Agora não",
    "scheduledPause.buttonLabel": "Pausa Programada",
    "scheduledPause.title": "Pausa Programada",
    "scheduledPause.explanation": "A pausa programada suspende as atividades automáticas durante o período informado e economiza bateria.",
    "scheduledPause.enable": "Ativar pausa programada.",
    "scheduledPause.from": "De:",
    "scheduledPause.to": "Até:",
    "scheduledPause.periodTitle": "Período da pausa",
    "scheduledPause.start": "Início",
    "scheduledPause.end": "Fim",
    "scheduledPause.overnightHint": "Se o fim for anterior ao início, a pausa continuará até o dia seguinte.",
    "scheduledPause.fullDaysTitle": "Pausar também em dias inteiros",
    "scheduledPause.saturday": "Sábado",
    "scheduledPause.sunday": "Domingo",
    "scheduledPause.suspendSaturdays": "Suspender aos sábados.",
    "scheduledPause.suspendSundays": "Suspender aos domingos.",
    "scheduledPause.close": "Fechar",
    "notifications.title": "Notificações",
    "notifications.intro": "Escolha quais acontecimentos do Checking devem gerar notificações.",
    "notifications.checkboxActivities": "Notificar quando uma atividade automática for realizada.",
    "notifications.checkboxScheduledPause": "Notificar o início e o fim da Pausa Programada.",
    "notifications.checkboxAccident": "Notificar quando houver um acidente reportado.",
    "notifications.backButton": "Voltar",
    "accident.button.report": "Reportar Acidente",
    "accident.button.reported": "Acidente Reportado",
    "accident.notification.bannerTemplate": "Acidente Reportado no projeto {project}!",
    "accident.wizard.selectProject": "Selecione o Projeto",
    "accident.wizard.selectLocation": "Local do Acidente",
    "accident.wizard.yourSituation": "Sua Situação:",
    "accident.wizard.confirmTitle": "Confirmação de Acidente",
    "accident.wizard.confirmTextTemplate": "Você está prestes a reportar um acidente na localização {location} do projeto {project}.",
    "accident.wizard.conflictAlreadyActive": "Já existe um acidente ativo no momento.",
    "accident.wizard.otherLocation": "Outro local",
    "accident.wizard.next": "Próximo",
    "accident.wizard.back": "Voltar",
    "accident.inquiry.title": "Estou em:",
    "accident.inquiry.safetyZone": "Zona de Segurança",
    "accident.inquiry.accidentZone": "Zona de Acidente",
    "accident.inquiry.imOk": "Estou bem.",
    "accident.inquiry.needHelp": "Preciso de Ajuda!",
    "accident.confirm.safety": "Você confirma que está fora de perigo?",
    "accident.confirm.accidentOk": "Você confirma que está na zona do acidente e que está fora de perigo?",
    "accident.confirm.help": "Você confirma que está na zona do acidente e que precisa de ajuda?",
    "accident.actions.title": "Ações de Emergência",
    "accident.actions.audioVideo": "Áudio e Vídeo",
    "accident.actions.reportNew": "Reportar Novo Acidente",
    "accident.actions.back": "Voltar",
    "accident.ack.title": "Acidente Reportado",
    "accident.ack.checkinReminder": "Realize check-in IMEDIATAMENTE, caso esteja no ambiente de trabalho.",
    "accident.ack.button": "Ciente",
    "accident.situationSent": "Situação atual enviada.",
    "accident.triggerEmergency": "Acionar Serviço de Emergência",
    "accident.description.title": "Descrição Detalhada",
    "accident.description.placeholder": "Descreva o ocorrido (opcional, máx. 500 caracteres)...",
    "accident.fallback.manualCheckin": "Situação de Acidente. Realize o check-in manual IMEDIATAMENTE.",
    "accident.emergency.callInitiated": "Ligação de emergência N.º {label} iniciada.",
    "accident.emergency.alreadyCalled": "A ligação de emergência já foi realizada.",
    "accident.emergency.callFailed": "Não foi possível acionar a ligação de emergência.",
    "accident.video.recording": "Gravando…",
    "accident.video.stopAndSend": "Parar e Enviar",
    "accident.video.sending": "Enviando o registro...",
    "accident.video.sent": "Registro enviado com sucesso.",
    "accident.video.error": "Erro: registro não enviado.",
    "accident.video.retry": "Tentar Novamente",
    "accident.video.permissionRequired": "É necessário permitir o acesso à câmera e ao microfone para gravar o vídeo.",
    "accident.video.openSettings": "Abrir Ajustes",
    "autoActivities.notification.brandTitle": "Checking",
    "autoActivities.notification.checkinMessage": "Check-In realizado.",
    "autoActivities.notification.checkoutMessage": "Check-Out realizado.",
    "autoActivities.notification.pauseStartMessage": "Checking em pausa.",
    "autoActivities.notification.pauseEndMessage": "Checking em atividade.",
    "autoActivities.notification.accidentMessage": "Checking: acidente reportado!",
    "autoActivities.notification.reauthTitle": "Checking — Reautenticação necessária",
    "autoActivities.notification.reauthBody": "Abra o aplicativo para entrar novamente.",
    "autoActivities.notification.lowAccuracyCheckinTitle": "Check-in - Falha!",
    "autoActivities.notification.lowAccuracyCheckoutTitle": "Check-out - Falha!",
    "autoActivities.notification.lowAccuracyGenericTitle": "Atividade automática - Falha!",
    "autoActivities.notification.lowAccuracyBody": "Baixa Precisão. Tentará novamente.",
]

let defaultLanguageCode = "pt"

struct LanguageEntry: Identifiable, Equatable, Sendable {
    let code: String
    let label: String
    let nativeLabel: String
    let localeIdentifier: String
    var id: String { code }
}

let supportedLanguages: [LanguageEntry] = [
    LanguageEntry(code: "zh", label: "Chinese", nativeLabel: "中文", localeIdentifier: "zh-CN"),
    LanguageEntry(code: "en", label: "English", nativeLabel: "English", localeIdentifier: "en-US"),
    LanguageEntry(code: "id", label: "Indonesian", nativeLabel: "Bahasa Indonesia", localeIdentifier: "id-ID"),
    LanguageEntry(code: "ms", label: "Malay", nativeLabel: "Bahasa Melayu", localeIdentifier: "ms-MY"),
    LanguageEntry(code: "pt", label: "Portuguese", nativeLabel: "Português", localeIdentifier: "pt-BR"),
    LanguageEntry(code: "tl", label: "Tagalog (Filipino)", nativeLabel: "Tagalog (Filipino)", localeIdentifier: "fil-PH"),
]

private let languageAliases = ["fil": "tl", "in": "id"]

/// Conteúdo editorial nativo do iOS usado como referência para cobertura dos demais idiomas.
/// A visibilidade interna permite que os testes impeçam a publicação de chaves sem tradução.
var iosPortugueseOverrideStrings: [String: String] {
    ptStrings.merging(contentPtStrings) { current, _ in current }
        .merging(iosManualPtStrings) { current, _ in current }
        .merging(aboutPtStrings) { current, _ in current }
}

let iosPlatformLocalizationOverrides: [String: [String: String]] = [
    "en": iosEnglishStrings,
    "zh": iosZhEditorialStrings,
    "ms": iosMsEditorialStrings,
    "id": iosIdEditorialStrings,
    "tl": iosTlEditorialStrings,
]

func resolveLanguageCode(_ languageCode: String?, fallback: String? = nil) -> String {
    let supportedCodes = Set(supportedLanguages.map(\.code))
    let explicitFallback = fallback != nil
    let resolvedFallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ?? defaultLanguageCode
    let normalized = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

    if normalized.isEmpty {
        if explicitFallback && resolvedFallback.isEmpty { return "" }
        return supportedCodes.contains(resolvedFallback) ? resolvedFallback : defaultLanguageCode
    }
    if supportedCodes.contains(normalized) { return normalized }

    let base = normalized.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? normalized
    let aliased = languageAliases[normalized] ?? languageAliases[base] ?? base
    if supportedCodes.contains(aliased) { return aliased }

    if explicitFallback && resolvedFallback.isEmpty { return "" }
    return supportedCodes.contains(resolvedFallback) ? resolvedFallback : defaultLanguageCode
}

func detectDeviceLanguageCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
    for preferredLanguage in preferredLanguages {
        let resolved = resolveLanguageCode(preferredLanguage, fallback: "")
        if !resolved.isEmpty { return resolved }
    }
    return defaultLanguageCode
}

func getLanguageEntry(_ code: String) -> LanguageEntry {
    let resolved = resolveLanguageCode(code)
    return supportedLanguages.first(where: { $0.code == resolved })
        ?? supportedLanguages.first(where: { $0.code == defaultLanguageCode })!
}

private func localizedTemplate(_ key: String, lang: String) -> String? {
    let resolved = resolveLanguageCode(lang)
    if resolved == defaultLanguageCode, let override = iosPortugueseOverrideStrings[key] { return override }
    if let override = iosPlatformLocalizationOverrides[resolved]?[key] { return override }
    if let translated = generatedLocalizationCatalogs[resolved]?[key] { return translated }
    return iosPortugueseOverrideStrings[key] ?? generatedLocalizationCatalogs[defaultLanguageCode]?[key]
}

func t(_ key: String, lang: String = defaultLanguageCode) -> String {
    localizedTemplate(key, lang: lang) ?? key
}

/// Variante com interpolação `{token}` — port de `t(key, mapOf(...))`. Só interpola se a chave existir
/// no catálogo (fallback-to-key não tem template pra interpolar).
func t(_ key: String, _ tokens: [String: String], lang: String = "pt") -> String {
    guard var text = localizedTemplate(key, lang: lang) else { return key }
    let tokenPattern = try? NSRegularExpression(pattern: #"\{([^}]+)\}"#)
    let matches = tokenPattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
    for match in matches.reversed() {
        guard let fullRange = Range(match.range(at: 0), in: text),
              let keyRange = Range(match.range(at: 1), in: text) else { continue }
        text.replaceSubrange(fullRange, with: tokens[String(text[keyRange])] ?? "")
    }
    return text
}

/// O servidor envia algumas mensagens em pt-BR. Este índice recupera a chave canônica e reapresenta a
/// mensagem no idioma ativo; texto desconhecido permanece intacto para não ocultar erros do backend.
private let knownPortugueseMessageIndex: [String: String] = {
    var index: [String: String] = [:]
    for (key, value) in generatedPtStrings { index[value] = key }
    for (key, value) in iosPortugueseOverrideStrings { index[value] = key }
    return index
}()

func localizeApiMessage(_ message: String, lang: String = defaultLanguageCode) -> String {
    let raw = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return "" }
    guard resolveLanguageCode(lang) != defaultLanguageCode else { return raw }
    if let key = knownPortugueseMessageIndex[raw] { return t(key, lang: lang) }

    let conflictPrefix = "Ja existe uma solicitacao de transporte ativa para "
    if raw == "Ja existe uma solicitacao de transporte ativa para essa data." {
        return t("transport.requestBuilder.conflictGeneric", lang: lang)
    }
    if raw.hasPrefix(conflictPrefix), raw.hasSuffix(".") {
        return t(
            "transport.requestBuilder.conflictByDate",
            ["serviceDateLabel": String(raw.dropFirst(conflictPrefix.count).dropLast())],
            lang: lang)
    }
    return raw
}

func resolveInitialLanguageCode(
    _ stored: String?,
    preferredLanguages: [String] = Locale.preferredLanguages
) -> String {
    if let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let resolved = resolveLanguageCode(stored, fallback: "")
        if !resolved.isEmpty { return resolved }
    }
    return detectDeviceLanguageCode(preferredLanguages: preferredLanguages)
}
