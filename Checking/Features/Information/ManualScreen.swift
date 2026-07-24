import SwiftUI

struct ManualScreen: View {
    let languageCode: String
    let onBack: () -> Void

    var body: some View {
        InformationScreenShell(
            title: t("settings.manualLabel", lang: languageCode),
            backLabel: t("settings.backButton", lang: languageCode),
            onBack: onBack
        ) {
            VStack(alignment: .leading, spacing: Tokens.sectionGap) {
                Text(t("iosManual.introPrimary", lang: languageCode))
                    .checkingText(CheckingTypography.bodyMedium)
                    .foregroundStyle(CheckingColors.textStrong)
                Text(t("iosManual.introSecondary", lang: languageCode))
                    .checkingText(CheckingTypography.bodySmall)
                    .foregroundStyle(CheckingColors.textMuted)
                InformationDivider()
                ForEach(Array(sections.enumerated()), id: \.element.key) { index, section in
                    IOSManualSectionView(
                        index: index + 1,
                        section: section,
                        languageCode: languageCode)
                }
            }
            .accessibilityIdentifier("manual.content")
        }
    }

    private var sections: [IOSManualSectionModel] {
        [
            .init("introduction", itemCount: 4, callout: "callout"),
            .init("firstUse", itemCount: 1, topics: [
                .init("noAccount", itemCount: 4, figures: [
                    .init(image: "ios_manual_first_use", caption: "caption1", annotations: [
                        .init(x: 0.07, y: 0.305, width: 0.37, height: 0.055, label: "annotationKey"),
                    ]),
                    .init(image: "ios_manual_self_registration", caption: "caption2"),
                ]),
                .init("noPassword", itemCount: 3, figures: [
                    .init(image: "ios_manual_password_registration", caption: "caption"),
                ]),
                .init("projects", itemCount: 4, figures: [
                    .init(image: "ios_manual_projects", caption: "caption", annotations: [
                        .init(x: 0.07, y: 0.69, width: 0.85, height: 0.15, label: "annotationProjects"),
                    ]),
                ], callout: "callout"),
            ]),
            .init("settings", itemCount: 1, topics: [
                .init("automatic", itemCount: 5, figures: [
                    .init(image: "ios_manual_settings", caption: "caption1"),
                    .init(image: "ios_manual_automatic", caption: "caption2"),
                ], callout: "callout"),
                .init("manual", itemCount: 5, figures: [
                    .init(image: "ios_manual_main", caption: "caption", annotations: [
                        .init(x: 0.07, y: 0.51, width: 0.85, height: 0.075, label: "annotationAction"),
                        .init(x: 0.07, y: 0.60, width: 0.85, height: 0.075, label: "annotationAttendance"),
                        .init(x: 0.07, y: 0.78, width: 0.85, height: 0.15, label: "annotationLocalSubmit"),
                    ]),
                ]),
                .init("pause", itemCount: 4, figures: [
                    .init(image: "ios_manual_pause", caption: "caption"),
                ]),
                .init("notifications", itemCount: 4, figures: [
                    .init(image: "ios_manual_notifications", caption: "caption"),
                ]),
                .init("password", itemCount: 3, figures: [
                    .init(image: "ios_manual_password_change", caption: "caption"),
                ]),
                .init("deletion", itemCount: 4, figures: [
                    .init(image: "ios_manual_settings", caption: "caption", annotations: [
                        .init(x: 0.10, y: 0.875, width: 0.80, height: 0.06, label: "annotationDelete"),
                    ]),
                ], callout: "callout"),
            ]),
            .init("main", itemCount: 1, topics: [
                .init("history", itemCount: 3, figures: [
                    .init(image: "ios_manual_main", caption: "caption1", annotations: [
                        .init(x: 0.07, y: 0.18, width: 0.85, height: 0.14, label: "annotationCards"),
                    ]),
                    .init(image: "ios_manual_history", caption: "caption2"),
                ]),
                .init("notificationBar", itemCount: 4, figures: [
                    .init(image: "ios_manual_main", caption: "caption", annotations: [
                        .init(x: 0.07, y: 0.33, width: 0.85, height: 0.075, label: "annotationBar"),
                    ]),
                ]),
                .init("location", itemCount: 4, figures: [
                    .init(image: "ios_manual_location", caption: "caption", annotations: [
                        .init(x: 0.07, y: 0.40, width: 0.85, height: 0.09, label: "annotationLocation"),
                    ]),
                ], callout: "callout"),
                .init("registration", itemCount: 1),
                .init("attendance", itemCount: 1),
                .init("projects", itemCount: 1),
            ]),
            .init("accident", itemCount: 2, callout: "callout"),
        ]
    }
}

private struct IOSManualAnnotation: Identifiable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let label: String
    var id: String { label }
}

private struct IOSManualFigure: Identifiable {
    let image: String
    let caption: String
    var annotations: [IOSManualAnnotation] = []
    var id: String { image + caption }
}

private struct IOSManualTopicModel: Identifiable {
    let key: String
    let itemCount: Int
    let figures: [IOSManualFigure]
    let callout: String?
    var id: String { key }

    init(_ key: String, itemCount: Int, figures: [IOSManualFigure] = [], callout: String? = nil) {
        self.key = key
        self.itemCount = itemCount
        self.figures = figures
        self.callout = callout
    }
}

