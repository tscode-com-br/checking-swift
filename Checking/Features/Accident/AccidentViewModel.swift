import Foundation
import Observation

/// Máquina de estado de acidente — port de presentation/accident/AccidentViewModel.kt (552 linhas).
/// `@Observable @MainActor`. Aplica as decisões D1–D4 (ver decision_log.md + port_spec_accident_video §0).
@Observable
@MainActor
final class AccidentViewModel {
    static let pollIntervalSeconds: UInt64 = 30
    static let autoCheckinRetries = 3
    static let autoCheckinDelaySeconds: UInt64 = 3

    private(set) var uiState: AccidentUiState
    private var languageCode = "pt"

    private let repository: any AccidentRepository
    let videoRecorder: any VideoRecording
    /// Seam do delay entre tentativas de auto-checkin — `TaskSleeper` em produção; nos testes, um sleeper
    /// instantâneo (mesmo seam usado pelo backoff de SSE) evita esperar os 6s reais (3 retries × 3s).
    private let sleeper: any Sleeping
    private let usesFixtureState: Bool

    private var chave = ""
    private var sseTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var videoIdempotencyKeys: [URL: String] = [:]
    /// Token de sessão — incrementado em `onLogin`/`onLogout`. Toda `Task` em voo que mutaria `uiState`
    /// captura o token vigente no início e o revalida antes de cada escrita; se a sessão mudou nesse
    /// meio-tempo (troca de chave, logout), a resposta tardia é descartada em vez de pisar no estado novo.
    private var sessionToken = 0

    /// D1: hook existe (espelha o Kotlin), mas fica **sem uso** — o Android nunca o conecta de verdade
    /// (lambda vazio em CheckScreen.kt). Não desligamos o automático após falha do auto-checkin.
    var onDisableAutoActivities: (@Sendable () -> Void)?

    init(repository: any AccidentRepository, videoRecorder: any VideoRecording, sleeper: any Sleeping = TaskSleeper(),
         initialState: AccidentUiState? = nil) {
        self.repository = repository
        self.videoRecorder = videoRecorder
        self.sleeper = sleeper
        self.uiState = initialState ?? AccidentUiState()
        self.usesFixtureState = initialState != nil
    }

    func setLanguageCode(_ value: String) { languageCode = value }

    /// Mantém a sessão do módulo alinhada à autenticação sem reiniciá-la a cada retorno de uma tela de ajuda.
    func synchronizeSession(chave chaveValue: String, authenticated: Bool) {
        guard !usesFixtureState else { return }
        if authenticated, chaveValue.count == 4 {
            if chave != chaveValue { onLogin(chaveValue) }
        } else if !chave.isEmpty {
            onLogout()
        }
    }

    // MARK: - Ciclo de vida

    func onLogin(_ chaveValue: String) {
        sessionToken += 1
        chave = chaveValue
        uiState = AccidentUiState()             // reset de todo estado de sessão
        refreshState()
        startSseStream()
        startPolling()
    }

    func onLogout() {
        sessionToken += 1                        // invalida qualquer Task da sessão anterior em voo
        sseTask?.cancel(); sseTask = nil
        pollTask?.cancel(); pollTask = nil
        chave = ""
        videoIdempotencyKeys.removeAll()
        uiState = AccidentUiState()
    }

    /// D2: recebe `automaticActivitiesEnabled` REAL (o Kotlin hardcoda `true` neste call-site — bug).
    func onCheckWebState(_ historyState: HistoryState, activeProject: String, automaticActivitiesEnabled: Bool) {
        let wasCheckin = uiState.currentActionIsCheckin
        uiState.hasCurrentDayCheckin = historyState.hasCurrentDayCheckin
        uiState.currentActionIsCheckin = historyState.currentAction == .checkIn
        let nowCheckin = uiState.currentActionIsCheckin
        if !wasCheckin && nowCheckin { refreshState() }        // transição checkout→checkin

        for accident in uiState.activeAccidents {
            let scenario = uiState.inquiryScenario(accident, userActiveProject: activeProject,
                                                   automaticActivitiesEnabled: automaticActivitiesEnabled)
            if scenario == .triggerAutoCheckin { triggerAutoCheckin(accident.accidentId) }
        }
    }

