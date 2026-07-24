import SwiftUI

struct CheckingDialogScaffold<Content: View>: View {
    let onDismiss: () -> Void
    var dismissOnScrimTap = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            if dismissOnScrimTap {
                Button(action: onDismiss) {
                    Color.black.opacity(0.5).ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            } else {
                Color.black.opacity(0.5).ignoresSafeArea()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.sectionGap) { content() }
                    .padding(Tokens.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CheckingColors.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadiusLarge, style: .circular))
                    .shadow(color: .black.opacity(0.2), radius: Tokens.dialogElevation, y: 3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 32)
                    .frame(maxWidth: Tokens.cardMaxWidth)
                    .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .transition(.opacity)
        .zIndex(100)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

struct DialogPasswordField: View {
    let label: String
    @Binding var text: String
    var enabled = true
    let languageCode: String
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).checkingText(CheckingTypography.labelMedium).foregroundStyle(CheckingColors.textMuted)
            HStack {
                Group {
                    if visible { TextField("", text: $text) }
                    else { SecureField("", text: $text) }
                }
                .checkingText(CheckingTypography.bodyLarge)
                .disabled(!enabled)
                Button { visible.toggle() } label: {
                    Image(systemName: visible ? "eye.slash" : "eye")
                        .foregroundStyle(CheckingColors.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t(visible ? "auth.hidePasswordAria" : "auth.showPasswordAria", lang: languageCode))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: Tokens.controlHeight)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular)
                    .stroke(CheckingColors.inputBorder, lineWidth: 1))
        }
    }
}

struct PasswordChangeDialog: View {
    let fields: PasswordChangeFields
    let hasPassword: Bool
    let languageCode: String
    let onOldChanged: (String) -> Void
    let onNewChanged: (String) -> Void
    let onConfirmChanged: (String) -> Void
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        CheckingDialogScaffold(onDismiss: onDismiss, dismissOnScrimTap: false) {
            Text(t(hasPassword ? "passwordDialog.titleChange" : "passwordDialog.titleRegister", lang: languageCode))
                .checkingText(CheckingTypography.titleLarge)
                .foregroundStyle(CheckingColors.textStrong)
            Divider().overlay(CheckingColors.divider)
            if hasPassword {
                DialogPasswordField(
                    label: t("passwordDialog.oldPasswordLabel", lang: languageCode),
                    text: binding(fields.oldPw, onOldChanged), enabled: !fields.isBusy, languageCode: languageCode)
            }
            DialogPasswordField(
                label: t("passwordDialog.newPasswordLabel", lang: languageCode),
                text: binding(fields.newPw, onNewChanged), enabled: !fields.isBusy, languageCode: languageCode)
            DialogPasswordField(
                label: t("passwordDialog.confirmPasswordLabel", lang: languageCode),
                text: binding(fields.confirmPw, onConfirmChanged), enabled: !fields.isBusy, languageCode: languageCode)
            if !fields.errorMessage.isEmpty {
                Text(fields.errorMessage).checkingText(CheckingTypography.bodySmall).foregroundStyle(CheckingColors.error)
            }
            if fields.isBusy {
                HStack(spacing: 8) {
                    ProgressView().tint(CheckingColors.primary)
                    Text(t(hasPassword ? "passwordDialog.changingStatus" : "passwordDialog.savingStatus", lang: languageCode))
                        .checkingText(CheckingTypography.bodySmall)
                        .foregroundStyle(CheckingColors.textMuted)
                }
            }
            PrimaryButton(
                text: t(hasPassword ? "passwordDialog.submitChangeButton" : "passwordDialog.submitRegisterButton", lang: languageCode),
                action: onSubmit,
                enabled: !fields.isBusy)
                .accessibilityIdentifier("password.submit")
            centeredBackButton
        }
    }

    private func binding(_ value: String, _ setter: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: { value }, set: setter)
    }

    private var centeredBackButton: some View {
        HStack {
            Spacer()
            Button(t("passwordDialog.backButton", lang: languageCode), action: onDismiss)
                .buttonStyle(.plain)
                .foregroundStyle(CheckingColors.textMuted)
                .disabled(fields.isBusy)
            Spacer()
        }
    }
}

