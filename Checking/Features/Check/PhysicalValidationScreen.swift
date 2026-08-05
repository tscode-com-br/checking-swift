#if DEBUG
import SwiftUI
import UIKit

/// Tela técnica da Fase 2. Não substitui a tela final da Fase 5: conecta auth, permissões, geofences e
/// instrumentação para que o ensaio físico possa ser executado sem credenciais hardcoded.
@MainActor
struct PhysicalValidationScreen: View {
    @Bindable var viewModel: CheckViewModel
    let environment: AppEnvironment

    @Environment(\.scenePhase) private var scenePhase
    @State private var requester = PermissionRequestCoordinator()
    @State private var permissions: PermissionsStatus?
    @State private var consentGranted = false
    @State private var geofenceSummary: GeofenceRegistrationSummary?
    @State private var geofenceSnapshot: GeofenceMonitoringSnapshot?
    @State private var evaluation: EvaluationEntry?
    @State private var validationEventCount = 0
    @State private var latestValidationEvent = "Nenhum evento registrado"
    @State private var isWorking = false
    @State private var operationMessage = ""
#if DEBUG
    @State private var isPreparingDiagnosticsExport = false
    @State private var diagnosticsExport: DiagnosticsExportFile?
#endif

    var body: some View {
        CheckScreenShell(
            accidentActive: false,
            banner: { EmptyView() },
            cardBody: {
                VStack(alignment: .leading, spacing: Tokens.sectionGapLarge) {
                    introSection
                    Divider()
                    authenticationSection
                    Divider()
                    permissionsSection
                    Divider()
                    validationSection
                }
            })
        .task { await refreshDiagnostics() }
        .task { await pollDiagnostics() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            viewModel.onForegroundResume()
            Task { await refreshDiagnostics() }
        }
        .onChange(of: viewModel.uiState.isAuthenticated) { _, authenticated in
            guard authenticated else { return }
            Task { await refreshDiagnostics() }
        }
#if DEBUG
        .sheet(item: $diagnosticsExport, onDismiss: removeDiagnosticsExport) { export in
            EvaluationDiagnosticsActivitySheet(
                exportURL: export.url,
                onCompletion: removeDiagnosticsExport
            )
        }
        .onDisappear(perform: removeDiagnosticsExport)
#endif
    }

