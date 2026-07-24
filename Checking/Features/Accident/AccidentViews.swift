import SwiftUI
import AVFoundation
import UIKit

struct AccidentBannerView: View {
    let message: String

    var body: some View {
        if !message.isEmpty {
            Text(message)
                .checkingText(CheckingTypography.labelMedium)
                .foregroundStyle(CheckingColors.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Tokens.cardPaddingSmall)
                .padding(.vertical, 8)
                .background(CheckingColors.error)
                .accessibilityIdentifier("accident.banner")
                .onAppear { announce() }
                .onChange(of: message) { _, _ in announce() }
        }
    }

    private func announce() {
        guard UIAccessibility.isVoiceOverRunning, !message.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

struct AccidentReportButton: View {
    let isActive: Bool
    let languageCode: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(t(isActive ? "accident.button.reported" : "accident.button.report", lang: languageCode))
                .checkingText(CheckingTypography.labelLarge)
                .foregroundStyle(CheckingColors.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .frame(minHeight: Tokens.controlHeight)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .background(CheckingColors.accident)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius))
        .shadow(color: isActive ? Color(hex: "#FF4D57").opacity(0.72) : .clear,
                radius: isActive ? 18 : 0)
        .accessibilityIdentifier("accident.report")
    }
}

struct AccidentInquiryCard: View {
    let accident: AccidentActiveItem
    let scenario: InquiryScenario
    let state: AccidentUiState
    let languageCode: String
    let onSafety: () -> Void
    let onAccident: () -> Void
    let onAccidentOK: () -> Void
    let onAccidentHelp: () -> Void
    let onEmergency: () -> Void
    let onDismissEmergency: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.sectionGap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(accident.projectName)
                    .checkingText(CheckingTypography.titleSmall)
                    .foregroundStyle(CheckingColors.error)
                Text(accident.locationName)
                    .checkingText(CheckingTypography.bodySmall)
                    .foregroundStyle(CheckingColors.textMuted)
                if let description = accident.description, !description.isEmpty {
                    Text(description)
                        .checkingText(CheckingTypography.bodySmall)
                        .foregroundStyle(CheckingColors.textMuted)
                }
            }

            switch scenario {
            case .showZoneButtons:
                if state.reportSentForAccidentId == accident.accidentId {
                    postReport
                } else {
                    zoneButtons
                }
            case .postReport:
                postReport
            case .autoCheckinRunning, .triggerAutoCheckin:
                ProgressView().tint(CheckingColors.accident).frame(maxWidth: .infinity)
                Text(t("status.runningAutomaticActivitySequence", lang: languageCode))
                    .checkingText(CheckingTypography.bodySmall)
                    .foregroundStyle(CheckingColors.textMuted)
            case .autoCheckinFailed:
                Text(t("accident.fallback.manualCheckin", lang: languageCode))
                    .checkingText(CheckingTypography.bodyMedium)
                    .foregroundStyle(CheckingColors.error)
            case .hideCard, .checkedOutAutoOff:
                EmptyView()
            }

            if !state.emergencyMessage.isEmpty {
                Button(action: onDismissEmergency) {
                    Text(state.emergencyMessage)
                        .checkingText(CheckingTypography.bodySmall)
                        .foregroundStyle(CheckingColors.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Tokens.cardPadding)
        .background(CheckingColors.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        .shadow(color: .black.opacity(0.12), radius: Tokens.cardElevation, y: 3)
        .accessibilityIdentifier("accident.inquiry")
    }

    @ViewBuilder private var zoneButtons: some View {
        Text(t("accident.inquiry.title", lang: languageCode))
            .checkingText(CheckingTypography.labelMedium)
            .foregroundStyle(CheckingColors.textMuted)
        AccidentSecondaryButton(text: t("accident.inquiry.safetyZone", lang: languageCode), action: onSafety)
        if state.zoneConfirmStep == .accidentExpanded {
            AccidentSecondaryButton(text: t("accident.inquiry.imOk", lang: languageCode), action: onAccidentOK)
            AccidentDangerButton(text: t("accident.inquiry.needHelp", lang: languageCode), action: onAccidentHelp)
        } else {
            AccidentSecondaryButton(text: t("accident.inquiry.accidentZone", lang: languageCode), action: onAccident)
        }
    }

    @ViewBuilder private var postReport: some View {
        Text(t("accident.situationSent", lang: languageCode))
            .checkingText(CheckingTypography.bodyMedium)
            .foregroundStyle(CheckingColors.primary)
        AccidentSecondaryButton(text: t("accident.triggerEmergency", lang: languageCode), action: onEmergency)
    }
}

struct AccidentOverlayStack: View {
    @Bindable var viewModel: AccidentViewModel
    let languageCode: String
    let settingsOpener: any SettingsOpening

    var body: some View {
        Group {
            if let accident = viewModel.uiState.ackDialogShowing {
                AccidentAckDialogView(
                    accident: accident, languageCode: languageCode,
                    onConfirm: { viewModel.onAckConfirm() },
                    onDismiss: { viewModel.onAckDismiss() })
            }
            if viewModel.uiState.actionsDialogOpen {
                AccidentActionsDialogView(
                    languageCode: languageCode,
                    onVideo: { viewModel.openVideoScreen() },
                    onWizard: { viewModel.openWizard() },
                    onDismiss: { viewModel.closeActionsDialog() })
            }
            if viewModel.uiState.wizardOpen, let wizard = viewModel.uiState.wizardState {
                AccidentWizardView(viewModel: viewModel, state: wizard, languageCode: languageCode)
            }
            if viewModel.uiState.videoScreenOpen {
                AccidentVideoScreen(
                    viewModel: viewModel, languageCode: languageCode,
                    settingsOpener: settingsOpener)
            }
            if let confirmationKey = zoneConfirmationKey {
                AccidentZoneConfirmationView(
                    message: t(confirmationKey, lang: languageCode),
                    confirmLabel: t("accident.ack.button", lang: languageCode),
                    cancelLabel: t("accident.wizard.back", lang: languageCode),
                    onConfirm: { viewModel.onZoneConfirm() },
                    onDismiss: { viewModel.onZoneConfirmDismiss() })
            }
        }
    }

    private var zoneConfirmationKey: String? {
        switch viewModel.uiState.zoneConfirmStep {
        case .confirmSafety: return "accident.confirm.safety"
        case .confirmAccidentOk: return "accident.confirm.accidentOk"
        case .confirmAccidentHelp: return "accident.confirm.help"
        case .none, .accidentExpanded: return nil
        }
    }
}

private struct AccidentZoneConfirmationView: View {
    let message: String
    let confirmLabel: String
    let cancelLabel: String
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        AccidentOverlayCard(onDismiss: onDismiss) {
            Text(message)
                .checkingText(CheckingTypography.bodyMedium)
                .foregroundStyle(CheckingColors.textStrong)
            HStack {
                AccidentSecondaryButton(text: cancelLabel, action: onDismiss)
                AccidentDangerButton(text: confirmLabel, action: onConfirm)
            }
        }
        .accessibilityIdentifier("accident.zoneConfirmation")
    }
}

