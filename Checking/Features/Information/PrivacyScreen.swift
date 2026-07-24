import SwiftUI

struct PrivacyScreen: View {
    let chave: String
    let languageCode: String
    let onBack: () -> Void
    let onDeleteLocalData: () async -> Void
    @Environment(\.openURL) private var openURL
    @State private var confirmsLocalDeletion = false
    @State private var deletedNotice = false
    @State private var isDeleting = false

    var body: some View {
        InformationScreenShell(
            title: t("privacy.heading", lang: languageCode),
            backLabel: t("settings.backButton", lang: languageCode),
            onBack: onBack
        ) {
            VStack(alignment: .leading, spacing: Tokens.sectionGapLarge) {
                RichInformationBody(text: t("privacy.intro", values, lang: languageCode))
                privacySection("purpose")
                privacySection("data")
                privacySection("legalBasis")
                privacySection("retention")
                privacySection("sharing")
                privacySection("controller")
                privacySection("rights")
                privacySection("automated")
                privacySection("security")
                privacySection("age")

                PrimaryButton(text: t("privacy.contactDpo", lang: languageCode), action: openPrivacyEmail)
                    .accessibilityIdentifier("privacy.contact")
                secondaryButton(t("privacy.requestAccountDeletion", lang: languageCode), id: "privacy.requestDeletion") {
                    openPrivacyEmail()
                }
                secondaryButton(t("privacy.deleteLocalData", lang: languageCode), id: "privacy.deleteLocal") {
                    confirmsLocalDeletion = true
                }
                secondaryButton(t("privacy.openFullPolicy", lang: languageCode), id: "privacy.policy") {
                    openURL(PrivacyConfig.privacyPolicyURL)
                }
                if deletedNotice {
                    Text(t("privacy.deleteLocalDataDone", lang: languageCode))
                        .checkingText(CheckingTypography.bodyMedium)
                        .foregroundStyle(CheckingColors.primary)
                }
                Spacer().frame(height: 16)
            }
            .accessibilityIdentifier("privacy.content")
        }
        .alert(t("privacy.deleteLocalData", lang: languageCode), isPresented: $confirmsLocalDeletion) {
            Button(t("privacy.cancel", lang: languageCode), role: .cancel) {}
            Button(t("privacy.confirm", lang: languageCode), role: .destructive) {
                isDeleting = true
                Task {
                    await onDeleteLocalData()
                    isDeleting = false
                    deletedNotice = true
                }
            }
        } message: {
            Text(t("privacy.deleteLocalDataConfirm", lang: languageCode))
        }
    }

    private var values: [String: String] {
        [
            "controller": PrivacyConfig.controllerLegalName,
            "privacyEmail": PrivacyConfig.privacyRequestsEmail,
            "hostingCountry": PrivacyConfig.hostingCountry,
            "retentionHistory": PrivacyConfig.retentionCheckHistory,
            "retentionVideo": PrivacyConfig.retentionAccidentVideo,
            "retentionLocalDays": String(PrivacyConfig.retentionLocalLogDays),
            "minAge": String(PrivacyConfig.minimumAge),
            "chave": chave,
        ]
    }

    private func privacySection(_ key: String) -> some View {
        InformationSection(
            title: t("privacy.\(key)Title", lang: languageCode),
            body: t("privacy.\(key)Body", values, lang: languageCode),
            primary: false)
    }

    private func secondaryButton(_ text: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .checkingText(CheckingTypography.labelLarge)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Tokens.buttonPaddingHorizontal)
                .padding(.vertical, Tokens.buttonPaddingVertical)
                .foregroundStyle(CheckingColors.primary)
                .background(CheckingColors.cardBg)
                .overlay(RoundedRectangle(cornerRadius: Tokens.controlRadius)
                    .stroke(CheckingColors.primary, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius))
        }
        .buttonStyle(.plain)
        .disabled(isDeleting)
        .accessibilityIdentifier(id)
    }

    private func openPrivacyEmail() {
        if let url = PrivacyLinkBuilder.emailURL(chave: chave, languageCode: languageCode) {
            openURL(url)
        }
    }
}