    private var introSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Validação física — Fase 2")
                .checkingText(CheckingTypography.titleMedium)
                .foregroundStyle(CheckingColors.textStrong)
            Text("Entre com a conta de teste, conceda as permissões em ordem e inicie o ensaio de segundo plano.")
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.textMutedLight)
        }
    }

    private var authenticationSection: some View {
        VStack(alignment: .leading, spacing: Tokens.itemGap) {
            sectionTitle("1. Autenticação")
            TextField("Chave", text: Binding(
                get: { viewModel.uiState.chave },
                set: { viewModel.onChaveChanged($0) }))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .checkingValidationField()
                .accessibilityLabel("Chave")

            SecureField("Senha", text: Binding(
                get: { viewModel.uiState.password },
                set: { viewModel.onPasswordChanged($0) }))
                .textContentType(.password)
                .checkingValidationField()
                .accessibilityLabel("Senha")

            if viewModel.uiState.isStatusLoading || viewModel.uiState.isInitializing {
                HStack { ProgressView(); Text("Consultando conta…") }
                    .foregroundStyle(CheckingColors.textMuted)
            }

            Button("Entrar") { viewModel.submitLogin() }
                .buttonStyle(ValidationPrimaryButtonStyle())
                .disabled(viewModel.uiState.chave.count != 4 ||
                          !isPasswordVerificationInputValid(viewModel.uiState.password))

            statusLine(
                viewModel.uiState.isAuthenticated ? "Sessão autenticada" : authStatusText,
                severity: viewModel.uiState.isAuthenticated ? .ok : .warning)

            statusLine(
                "Atividades automáticas: \(viewModel.uiState.automaticActivitiesEnabled ? "ativadas" : "desativadas")",
                severity: viewModel.uiState.automaticActivitiesEnabled ? .ok : .critical)

            Button(viewModel.uiState.automaticActivitiesEnabled
                   ? "Atividades automáticas ativadas"
                   : "Ativar atividades automáticas para o ensaio") {
                Task { await enableAutomaticActivities() }
            }
            .buttonStyle(ValidationSecondaryButtonStyle())
            .disabled(!viewModel.uiState.isAuthenticated || viewModel.uiState.automaticActivitiesEnabled || isWorking)

            if !viewModel.uiState.notificationPrimary.isEmpty {
                Text(viewModel.uiState.notificationPrimary)
                    .checkingText(CheckingTypography.bodySmall)
                    .foregroundStyle(notificationColor)
                    .accessibilityLabel("Mensagem: \(viewModel.uiState.notificationPrimary)")
            }
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.itemGap) {
            sectionTitle("2. Permissões e consentimento")
            if let permissions {
                statusLine("Notificações: \(notificationLabel(permissions.notificationAuthorization))",
                           severity: permissions.notificationsGranted ? .ok : .critical)
                statusLine("Localização: \(locationLabel(permissions))",
                           severity: permissions.preciseLocationGranted ? .ok : .critical)
                statusLine("Segundo plano: \(permissions.alwaysLocationGranted ? "Sempre" : "modo degradado")",
                           severity: permissions.alwaysLocationGranted ? .ok : .warning)
                statusLine("Atualização em 2º Plano: \(backgroundRefreshLabel(permissions.backgroundRefresh))",
                           severity: permissions.backgroundRefresh == .available ? .ok : .warning)
                statusLine("Modo Pouca Energia: \(permissions.lowPowerMode ? "ligado" : "desligado")",
                           severity: permissions.lowPowerMode ? .warning : .ok)
            } else {
                ProgressView("Lendo permissões…")
            }

            Button(nextPermissionButtonTitle) { Task { await requestNextPermission() } }
                .buttonStyle(ValidationSecondaryButtonStyle())
                .disabled(isWorking || permissions?.ladder.allRecommendedGranted == true)

            Button(consentGranted ? "Consentimento registrado" : "Autorizar o ensaio em segundo plano") {
                Task { await grantConsent() }
            }
            .buttonStyle(ValidationSecondaryButtonStyle())
            .disabled(consentGranted)

            if permissions.map({
                $0.locationAuthorization == .denied || $0.notificationAuthorization == .denied ||
                    !$0.preciseAccuracy || $0.backgroundRefresh != .available
            }) == true {
                Button("Abrir Ajustes do Checking") { environment.settingsOpener.openAppSettings() }
                    .buttonStyle(ValidationSecondaryButtonStyle())
            }
        }
    }

    private var validationSection: some View {
        VStack(alignment: .leading, spacing: Tokens.itemGap) {
            sectionTitle("3. Diagnóstico de segundo plano")
            statusLine("Geofences: \(geofenceText)", severity: geofenceSeverity)
            statusLine("Eventos do ensaio: \(validationEventCount)", severity: validationEventCount > 0 ? .ok : .warning)
            Text("Último evento: \(latestValidationEvent)")
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.textMuted)
            if let evaluation {
                Text("Última avaliação: \(evaluation.trigger.name) — \(evaluationOutcomeLabel(evaluation.outcome))")
                    .checkingText(CheckingTypography.bodySmall)
                    .foregroundStyle(CheckingColors.textMuted)
            }

            Button(isWorking ? "Preparando…" : "Iniciar ensaio físico") {
                Task { await startPhysicalValidation() }
            }
            .buttonStyle(ValidationPrimaryButtonStyle())
            .disabled(!canStartValidation || isWorking)

#if DEBUG
            if BackgroundValidationHarness.isEnabled {
                Button("Encerrar ensaio") { Task { await stopPhysicalValidation() } }
                    .buttonStyle(ValidationSecondaryButtonStyle())
            }
            Button(isPreparingDiagnosticsExport ? "Preparando diagnóstico…" : "Exportar diagnóstico") {
                Task { await exportDiagnostics() }
            }
            .buttonStyle(ValidationSecondaryButtonStyle())
            .disabled(isPreparingDiagnosticsExport || diagnosticsExport != nil)
            .accessibilityLabel("Exportar diagnóstico de validação")
            .accessibilityIdentifier("physical-validation-export-diagnostics")
#endif

            if !operationMessage.isEmpty {
                Text(operationMessage)
                    .checkingText(CheckingTypography.bodySmall)
                    .foregroundStyle(CheckingColors.textStrong)
            }
            Text("Durante o ensaio, bloqueie a tela e se desloque normalmente. Não force o encerramento do aplicativo.")
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.textMutedLight)
        }
    }

    private var canStartValidation: Bool {
        viewModel.uiState.isAuthenticated && consentGranted &&
            viewModel.uiState.automaticActivitiesEnabled &&
            permissions?.ladder.allRecommendedGranted == true
    }

    private var authStatusText: String {
        if viewModel.uiState.statusErrored { return "Falha ao consultar a conta" }
        if viewModel.uiState.authStatus?.hasPassword == true { return "Informe a senha" }
        if viewModel.uiState.chave.count == 4 { return "Conta localizada" }
        return "Informe a chave de quatro caracteres"
    }

    private var notificationColor: Color {
        switch viewModel.uiState.notificationTone {
        case .error: return CheckingColors.error
        case .success, .teal: return CheckingColors.success
        case .info: return CheckingColors.activityInfo
        case .none: return CheckingColors.textMuted
        }
    }

    private var geofenceText: String {
        if let snapshot = geofenceSnapshot {
            return "\(snapshot.requestedCount) solicitadas, \(snapshot.confirmedCount) confirmadas, \(snapshot.failedCount) falhas, \(snapshot.omittedCount) omitidas, \(snapshot.pendingCount) pendentes"
        }
        guard let summary = geofenceSummary else { return "ainda não solicitadas" }
        return "\(summary.requested) solicitadas, \(summary.omitted) omitidas"
    }

    private var geofenceSeverity: HealthSeverity {
        guard let snapshot = geofenceSnapshot else { return .warning }
        return snapshot.confirmationState == .confirmed ? .ok : .warning
    }

    private var nextPermissionButtonTitle: String {
        guard let permissions else { return "Atualizar permissões" }
        switch permissions.ladder.nextStep {
        case .notifications: return permissions.notificationAuthorization == .denied ? "Abrir Ajustes para notificações" : "Permitir notificações"
        case .preciseLocation:
            return permissions.locationAuthorization == .notDetermined ? "Permitir localização durante o uso" : "Abrir Ajustes para localização exata"
        case .alwaysLocation: return "Permitir localização Sempre"
        case nil: return "Permissões recomendadas concedidas"
        }
    }

    private func requestNextPermission() async {
        guard let permissions else { await refreshDiagnostics(); return }
        isWorking = true
        defer { isWorking = false }
        switch permissions.ladder.nextStep {
        case .notifications:
            if permissions.notificationAuthorization == .notDetermined {
                await requester.requestNotifications()
            } else {
                environment.settingsOpener.openAppSettings()
            }
        case .preciseLocation:
            if permissions.locationAuthorization == .notDetermined {
                requester.requestWhenInUseLocation()
            } else {
                environment.settingsOpener.openAppSettings()
            }
        case .alwaysLocation:
            requester.requestAlwaysLocation()
        case nil:
            break
        }
        try? await Task.sleep(for: .seconds(1))
        await refreshDiagnostics()
    }

    private func grantConsent() async {
        await environment.appPreferences.setBackgroundLocationConsentAt(ISOInstant.string(Date()))
        if viewModel.uiState.automaticActivitiesEnabled {
            await environment.significantLocationMonitor.start()
        }
        await refreshDiagnostics()
    }

    private func enableAutomaticActivities() async {
        isWorking = true
        operationMessage = "Consultando os projetos da conta…"
        let enabled = await viewModel.setAutomaticActivitiesEnabled(true)
        operationMessage = enabled
            ? "Atividades automáticas ativadas e projeto ativo persistido."
            : "Não foi possível ativar. Confirme a sessão e se a conta possui ao menos um projeto."
        isWorking = false
    }

    private func startPhysicalValidation() async {
        isWorking = true
        operationMessage = "Registrando geofences e iniciando localização…"
        await environment.significantLocationMonitor.start()
        await environment.geofenceRegionManager.register(chave: viewModel.uiState.chave)
#if DEBUG
        let rawSettings = await environment.appPreferences.userSettingsJson()
        let settingsMap = try? JSONCoding.decoder.decode([String: UserSettings].self, from: Data(rawSettings.utf8))
        let persistedSettings = resolvePersistedUserSettings(settingsMap, viewModel.uiState.chave)
        await BackgroundValidationHarness.shared.start(
            resetReport: true,
            includeSyntheticRegion: false,
            useContinuousLocation: false
        )
        await BackgroundValidationRecorder.shared.record(
            "automatic_activities_gate",
            details: [
                "enabled": String(viewModel.uiState.automaticActivitiesEnabled),
                "projectConfigured": String(!persistedSettings.activeProject.isEmpty)
            ]
        )
        await BackgroundValidationRecorder.shared.record(
            "production_significant_monitor_status",
            details: ["active": String(await environment.significantLocationMonitor.isActive())]
        )
#endif
        UIApplication.shared.registerForRemoteNotifications()
        await refreshDiagnostics()
        operationMessage = "Ensaio ativo. Pode bloquear a tela e colocar o Checking em segundo plano."
        isWorking = false
    }

    private func stopPhysicalValidation() async {
#if DEBUG
        await BackgroundValidationHarness.shared.stop()
#endif
        operationMessage = "Ensaio encerrado; as geofences da conta permanecem monitoradas."
        await refreshDiagnostics()
    }