    private func refreshState() {
        let token = sessionToken
        Task {
            switch await repository.getState(chave) {
            case .success(let state):
                guard token == sessionToken else { return }   // resposta tardia p/ sessão abandonada — descarta
                let banner = (state.isActive && state.projectName != nil) ? t("accident.notification.bannerTemplate", ["project": state.projectName!], lang: languageCode) : ""
                var next = uiState
                next.accidentState = state
                next.bannerMessage = banner
                next.isLoading = false
                uiState = reconcileAckQueue(next)
            case .failure:
                guard token == sessionToken else { return }
                uiState.isLoading = false
            }
        }
    }

    // MARK: - Fila de ciência

    func onAckConfirm() {
        guard let showing = uiState.ackDialogShowing else { return }
        let token = sessionToken
        Task {
            _ = await repository.acknowledge(chave: chave, accidentId: showing.accidentId)   // resultado não inspecionado (§13)
            guard token == sessionToken else { return }
            let next = uiState.ackDialogQueue.first
            let remaining = Array(uiState.ackDialogQueue.dropFirst())
            var shownIds = uiState.ackShownForAccidentIds
            if let next { shownIds.insert(next.accidentId) }
            uiState.ackDialogShowing = next
            uiState.ackDialogQueue = remaining
            uiState.ackShownForAccidentIds = shownIds
            triggerAutoCheckin(showing.accidentId)
            refreshState()
        }
    }

    func onAckDismiss() {
        let next = uiState.ackDialogQueue.first
        let remaining = Array(uiState.ackDialogQueue.dropFirst())
        uiState.ackDialogShowing = next
        uiState.ackDialogQueue = remaining
        // NÃO chama acknowledge; NÃO atualiza ackShownForAccidentIds (assimetria fiel ao Kotlin).
    }

    // MARK: - SSE + polling

    private func startSseStream() {
        sseTask?.cancel()
        let token = sessionToken
        let stream = repository.streamCheckEvents(chave: chave)   // obtido síncrono — não retém self no loop
        sseTask = Task { [weak self] in
            for await data in stream {
                guard let self, self.sessionToken == token else { return }   // sessão mudou/VM desalocada → sai
                if data.hasPrefix("accident_") || data.contains("accident") { self.refreshState() }
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        let token = sessionToken
        pollTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
                if Task.isCancelled { break }
                guard let self, self.sessionToken == token else { break }
                if self.uiState.isActive { self.refreshState() }
            }
        }
    }

    // MARK: - Auto-checkin passivo (D3) + callback de disable (D1)

    /// D3: detect-and-wait — 3 tentativas (0s, depois 3s), só LÊ o estado; NUNCA submete check-in
    /// nem aciona o motor. Desacoplamento intencional (ver decision_log D3).
    func triggerAutoCheckin(_ accidentId: Int) {
        guard uiState.autoCheckinStatus[accidentId] == nil else { return }   // guarda de reentrância
        uiState.autoCheckinStatus[accidentId] = .pending
        let token = sessionToken
        Task {
            var success = false
            for attempt in 0..<Self.autoCheckinRetries {
                if success { break }
                if attempt > 0 { await sleeper.sleep(milliseconds: Int(Self.autoCheckinDelaySeconds * 1000)) }
                guard token == sessionToken else { return }   // sessão mudou durante a espera — aborta
                if case .success = await repository.getState(chave) {
                    guard token == sessionToken else { return }
                    refreshState()
                    if uiState.currentActionIsCheckin { success = true }
                }
            }
            guard token == sessionToken else { return }
            uiState.autoCheckinStatus[accidentId] = success ? .success : .failed
            if !success { onAccidentAutoCheckinFailed() }
        }
    }

    /// D1: NÃO desligar o automático (produção é no-op). Hook existe p/ pendência de produto.
    private func onAccidentAutoCheckinFailed() {
        onDisableAutoActivities?()   // no-op enquanto ninguém setar o hook — fiel à produção
    }

    func onNeedsDisableAutoActivitiesHandled() {
        uiState.needsDisableAutoActivities = false
    }

    // MARK: - Wizard (5 passos)

    func onReportButtonTap() {
        if uiState.isActive { uiState.actionsDialogOpen = true } else { openWizard() }
    }

    func openWizard() {
        uiState.actionsDialogOpen = false
        uiState.wizardOpen = true
        uiState.wizardState = WizardState()
        loadWizardProjects()
    }

    /// Fecha o wizard de qualquer passo sem submeter (ex.: tap fora / botão "x") — port de `onWizardDismiss`.
    func onWizardDismiss() {
        uiState.wizardOpen = false
        uiState.wizardState = nil
    }