struct SelfRegistrationDialog: View {
    let fields: SelfRegistrationFields
    let languageCode: String
    let onChaveChanged: (String) -> Void
    let onNameChanged: (String) -> Void
    let onEmailChanged: (String) -> Void
    let onPasswordChanged: (String) -> Void
    let onConfirmChanged: (String) -> Void
    let onProjectToggled: (Int) -> Void
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        CheckingDialogScaffold(onDismiss: onDismiss, dismissOnScrimTap: false) {
            HStack(spacing: 8) {
                Button(action: onDismiss) {
                    Image(systemName: "arrow.left").foregroundStyle(CheckingColors.primary)
                }
                .buttonStyle(.plain)
                .disabled(fields.isBusy)
                Text(t("registrationDialog.title", lang: languageCode))
                    .checkingText(CheckingTypography.titleLarge)
                    .foregroundStyle(CheckingColors.textStrong)
            }
            Divider().overlay(CheckingColors.divider)
            dialogTextField(
                t("registrationDialog.keyLabel", lang: languageCode),
                value: fields.chave,
                setter: onChaveChanged,
                monospaced: true)
            dialogTextField(
                t("registrationDialog.fullNameLabel", lang: languageCode),
                value: fields.nome,
                setter: onNameChanged)
            dialogTextField(
                t("registrationDialog.emailLabel", lang: languageCode),
                value: fields.email,
                placeholder: t("registrationDialog.emailPlaceholder", lang: languageCode),
                setter: onEmailChanged)
            DialogPasswordField(
                label: t("registrationDialog.passwordLabel", lang: languageCode),
                text: binding(fields.password, onPasswordChanged), enabled: !fields.isBusy, languageCode: languageCode)
            DialogPasswordField(
                label: t("registrationDialog.confirmPasswordLabel", lang: languageCode),
                text: binding(fields.confirmPw, onConfirmChanged), enabled: !fields.isBusy, languageCode: languageCode)
            Divider().overlay(CheckingColors.divider)
            Text(t("registrationDialog.projectsLabel", lang: languageCode))
                .checkingText(CheckingTypography.labelMedium)
                .foregroundStyle(CheckingColors.textMuted)
            projectSection
            if !fields.errorMessage.isEmpty {
                Text(fields.errorMessage).checkingText(CheckingTypography.bodySmall).foregroundStyle(CheckingColors.error)
            }
            if fields.isBusy {
                HStack(spacing: 8) {
                    ProgressView().tint(CheckingColors.primary)
                    Text(t("registrationDialog.submittingStatus", lang: languageCode))
                        .checkingText(CheckingTypography.bodySmall)
                        .foregroundStyle(CheckingColors.textMuted)
                }
            }
            PrimaryButton(
                text: t("registrationDialog.submitButton", lang: languageCode),
                action: onSubmit,
                enabled: !fields.isBusy)
                .accessibilityIdentifier("selfRegistration.submit")
            HStack {
                Spacer()
                Button(t("registrationDialog.backButton", lang: languageCode), action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(CheckingColors.textMuted)
                    .disabled(fields.isBusy)
                Spacer()
            }
        }
    }

    @ViewBuilder private var projectSection: some View {
        if fields.isLoadingProjects {
            HStack(spacing: 8) {
                ProgressView().tint(CheckingColors.primary)
                Text(t("registrationDialog.loadingProjects", lang: languageCode))
                    .checkingText(CheckingTypography.bodySmall)
            }
        } else if fields.projectCatalog.isEmpty {
            Text(t("registrationDialog.noProjectsAvailable", lang: languageCode))
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.textMuted)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(fields.projectCatalog, id: \.id) { project in
                    Button { onProjectToggled(project.id) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: fields.selectedProjectIds.contains(project.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(fields.selectedProjectIds.contains(project.id) ? CheckingColors.primary : CheckingColors.inputBorder)
                            Text(project.name)
                                .checkingText(CheckingTypography.bodyMedium)
                                .foregroundStyle(CheckingColors.textStrong)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .disabled(fields.isBusy)
                }
            }
        }
    }