#if DEBUG
    private func exportDiagnostics() async {
        guard !isPreparingDiagnosticsExport, diagnosticsExport == nil else { return }
        isPreparingDiagnosticsExport = true
        defer { isPreparingDiagnosticsExport = false }

        let exporter = EvaluationDiagnosticsExporter(journal: environment.evaluationJournal)
        guard let url = await exporter.createTemporaryExport() else {
            operationMessage = "Não foi possível preparar o diagnóstico."
            return
        }
        guard !Task.isCancelled else {
            EvaluationDiagnosticsExporter.removeTemporaryExport(at: url)
            return
        }
        diagnosticsExport = DiagnosticsExportFile(url: url)
        operationMessage = "Diagnóstico preparado para compartilhamento."
    }

    private func removeDiagnosticsExport() {
        guard let export = diagnosticsExport else { return }
        diagnosticsExport = nil
        EvaluationDiagnosticsExporter.removeTemporaryExport(at: export.url)
    }
#endif

    private func refreshDiagnostics() async {
        permissions = await environment.permissionsInspector.inspect()
        consentGranted = !(await environment.appPreferences.backgroundLocationConsentAt()).isEmpty
        geofenceSnapshot = await environment.geofenceRegionManager.monitoringSnapshot()
        geofenceSummary = await environment.geofenceRegionManager.lastSummary
        evaluation = EvaluationLog.shared.snapshot().first
#if DEBUG
        let report = await BackgroundValidationRecorder.shared.snapshot()
        validationEventCount = report.events.count
        latestValidationEvent = report.events.last?.kind ?? "Nenhum evento registrado"
#endif
    }

    private func pollDiagnostics() async {
        while !Task.isCancelled {
            await refreshDiagnostics()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .checkingText(CheckingTypography.titleSmall)
            .foregroundStyle(CheckingColors.textStrong)
    }

    private func statusLine(_ text: String, severity: HealthSeverity) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: statusSymbol(severity))
                .foregroundStyle(statusColor(severity))
                .accessibilityHidden(true)
            Text(text)
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.textStrong)
        }
        .accessibilityElement(children: .combine)
    }

    private func statusSymbol(_ severity: HealthSeverity) -> String {
        switch severity { case .ok: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .critical: "xmark.octagon.fill" }
    }

    private func statusColor(_ severity: HealthSeverity) -> Color {
        switch severity { case .ok: CheckingColors.success; case .warning: CheckingColors.warning; case .critical: CheckingColors.error }
    }

    private func notificationLabel(_ status: NotificationAuthorization) -> String {
        switch status { case .authorized: "permitidas"; case .denied: "negadas"; case .notDetermined: "pendentes" }
    }

    private func locationLabel(_ status: PermissionsStatus) -> String {
        switch status.locationAuthorization {
        case .notDetermined: return "pendente"
        case .denied: return "negada"
        case .whenInUse: return status.preciseAccuracy ? "Durante o Uso, exata" : "Durante o Uso, reduzida"
        case .always: return status.preciseAccuracy ? "Sempre, exata" : "Sempre, reduzida"
        }
    }

    private func backgroundRefreshLabel(_ status: BackgroundRefreshAvailability) -> String {
        switch status { case .available: "disponível"; case .denied: "desligada"; case .restricted: "restrita" }
    }

    private func evaluationOutcomeLabel(_ outcome: EvaluationOutcome) -> String {
        switch outcome {
        case .submitted: "enviado"
        case .noAction: "sem ação"
        case .skip: "ignorado"
        case .paused: "pausado"
        case .networkError: "erro de rede"
        case .toggleOff: "automático desligado"
        }
    }
}

#if DEBUG
private struct DiagnosticsExportFile: Identifiable {
    let id = UUID()
    let url: URL
}
#endif

private extension View {
    func checkingValidationField() -> some View {
        self
            .padding(.horizontal, Tokens.inputPaddingHorizontal)
            .frame(minHeight: 48)
            .background(CheckingColors.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
            .overlay(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular)
                .stroke(CheckingColors.inputBorder, lineWidth: 1))
    }
}

private struct ValidationPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(CheckingColors.onPrimary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(CheckingColors.primary.opacity(!isEnabled ? 0.42 : (configuration.isPressed ? 0.8 : 1)))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
    }
}

private struct ValidationSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(CheckingColors.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(CheckingColors.accentBgSoft.opacity(!isEnabled ? 0.42 : (configuration.isPressed ? 0.6 : 1)))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
    }
}
#endif