    private func loadWizardProjects() {
        let token = sessionToken
        Task {
            guard token == sessionToken else { return }
            uiState.wizardState?.isLoadingProjects = true
            switch await repository.wizardProjects(chave: chave) {
            case .success(let projects):
                guard token == sessionToken else { return }
                uiState.wizardState?.isLoadingProjects = false
                uiState.wizardState?.projects = projects
            case .failure:
                guard token == sessionToken else { return }
                uiState.wizardState?.isLoadingProjects = false
            }
        }
    }

    private func loadWizardLocations(_ projectId: Int) {
        let token = sessionToken
        Task {
            switch await repository.wizardLocations(chave: chave, projectId: projectId) {
            case .success(let locations):
                guard token == sessionToken else { return }
                uiState.wizardState?.isLoadingLocations = false
                uiState.wizardState?.locations = locations
            case .failure:
                guard token == sessionToken else { return }
                uiState.wizardState?.isLoadingLocations = false
            }
        }
    }

    func onWizardProjectSelected(id: Int, name: String) {
        uiState.wizardState?.selectedProjectId = id
        uiState.wizardState?.selectedProjectName = name
    }

    func onWizardNextFromProject() {
        guard let ws = uiState.wizardState, ws.canProceedProject else { return }
        uiState.wizardState?.step = .location
        uiState.wizardState?.isLoadingLocations = true
        loadWizardLocations(ws.selectedProjectId!)
    }

    func onWizardLocationSelected(id: Int, name: String) {
        uiState.wizardState?.selectedLocationId = id
        uiState.wizardState?.selectedLocationName = name
        uiState.wizardState?.useCustomLocation = false
    }

    func onWizardCustomLocationToggled() {
        guard let ws = uiState.wizardState else { return }
        let newUseCustom = !ws.useCustomLocation
        uiState.wizardState?.useCustomLocation = newUseCustom
        uiState.wizardState?.selectedLocationId = newUseCustom ? nil : ws.selectedLocationId
    }

    func onWizardCustomLocationChanged(_ value: String) {
        uiState.wizardState?.customLocationName = value
    }

    func onWizardNextFromLocation() {
        guard let ws = uiState.wizardState, ws.canProceedLocation else { return }
        uiState.wizardState?.step = .description
    }

    /// Limita a 500 chars (rejeita silenciosamente o excedente — não trunca).
    func onWizardDescriptionChanged(_ value: String) {
        if value.count > 500 { return }
        uiState.wizardState?.description = value
    }

    func onWizardNextFromDescription() {
        uiState.wizardState?.step = .situation
    }

    func onWizardSituationSelected(zone: AccidentZone, status: AccidentSafetyStatus) {
        uiState.wizardState?.selectedZone = zone
        uiState.wizardState?.selectedStatus = status
    }

    func onWizardNextFromSituation() {
        guard let ws = uiState.wizardState, ws.canProceedSituation else { return }
        uiState.wizardState?.step = .confirm
    }

    func onWizardBack() {
        guard let ws = uiState.wizardState else { return }
        let prevStep: WizardStep?
        switch ws.step {
        case .project: prevStep = nil                  // fecha o wizard
        case .location: prevStep = .project
        case .description: prevStep = .location
        case .situation: prevStep = .description
        case .confirm: prevStep = .situation
        }
        if let prevStep {
            uiState.wizardState?.step = prevStep
            uiState.wizardState?.errorMessage = ""
        } else {
            uiState.wizardOpen = false
            uiState.wizardState = nil
        }
    }

    func onWizardConfirmSubmit() {
        guard let ws = uiState.wizardState, ws.canSubmitConfirm else { return }
        let token = sessionToken
        Task {
            uiState.wizardState?.isSubmitting = true
            uiState.wizardState?.errorMessage = ""
            let trimmedDescription = ws.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = await repository.open(
                chave: chave, projectId: ws.selectedProjectId!, locationId: ws.effectiveLocationId,
                customLocationName: ws.effectiveCustomName, zone: ws.selectedZone!, status: ws.selectedStatus!,
                description: trimmedDescription.isEmpty ? nil : ws.description)
            guard token == sessionToken else { return }
            switch result {
            case .success(let state):
                let banner = (state.isActive && state.projectName != nil) ? t("accident.notification.bannerTemplate", ["project": state.projectName!], lang: languageCode) : ""
                var next = uiState
                next.accidentState = state
                next.bannerMessage = banner
                next.wizardOpen = false
                next.wizardState = nil
                uiState = reconcileAckQueue(next)
            case .failure(let error):
                let errMsg: String
                if case .conflict = error { errMsg = t("accident.wizard.conflictAlreadyActive", lang: languageCode) }
                else { errMsg = t("status.apiCommunicationFailure", lang: languageCode) }
                uiState.wizardState?.isSubmitting = false
                uiState.wizardState?.errorMessage = errMsg
            }
        }
    }