private struct IOSManualSectionModel: Identifiable {
    let key: String
    let itemCount: Int
    let topics: [IOSManualTopicModel]
    let callout: String?
    var id: String { key }

    init(
        _ key: String,
        itemCount: Int,
        topics: [IOSManualTopicModel] = [],
        callout: String? = nil
    ) {
        self.key = key
        self.itemCount = itemCount
        self.topics = topics
        self.callout = callout
    }
}

private struct IOSManualSectionView: View {
    let index: Int
    let section: IOSManualSectionModel
    let languageCode: String

    private var prefix: String { "iosManual.sections.\(section.key)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Text(String(format: "%02d", index))
                    .checkingText(CheckingTypography.labelLarge)
                    .foregroundStyle(CheckingColors.primary)
                Text(t("\(prefix).title", lang: languageCode))
                    .checkingText(CheckingTypography.titleSmall)
                    .foregroundStyle(CheckingColors.textStrong)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ManualBulletParagraph(
                text: t("\(prefix).lead", lang: languageCode),
                color: CheckingColors.textMuted)
            ManualBulletList(prefix: prefix, itemCount: section.itemCount, languageCode: languageCode)
            if let callout = section.callout {
                ManualCallout(text: t("\(prefix).\(callout)", lang: languageCode))
            }

            ForEach(Array(section.topics.enumerated()), id: \.element.key) { topicIndex, topic in
                IOSManualTopicView(
                    number: "\(index).\(topicIndex + 1)",
                    prefix: "\(prefix).topics.\(topic.key)",
                    topic: topic,
                    languageCode: languageCode)
            }
            InformationDivider().padding(.top, 4)
        }
    }
}

private struct IOSManualTopicView: View {
    let number: String
    let prefix: String
    let topic: IOSManualTopicModel
    let languageCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(number)  \(t("\(prefix).title", lang: languageCode))")
                .checkingText(CheckingTypography.titleSmall)
                .foregroundStyle(CheckingColors.primary)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            ManualBulletParagraph(
                text: t("\(prefix).lead", lang: languageCode),
                color: CheckingColors.textMuted)
            ManualBulletList(prefix: prefix, itemCount: topic.itemCount, languageCode: languageCode)
            if let callout = topic.callout {
                ManualCallout(text: t("\(prefix).\(callout)", lang: languageCode))
            }
            ForEach(topic.figures) { figure in
                ManualBundledImage(
                    name: figure.image,
                    annotations: figure.annotations,
                    prefix: prefix,
                    languageCode: languageCode)
                Text(t("\(prefix).\(figure.caption)", lang: languageCode))
                    .checkingText(CheckingTypography.labelSmall)
                    .foregroundStyle(CheckingColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            Rectangle().fill(CheckingColors.primary.opacity(0.16)).frame(width: 2)
        }
    }
}

private struct ManualBulletList: View {
    let prefix: String
    let itemCount: Int
    let languageCode: String

    var body: some View {
        if itemCount > 0 {
            ForEach(1 ... itemCount, id: \.self) { number in
                ManualBulletParagraph(
                    text: t("\(prefix).item\(number)", lang: languageCode),
                    color: CheckingColors.textStrong)
            }
        }
    }
}

private struct ManualBulletParagraph: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text("•")
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.primary)
            Text(text)
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ManualCallout: View {
    let text: String

    var body: some View {
        Text(text)
            .checkingText(CheckingTypography.bodySmall)
            .foregroundStyle(CheckingColors.textStrong)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CheckingColors.choiceSelectedBg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CheckingColors.primary.opacity(0.25)))
    }
}

private struct ManualBundledImage: View {
    let name: String
    let annotations: [IOSManualAnnotation]
    let prefix: String
    let languageCode: String

    var body: some View {
        if let path = Bundle.main.path(forResource: name, ofType: "png"),
           let uiImage = UIImage(contentsOfFile: path) {
            VStack(alignment: .leading, spacing: 7) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 310)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        GeometryReader { proxy in
                            ForEach(Array(annotations.enumerated()), id: \.element.id) { offset, annotation in
                                annotationOverlay(annotation, number: offset + 1, size: proxy.size)
                            }
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(CheckingColors.divider))
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)

                ForEach(Array(annotations.enumerated()), id: \.element.id) { offset, annotation in
                    HStack(alignment: .top, spacing: 7) {
                        annotationBadge(offset + 1)
                        Text(t("\(prefix).\(annotation.label)", lang: languageCode))
                            .checkingText(CheckingTypography.labelSmall)
                            .foregroundStyle(CheckingColors.textStrong)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func annotationOverlay(_ annotation: IOSManualAnnotation, number: Int, size: CGSize) -> some View {
        let rect = CGRect(
            x: annotation.x * size.width,
            y: annotation.y * size.height,
            width: annotation.width * size.width,
            height: annotation.height * size.height)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7)
                .stroke(CheckingColors.fieldPendingBorder, lineWidth: 3)
            annotationBadge(number).offset(x: 4, y: 4)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    private func annotationBadge(_ number: Int) -> some View {
        Text("\(number)")
            .font(.system(.caption2, design: .default, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(CheckingColors.fieldPendingBorder, in: Circle())
    }
}