private struct AccidentAckDialogView: View {
    let accident: AccidentActiveItem
    let languageCode: String
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        AccidentOverlayCard(onDismiss: onDismiss) {
            Text(t("accident.ack.title", lang: languageCode))
                .checkingText(CheckingTypography.titleMedium)
                .foregroundStyle(CheckingColors.error)
            Text(accident.projectName).checkingText(CheckingTypography.bodyMedium)
            Text(accident.locationName).checkingText(CheckingTypography.bodySmall).foregroundStyle(CheckingColors.textMuted)
            if let description = accident.description { Text(description).checkingText(CheckingTypography.bodySmall) }
            Text(t("accident.ack.checkinReminder", lang: languageCode))
                .checkingText(CheckingTypography.bodyMedium)
                .foregroundStyle(CheckingColors.error)
            AccidentDangerButton(text: t("accident.ack.button", lang: languageCode), action: onConfirm)
        }
        .accessibilityIdentifier("accident.ack")
    }
}

private struct AccidentActionsDialogView: View {
    let languageCode: String
    let onVideo: () -> Void
    let onWizard: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        AccidentOverlayCard(onDismiss: onDismiss) {
            Text(t("accident.actions.title", lang: languageCode)).checkingText(CheckingTypography.titleMedium)
            AccidentSecondaryButton(text: t("accident.actions.audioVideo", lang: languageCode), action: onVideo)
            AccidentSecondaryButton(text: t("accident.actions.reportNew", lang: languageCode), action: onWizard)
            AccidentSecondaryButton(text: t("accident.actions.back", lang: languageCode), action: onDismiss)
        }
        .accessibilityIdentifier("accident.actions")
    }
}

