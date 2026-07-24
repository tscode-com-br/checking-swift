import SwiftUI

struct InformationScreenShell<Content: View>: View {
    let title: String
    let backLabel: String
    let onBack: () -> Void
    @ViewBuilder let content: Content

    init(title: String, backLabel: String, onBack: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.backLabel = backLabel
        self.onBack = onBack
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(.headline, design: .default, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(CheckingColors.onPrimary)
                .accessibilityLabel(backLabel)
                .accessibilityIdentifier("information.back")
                Text(title)
                    .checkingText(CheckingTypography.titleMedium)
                    .foregroundStyle(CheckingColors.onPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(minHeight: Tokens.headerHeight)
            .background(CheckingColors.headerBg)

            ScrollView {
                content
                    .frame(maxWidth: Tokens.cardMaxWidth, alignment: .leading)
                    .padding(Tokens.sectionGapLarge)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("information.scroll")
        }
        .background(
            LinearGradient(colors: [CheckingColors.surfaceStart, CheckingColors.surfaceEnd],
                           startPoint: .top, endPoint: .bottom))
    }
}

struct InformationDivider: View {
    var body: some View { Divider().overlay(CheckingColors.divider) }
}

struct RichInformationBody: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                richLine(line)
            }
        }
    }

    @ViewBuilder private func richLine(_ line: String) -> some View {
        if line.hasPrefix("## ") {
            Text(String(line.dropFirst(3)))
                .checkingText(CheckingTypography.titleSmall)
                .foregroundStyle(CheckingColors.textStrong)
                .padding(.top, 5)
                .accessibilityAddTraits(.isHeader)
        } else if line.hasPrefix("• ") {
            HStack(alignment: .top, spacing: 7) {
                Text("•").foregroundStyle(CheckingColors.primary)
                Text(String(line.dropFirst(2)))
                    .checkingText(CheckingTypography.bodySmall)
                    .foregroundStyle(CheckingColors.textStrong)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else if line.hasPrefix("! ") {
            Text(String(line.dropFirst(2)))
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CheckingColors.cardBg, in: RoundedRectangle(cornerRadius: 8))
        } else if line.isEmpty {
            Spacer().frame(height: 4)
        } else {
            Text(line)
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.textStrong)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct InformationSection: View {
    let title: String
    let text: String
    var primary = true

    init(title: String, body: String, primary: Bool = true) {
        self.title = title
        self.text = body
        self.primary = primary
    }

    var bodyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .checkingText(primary ? CheckingTypography.titleMedium : CheckingTypography.titleSmall)
                .foregroundStyle(primary ? CheckingColors.primary : CheckingColors.textStrong)
                .accessibilityAddTraits(.isHeader)
            RichInformationBody(text: text)
            InformationDivider().padding(.top, 4)
        }
    }

    var body: some View { bodyView }
}

enum SupportLinkBuilder {
    static func url(chave: String, languageCode: String = "pt") -> URL? {
        let number = t("support.phoneNumber", lang: languageCode)
        let message = t("support.messageTemplate", ["chave": chave], lang: languageCode)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "wa.me"
        components.path = "/\(number)"
        components.queryItems = [URLQueryItem(name: "text", value: message)]
        return components.url
    }
}

enum PrivacyConfig {
    static let controllerLegalName = "Tamer Salmem"
    static let privacyRequestsEmail = "tscode.com.br@gmail.com"
    static let privacyPolicyURL = URL(string: "https://www.tscode.com.br/checking/privacidade")!
    static let hostingCountry = "Singapura"
    static let retentionCheckHistory = "enquanto durar o uso e pelo prazo de obrigações legais"
    static let retentionAccidentVideo = "pelo prazo necessário à apuração e a obrigações legais"
    static let retentionLocalLogDays = 30
    static let minimumAge = 18
}

enum PrivacyLinkBuilder {
    static func emailURL(chave: String, languageCode: String = "pt") -> URL? {
        let values = ["chave": chave]
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = PrivacyConfig.privacyRequestsEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: t("privacy.contactSubject", values, lang: languageCode)),
            URLQueryItem(name: "body", value: t("privacy.contactBody", values, lang: languageCode)),
        ]
        return components.url
    }
}
