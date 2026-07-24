import SwiftUI

enum FieldGlow: Sendable, Equatable { case none, pending, authenticated }

struct AuthRow: View {
    @Binding var chave: String
    @Binding var password: String
    let isFound: Bool
    let isAuthenticated: Bool
    let isStatusLoading: Bool
    let isStatusAvailable: Bool
    let awaitingApproval: Bool
    let prompt: String
    let languageCode: String
    var autoActivitiesGlow: FieldGlow = .none
    let onSettingsTap: () -> Void
    let onRequestRegistrationTap: () -> Void

    @State private var passwordVisible = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var authGlow: FieldGlow {
        if isAuthenticated { return .authenticated }
        if awaitingApproval || isFound { return .pending }
        return .none
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.itemGap) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        keyField
                        passwordField
                        settingsButton
                    }
                } else {
                    HStack(alignment: .bottom, spacing: 8) {
                        keyField
                        passwordField
                        settingsButton
                    }
                }
            }

            if !prompt.isEmpty {
                Text(prompt)
                    .checkingText(CheckingTypography.bodySmall)
                    .foregroundStyle(CheckingColors.textMuted)
            }
            if isStatusAvailable && !isFound {
                Button(t("auth.requestRegistrationButton", lang: languageCode), action: onRequestRegistrationTap)
                    .checkingText(CheckingTypography.labelLarge)
                    .foregroundStyle(CheckingColors.primary)
                    .buttonStyle(.plain)
            }
        }
    }

    private var keyField: some View {
        credentialField(
            label: t("auth.keyLabel", lang: languageCode),
            placeholder: t("auth.keyPlaceholder", lang: languageCode),
            isEmpty: chave.isEmpty,
            glow: authGlow,
            trailing: isStatusLoading ? AnyView(ProgressView().tint(CheckingColors.primary).scaleEffect(0.75)) : nil
        ) {
            TextField("", text: $chave)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(CheckingColors.textStrong)
                .accessibilityIdentifier("auth.key")
                .onChange(of: chave) { _, value in
                    let sanitized = String(value.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(4))
                    if sanitized != value { chave = sanitized }
                }
        }
    }

    private var passwordField: some View {
        credentialField(
            label: t("auth.passwordLabel", lang: languageCode),
            placeholder: t("auth.passwordPlaceholder", lang: languageCode),
            isEmpty: password.isEmpty && !isAuthenticated,
            glow: authGlow,
            trailing: isAuthenticated ? AnyView(savedPasswordIndicator) : AnyView(passwordVisibilityButton)
        ) {
            if isAuthenticated {
                Text("••••••")
                    .checkingText(CheckingTypography.bodyLarge)
                    .foregroundStyle(CheckingColors.textStrong)
                    .accessibilityLabel(t("auth.savedPasswordAria", lang: languageCode))
                    .accessibilityIdentifier("auth.password.masked")
            } else {
                Group {
                    if passwordVisible { TextField("", text: $password) }
                    else { SecureField("", text: $password) }
                }
                .checkingText(CheckingTypography.bodyLarge)
                .foregroundStyle(CheckingColors.textStrong)
                .accessibilityIdentifier("auth.password")
            }
        }
    }

    private var settingsButton: some View {
        VStack(spacing: 6) {
            if !dynamicTypeSize.isAccessibilitySize {
                Text(" ").checkingText(CheckingTypography.labelLarge).accessibilityHidden(true)
            }
            Button(action: onSettingsTap) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        Label(t("auth.openSettingsAria", lang: languageCode), systemImage: "gearshape")
                    } else {
                        Image(systemName: "gearshape")
                    }
                }
                .checkingText(CheckingTypography.labelLarge)
                .foregroundStyle(glowBorder(autoActivitiesGlow, fallback: CheckingColors.primary))
                .frame(minWidth: Tokens.controlHeight, minHeight: Tokens.controlHeight)
                .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
            }
            .buttonStyle(.plain)
            .background(Capsule().fill(CheckingColors.cardBg))
            .shadow(color: glowColor(autoActivitiesGlow).opacity(autoActivitiesGlow == .none ? 0 : 0.7), radius: 8)
            .accessibilityLabel(t("auth.openSettingsAria", lang: languageCode))
            .accessibilityIdentifier("auth.settings")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var passwordVisibilityButton: some View {
        Button { passwordVisible.toggle() } label: {
            Image(systemName: passwordVisible ? "eye.slash" : "eye")
                .foregroundStyle(CheckingColors.textMuted)
                .frame(width: Tokens.iconLarge, height: Tokens.iconLarge)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t(passwordVisible ? "auth.hidePasswordAria" : "auth.showPasswordAria", lang: languageCode))
    }

    private var savedPasswordIndicator: some View {
        Image(systemName: "lock.fill")
            .foregroundStyle(CheckingColors.textMuted)
            .frame(width: Tokens.iconLarge, height: Tokens.iconLarge)
            .accessibilityHidden(true)
    }

    private func credentialField<Field: View>(
        label: String,
        placeholder: String,
        isEmpty: Bool,
        glow: FieldGlow,
        trailing: AnyView?,
        @ViewBuilder field: () -> Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .checkingText(CheckingTypography.labelLarge)
                .foregroundStyle(CheckingColors.textStrong)
            HStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    if isEmpty {
                        Text(placeholder)
                            .checkingText(CheckingTypography.bodySmall)
                            .foregroundStyle(CheckingColors.textMutedSoft)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .allowsTightening(true)
                            .allowsHitTesting(false)
                    }
                    field()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let trailing { trailing }
            }
            .padding(.horizontal, 12)
            // O ícone de senha possui 28 pt; 6 pt acima e abaixo fecha o controle em 40 pt,
            // igualando-o ao campo Chave sem reduzir o ícone nem prejudicar Dynamic Type.
            .padding(.vertical, 6)
            .frame(minHeight: Tokens.controlHeight)
            .background(CheckingColors.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular)
                    .stroke(glowBorder(glow, fallback: CheckingColors.inputBorder), lineWidth: glow == .none ? 1 : 1.5))
            .shadow(color: glowColor(glow).opacity(glow == .none ? 0 : 0.65), radius: 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func glowBorder(_ glow: FieldGlow, fallback: Color) -> Color {
        switch glow {
        case .pending: CheckingColors.fieldPendingBorder
        case .authenticated: CheckingColors.fieldAuthedBorder
        case .none: fallback
        }
    }

    private func glowColor(_ glow: FieldGlow) -> Color {
        switch glow {
        case .pending: CheckingColors.fieldPendingGlow
        case .authenticated: CheckingColors.fieldAuthedGlow
        case .none: .clear
        }
    }
}