private struct AccidentWizardView: View {
    @Bindable var viewModel: AccidentViewModel
    let state: WizardState
    let languageCode: String

    var body: some View {
        AccidentOverlayCard(onDismiss: { viewModel.onWizardDismiss() }, width: 0.92) {
            if !state.errorMessage.isEmpty {
                Text(state.errorMessage).checkingText(CheckingTypography.bodySmall).foregroundStyle(CheckingColors.error)
            }
            switch state.step {
            case .project: projectStep
            case .location: locationStep
            case .description: descriptionStep
            case .situation: situationStep
            case .confirm: confirmStep
            }
        }
        .accessibilityIdentifier("accident.wizard")
    }

    @ViewBuilder private var projectStep: some View {
        title("accident.wizard.selectProject")
        if state.isLoadingProjects { ProgressView().frame(maxWidth: .infinity) }
        ForEach(state.projects) { project in
            radio(project.name, selected: state.selectedProjectId == project.id) {
                viewModel.onWizardProjectSelected(id: project.id, name: project.name)
            }
        }
        navigation(enabled: state.canProceedProject) { viewModel.onWizardNextFromProject() }
    }

    @ViewBuilder private var locationStep: some View {
        title("accident.wizard.selectLocation")
        if state.isLoadingLocations { ProgressView().frame(maxWidth: .infinity) }
        ForEach(state.locations) { location in
            radio(location.name, selected: !state.useCustomLocation && state.selectedLocationId == location.id) {
                viewModel.onWizardLocationSelected(id: location.id, name: location.name)
            }
        }
        radio(t("accident.wizard.otherLocation", lang: languageCode), selected: state.useCustomLocation) {
            viewModel.onWizardCustomLocationToggled()
        }
        if state.useCustomLocation {
            TextField(t("accident.wizard.otherLocation", lang: languageCode), text: Binding(
                get: { state.customLocationName },
                set: { value in viewModel.onWizardCustomLocationChanged(value) }))
                .textFieldStyle(.roundedBorder)
        }
        navigation(enabled: state.canProceedLocation) { viewModel.onWizardNextFromLocation() }
    }