    private func dialogTextField(
        _ label: String,
        value: String,
        placeholder: String = "",
        setter: @escaping (String) -> Void,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).checkingText(CheckingTypography.labelMedium).foregroundStyle(CheckingColors.textMuted)
            TextField(placeholder, text: binding(value, setter))
                .font(monospaced ? .system(.body, design: .monospaced) : CheckingTypography.bodyMedium.font)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: Tokens.controlHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular)
                        .stroke(CheckingColors.inputBorder, lineWidth: 1))
                .disabled(fields.isBusy)
        }
    }

    private func binding(_ value: String, _ setter: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: { value }, set: setter)
    }
}

struct SettingsDialog: View {
    let isAuthenticated: Bool
    let hasPassword: Bool
    let automaticActivitiesEnabled: Bool
    let permissionsStatus: PermissionsStatus?
    let languageCode: String
    let onLanguageChanged: (String) -> Void
    let onAutoActivitiesTap: () -> Void
    let onScheduledPauseTap: () -> Void
    let onNotificationsTap: () -> Void
    let onManualTap: () -> Void
    let onSupportTap: () -> Void
    let onAboutTap: () -> Void
    let onPrivacyTap: () -> Void
    let onActivitiesTap: () -> Void
    let onPasswordTap: () -> Void
    let onDeleteAccount: () -> Void
    let onPhysicalValidationTap: () -> Void
    let onDismiss: () -> Void
    @State private var confirmsDeletion = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        CheckingDialogScaffold(onDismiss: onDismiss, dismissOnScrimTap: false) {
            Text(t("settings.title", lang: languageCode))
                .checkingText(CheckingTypography.titleLarge)
                .foregroundStyle(CheckingColors.textStrong)
            languageMenu
            if isAuthenticated {
                settingsRow(
                    icon: "location",
                    title: t("autoActivities.title", lang: languageCode),
                    trailing: automaticStatus,
                    accessibilityIdentifier: "settings.automatic",
                    action: onAutoActivitiesTap)
                groupHeader(t("settings.groupPreferences", lang: languageCode))
                settingsRow(
                    icon: "clock",
                    title: t("scheduledPause.buttonLabel", lang: languageCode),
                    accessibilityIdentifier: "settings.scheduledPause",
                    action: onScheduledPauseTap)
                settingsRow(
                    icon: "bell",
                    title: t("settings.notificationsLabel", lang: languageCode),
                    accessibilityIdentifier: "settings.notifications",
                    action: onNotificationsTap)
                settingsRow(
                    icon: "key",
                    title: hasPassword ? t("settings.resetPasswordLabel", lang: languageCode)
                        : t("passwordDialog.titleRegister", lang: languageCode),
                    action: onPasswordTap)
            }
            groupHeader(t("settings.groupHelp", lang: languageCode))
            settingsRow(
                icon: "book.closed",
                title: t("settings.manualLabel", lang: languageCode),
                accessibilityIdentifier: "settings.manual",
                action: onManualTap)
            settingsRow(
                icon: "message",
                title: t("settings.supportLabel", lang: languageCode),
                accessibilityIdentifier: "settings.support",
                action: onSupportTap)
            settingsRow(
                icon: "info.circle",
                title: t("settings.aboutLabel", lang: languageCode),
                accessibilityIdentifier: "settings.about",
                action: onAboutTap)
            settingsRow(
                icon: "hand.raised",
                title: t("settings.privacyLabel", lang: languageCode),
                accessibilityIdentifier: "settings.privacy",
                action: onPrivacyTap)
            settingsRow(
                icon: "clock.arrow.circlepath",
                title: t("settings.activitiesLabel", lang: languageCode),
                accessibilityIdentifier: "settings.activities",
                action: onActivitiesTap)
#if DEBUG
            if !ProcessInfo.processInfo.arguments.contains("--ui-test-documentation") {
                settingsRow(
                    icon: "wrench.and.screwdriver",
                    title: "Validação física — Fase 2",
                    action: onPhysicalValidationTap)
            }
#endif
            if isAuthenticated {
                groupHeader(t("settings.groupAccount", lang: languageCode))
                settingsRow(
                    icon: "trash",
                    title: t("settings.deleteAccountLabel", lang: languageCode),
                    tint: CheckingColors.error,
                    destructive: true,
                    action: { confirmsDeletion = true })
            }
            HStack {
                Spacer()
                Button(t("settings.backButton", lang: languageCode), action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(CheckingColors.textMuted)
                Spacer()
            }
        }
        .alert(t("settings.deleteAccountConfirmTitle", lang: languageCode), isPresented: $confirmsDeletion) {
            Button(t("settings.deleteAccountCancel", lang: languageCode), role: .cancel) {}
            Button(t("settings.deleteAccountConfirm", lang: languageCode), role: .destructive, action: onDeleteAccount)
        } message: {
            Text(t("settings.deleteAccountConfirmBody", lang: languageCode))
        }
    }