    // MARK: - Relato de zona

    func onZoneSafetyTap(_ accidentId: Int) { uiState.zoneConfirmStep = .confirmSafety(accidentId) }
    func onZoneAccidentTap() { uiState.zoneConfirmStep = .accidentExpanded }
    func onZoneAccidentOkTap(_ accidentId: Int) { uiState.zoneConfirmStep = .confirmAccidentOk(accidentId) }
    func onZoneAccidentHelpTap(_ accidentId: Int) { uiState.zoneConfirmStep = .confirmAccidentHelp(accidentId) }

    /// Cancela um diálogo de confirmação de zona pendente sem submeter — port de `onZoneConfirmDismiss`.
    func onZoneConfirmDismiss() { uiState.zoneConfirmStep = .none }

    func onZoneConfirm() {
        switch uiState.zoneConfirmStep {
        case .confirmSafety(let id): submitReport(id, .safety, .ok)
        case .confirmAccidentOk(let id): submitReport(id, .accident, .ok)
        case .confirmAccidentHelp(let id): submitReport(id, .accident, .help)
        default: break
        }
        uiState.zoneConfirmStep = .none
    }

    private func submitReport(_ accidentId: Int, _ zone: AccidentZone, _ status: AccidentSafetyStatus) {
        let token = sessionToken
        Task {
            switch await repository.report(chave: chave, zone: zone, status: status) {
            case .success(let state):
                guard token == sessionToken else { return }
                let banner = (state.isActive && state.projectName != nil) ? t("accident.notification.bannerTemplate", ["project": state.projectName!], lang: languageCode) : ""
                uiState.accidentState = state
                uiState.bannerMessage = banner
                uiState.reportSentForAccidentId = accidentId
                if status == .help { triggerEmergencyCall() }
            case .failure:
                break   // silencioso — fiel ao Kotlin (§13, fora do conjunto D1–D6)
            }
        }
    }

    // MARK: - Emergência

    func triggerEmergencyCall() {
        let token = sessionToken
        Task {
            switch await repository.emergencyCall(chave: chave) {
            case .success(let result):
                guard token == sessionToken else { return }
                uiState.emergencyMessage = t("accident.emergency.callInitiated", ["label": result.callNumberLabel], lang: languageCode)
            case .failure(let error):
                guard token == sessionToken else { return }
                if case .conflict = error {
                    uiState.emergencyMessage = t("accident.emergency.alreadyCalled", lang: languageCode)   // idempotência!
                } else {
                    uiState.emergencyMessage = t("accident.emergency.callFailed", lang: languageCode)
                }
            }
        }
    }

    /// Limpa a mensagem de emergência (fecha o banner/toast) — port de `onEmergencyMessageDismiss`.
    func onEmergencyMessageDismiss() { uiState.emergencyMessage = "" }

    /// Destino seguro de notificações locais/APNs: reconcilia o estado no backend; a fila de ciência
    /// resultante decide qual diálogo deve aparecer, sem confiar em dados sensíveis do payload push.
    func onAccidentNotificationOpened() { refreshState() }

    // MARK: - Vídeo (D4 — retorna o Result; o caller DEVE inspecionar)

    /// D4: ao contrário do Kotlin (que descarta o `AppResult`), este método RETORNA o resultado —
    /// o chamador (tela/controller) decide DONE/ERROR a partir dele, nunca assume sucesso.
    func uploadVideo(file: URL, contentType: String, onProgress: @escaping @Sendable (Double) -> Void) async -> AppResult<VideoUploadResult> {
        let idempotencyKey = videoIdempotencyKeys[file] ?? UUID().uuidString
        videoIdempotencyKeys[file] = idempotencyKey
        let result = await repository.uploadVideo(
            chave: chave,
            idempotencyKey: idempotencyKey,
            videoFile: file,
            contentType: contentType,
            onProgress: onProgress)
        if case .success = result { videoIdempotencyKeys.removeValue(forKey: file) }
        return result
    }

    // MARK: - Dialogs

    /// Abre a tela de vídeo E fecha o diálogo de ações (transição combinada — port de `onVideoRecordOpen`).
    func openVideoScreen() {
        uiState.actionsDialogOpen = false
        uiState.videoScreenOpen = true
    }
    func closeVideoScreen() { uiState.videoScreenOpen = false }
    func closeActionsDialog() { uiState.actionsDialogOpen = false }
}
