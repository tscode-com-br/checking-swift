import SwiftUI

struct AboutScreen: View {
    let languageCode: String
    let onBack: () -> Void

    var body: some View {
        InformationScreenShell(
            title: t("about.heading", lang: languageCode),
            backLabel: t("settings.backButton", lang: languageCode),
            onBack: onBack
        ) {
            VStack(alignment: .leading, spacing: Tokens.sectionGapLarge) {
                section("intro", primary: true)
                section("parts", bodyKey: "partsIntro", primary: true)
                subpart("partApi")
                subpart("partWebsite")
                subpart("partWebapp")
                subpart("partTransport")
                subpart("partAndroid")
                section("rules", bodyKey: "rulesIntro", primary: true)
                subpart("rulesWeb")
                subpart("rulesNative")
                section("notes", primary: true)
                Spacer().frame(height: 16)
            }
            .accessibilityIdentifier("about.content")
        }
    }

    private func section(_ key: String, bodyKey: String? = nil, primary: Bool) -> some View {
        InformationSection(
            title: t("about.\(key)Title", lang: languageCode),
            body: t("about.\(bodyKey ?? key + "Body")", lang: languageCode),
            primary: primary)
    }

    private func subpart(_ key: String) -> some View {
        section(key, primary: false)
    }
}