    @ViewBuilder private var descriptionStep: some View {
        title("accident.description.title")
        TextEditor(text: Binding(
            get: { state.description },
            set: { value in viewModel.onWizardDescriptionChanged(value) }))
            .frame(minHeight: 120)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CheckingColors.inputBorder))
        Text("\(state.description.count)/500")
            .checkingText(CheckingTypography.labelSmall)
            .foregroundStyle(CheckingColors.textMuted)
        navigation(enabled: true) { viewModel.onWizardNextFromDescription() }
    }

    @ViewBuilder private var situationStep: some View {
        title("accident.wizard.yourSituation")
        situation(.safety, .ok, "accident.inquiry.safetyZone")
        situation(.accident, .ok, "accident.inquiry.imOk")
        situation(.accident, .help, "accident.inquiry.needHelp")
        navigation(enabled: state.canProceedSituation) { viewModel.onWizardNextFromSituation() }
    }

    @ViewBuilder private var confirmStep: some View {
        title("accident.wizard.confirmTitle")
        Text(t("accident.wizard.confirmTextTemplate", [
            "location": state.effectiveLocationLabel,
            "project": state.selectedProjectName
        ], lang: languageCode)).checkingText(CheckingTypography.bodyMedium)
        HStack {
            AccidentSecondaryButton(text: t("accident.wizard.back", lang: languageCode)) {
                viewModel.onWizardBack()
            }
            AccidentDangerButton(
                text: state.isSubmitting ? "…" : t("accident.ack.button", lang: languageCode),
                enabled: state.canSubmitConfirm,
                action: { viewModel.onWizardConfirmSubmit() })
        }
    }

    private func title(_ key: String) -> some View {
        Text(t(key, lang: languageCode))
            .checkingText(CheckingTypography.titleSmall)
            .accessibilityAddTraits(.isHeader)
    }

    private func navigation(enabled: Bool, next: @escaping () -> Void) -> some View {
        HStack {
            AccidentSecondaryButton(text: t("accident.wizard.back", lang: languageCode)) {
                viewModel.onWizardBack()
            }
            AccidentDangerButton(text: t("accident.wizard.next", lang: languageCode), enabled: enabled, action: next)
        }
    }

    private func situation(_ zone: AccidentZone, _ status: AccidentSafetyStatus, _ key: String) -> some View {
        radio(t(key, lang: languageCode), selected: state.selectedZone == zone && state.selectedStatus == status) {
            viewModel.onWizardSituationSelected(zone: zone, status: status)
        }
    }

    private func radio(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(CheckingColors.accident)
                    .accessibilityHidden(true)
                Text(label).checkingText(CheckingTypography.bodyMedium).foregroundStyle(CheckingColors.textStrong)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AccidentVideoScreen: View {
    @Bindable var viewModel: AccidentViewModel
    let languageCode: String
    let settingsOpener: any SettingsOpening
    @State private var permissionsGranted = false
    @State private var requested = false
    @State private var controller: VideoRecordController?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session = controller?.previewSession {
                AccidentCameraPreview(session: session)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            VStack(spacing: Tokens.sectionGap) {
                Spacer()
                if permissionsGranted, let controller {
                    videoControls(controller)
                } else {
                    Text(t("accident.video.permissionRequired", lang: languageCode))
                        .checkingText(CheckingTypography.bodyMedium)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    AccidentDangerButton(text: t("accident.video.openSettings", lang: languageCode)) {
                        settingsOpener.openAppSettings()
                    }
                    AccidentSecondaryButton(text: t("accident.actions.back", lang: languageCode)) {
                        viewModel.closeVideoScreen()
                    }
                }
                Spacer().frame(height: 32)
            }
            .padding(Tokens.sectionGap)
        }
        .task { await requestPermissionsAndStart() }
        .onDisappear { controller?.onScreenDisposed() }
        .accessibilityIdentifier("accident.video")
    }

    @ViewBuilder private func videoControls(_ controller: VideoRecordController) -> some View {
        switch controller.phase {
        case .recording:
            Text("●  \(t("accident.video.recording", lang: languageCode))")
                .checkingText(CheckingTypography.labelLarge).foregroundStyle(CheckingColors.error)
            AccidentDangerButton(text: t("accident.video.stopAndSend", lang: languageCode)) {
                Task { await controller.stopRecordingAndUpload() }
            }
        case .uploading:
            Text(controller.statusMessage).foregroundStyle(.white)
            ProgressView(value: controller.uploadProgress).tint(CheckingColors.accident)
        case .done, .error:
            Text(controller.statusMessage)
                .foregroundStyle(controller.phase == .done ? .white : CheckingColors.error)
            if controller.canRetryUpload {
                AccidentDangerButton(text: t("accident.video.retry", lang: languageCode)) {
                    Task { await controller.stopRecordingAndUpload() }
                }
            }
            AccidentDangerButton(text: t("accident.actions.back", lang: languageCode)) {
                viewModel.closeVideoScreen()
            }
        }
    }

    private func requestPermissionsAndStart() async {
        guard !requested else { return }
        requested = true
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        permissionsGranted = camera && microphone
        guard permissionsGranted else { return }
        let newController = VideoRecordController(videoRecorder: viewModel.videoRecorder) {
            [viewModel] file, contentType, progress in
            await viewModel.uploadVideo(file: file, contentType: contentType, onProgress: progress)
        }
        newController.startRecording()
        controller = newController
    }
}

private struct AccidentCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
    }
}

private final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct AccidentOverlayCard<Content: View>: View {
    let onDismiss: () -> Void
    var width: CGFloat = 0.86
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea().onTapGesture(perform: onDismiss)
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.sectionGap) { content() }
                    .padding(Tokens.cardPadding)
                    .frame(maxWidth: 680, alignment: .leading)
                    .background(CheckingColors.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadiusLarge))
                    .padding(.vertical, 32)
            }
            .frame(maxWidth: UIScreen.main.bounds.width * width, maxHeight: UIScreen.main.bounds.height * 0.88)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct AccidentSecondaryButton: View {
    let text: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).checkingText(CheckingTypography.labelMedium)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .frame(minHeight: Tokens.controlHeight)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(CheckingColors.accident)
        .overlay(RoundedRectangle(cornerRadius: Tokens.controlRadius).stroke(CheckingColors.accident))
    }
}

private struct AccidentDangerButton: View {
    let text: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).checkingText(CheckingTypography.labelMedium).foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .frame(minHeight: Tokens.controlHeight)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .background(CheckingColors.accident.opacity(enabled ? 1 : 0.38))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius))
        .disabled(!enabled)
    }
}