    private var automaticStatus: String {
        guard automaticActivitiesEnabled else { return t("settings.statusOff", lang: languageCode) }
        return permissionsStatus?.ladder.allRecommendedGranted == true
            ? t("settings.statusOn", lang: languageCode)
            : t("settings.statusAttention", lang: languageCode)
    }

    private var languageMenu: some View {
        Menu {
            ForEach(supportedLanguages) { language in
                Button {
                    onLanguageChanged(language.code)
                } label: {
                    if language.code == resolveLanguageCode(languageCode) {
                        Label(language.nativeLabel, systemImage: "checkmark")
                    } else {
                        Text(language.nativeLabel)
                    }
                }
            }
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            languageIcon
                            languageTitle
                        }
                        HStack(spacing: 8) {
                            languageValue
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(CheckingColors.textMutedSoft)
                        }
                        .padding(.leading, 36)
                    }
                } else {
                    HStack(spacing: 12) {
                        languageIcon
                        languageTitle
                        Spacer()
                        languageValue
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(CheckingColors.textMutedSoft)
                    }
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("settings.language")
        .accessibilityLabel(t("settings.languageLabel", lang: languageCode))
        .accessibilityValue(getLanguageEntry(languageCode).nativeLabel)
    }

    private var languageIcon: some View {
        Image(systemName: "globe")
            .foregroundStyle(CheckingColors.primary)
            .frame(width: 24)
            .accessibilityHidden(true)
    }

    private var languageTitle: some View {
        Text(t("settings.languageLabel", lang: languageCode))
            .checkingText(CheckingTypography.bodyLarge)
            .foregroundStyle(CheckingColors.textStrong)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var languageValue: some View {
        Text(getLanguageEntry(languageCode).nativeLabel)
            .checkingText(CheckingTypography.labelSmall)
            .foregroundStyle(CheckingColors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func groupHeader(_ title: String) -> some View {
        Text(dynamicTypeSize.isAccessibilitySize
            ? title.uppercased().replacingOccurrences(of: " ", with: "\n")
            : title.uppercased())
            .checkingText(CheckingTypography.labelMedium)
            .foregroundStyle(CheckingColors.textMuted)
            .padding(.top, Tokens.itemGap)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func settingsRow(
        icon: String, title: String, trailing: String? = nil,
        tint: Color = CheckingColors.primary, destructive: Bool = false,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 12) {
                            settingsIcon(icon, tint: tint)
                            settingsTitle(title, tint: tint, destructive: destructive)
                        }
                        if let trailing {
                            settingsTrailing(trailing, tint: tint)
                                .padding(.leading, 36)
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        settingsIcon(icon, tint: tint)
                        settingsTitle(title, tint: tint, destructive: destructive)
                        Spacer()
                        if let trailing { settingsTrailing(trailing, tint: tint) }
                        Image(systemName: "chevron.right").foregroundStyle(CheckingColors.textMutedSoft)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(trailing ?? "")
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }

    private func settingsIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name).foregroundStyle(tint).frame(width: 24)
            .accessibilityHidden(true)
    }

    private func settingsTitle(_ title: String, tint: Color, destructive: Bool) -> some View {
        Text(title)
            .checkingText(CheckingTypography.bodyLarge)
            .foregroundStyle(destructive ? tint : CheckingColors.textStrong)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func settingsTrailing(_ trailing: String, tint: Color) -> some View {
        Text(trailing)
            .checkingText(CheckingTypography.labelSmall)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().stroke(tint, lineWidth: 1))
    }
}
