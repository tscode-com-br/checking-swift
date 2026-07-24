import SwiftUI

struct ChoiceCard: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    var identifier: String? = nil

    var body: some View {
        Button(action: action) {
            Text(label)
                .checkingText(CheckingTypography.labelLarge)
                .foregroundStyle(CheckingColors.textStrong)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: Tokens.controlHeight)
                .padding(.horizontal, 6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .background(selected ? CheckingColors.choiceSelectedBg : CheckingColors.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular)
                .stroke(selected ? CheckingColors.primaryDark : CheckingColors.inputBorder, lineWidth: 1))
        .shadow(color: selected ? CheckingColors.primary.opacity(0.28) : .clear, radius: 8, y: -1)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .modifier(OptionalAccessibilityIdentifier(identifier: identifier))
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?
    func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier(identifier) }
        else { content }
    }
}

struct RegistrationFieldset: View {
    let selectedAction: CheckAction
    let transportEnabled: Bool
    let languageCode: String
    let onActionSelected: (CheckAction) -> Void
    var onTransportTap: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.itemGap) {
            sectionLabel(t("registration.sectionTitle", lang: languageCode))
            Group {
                if dynamicTypeSize > .large {
                    VStack(spacing: 8) { choices }
                } else {
                    HStack(spacing: 8) { choices }
                }
            }
        }
    }

    @ViewBuilder private var choices: some View {
                ChoiceCard(
                    label: t("registration.checkinLabel", lang: languageCode),
                    selected: selectedAction == .checkIn,
                    action: { onActionSelected(.checkIn) },
                    identifier: "registration.checkin")
                ChoiceCard(
                    label: t("registration.checkoutLabel", lang: languageCode),
                    selected: selectedAction == .checkOut,
                    action: { onActionSelected(.checkOut) },
                    identifier: "registration.checkout")
                if transportEnabled, let onTransportTap {
                    Button(action: onTransportTap) {
                        Text(t("registration.transportLabel", lang: languageCode))
                            .checkingText(CheckingTypography.labelLarge)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: Tokens.controlHeight)
                    }
                    .buttonStyle(.plain)
                    .background(
                        LinearGradient(
                            colors: [CheckingColors.transportChoiceBgStart, CheckingColors.transportChoiceBgEnd],
                            startPoint: .leading,
                            endPoint: .trailing))
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
                    .shadow(color: CheckingColors.transportChoiceBgEnd.opacity(0.5), radius: 10)
                    .accessibilityIdentifier("registration.transport")
                }
    }
}

struct InformeFieldset: View {
    let selected: UiInformeType
    let languageCode: String
    let onSelected: (UiInformeType) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.itemGap) {
            sectionLabel(t("registration.informeTitle", lang: languageCode))
            Group {
                if dynamicTypeSize > .large {
                    VStack(spacing: 8) { choices }
                } else {
                    HStack(spacing: 8) { choices }
                }
            }
        }
    }

    @ViewBuilder private var choices: some View {
                ChoiceCard(
                    label: t("registration.informeNormalLabel", lang: languageCode),
                    selected: selected == .normal,
                    action: { onSelected(.normal) },
                    identifier: "registration.informe.normal")
                ChoiceCard(
                    label: t("registration.informeRetroativoLabel", lang: languageCode),
                    selected: selected == .retroativo,
                    action: { onSelected(.retroativo) },
                    identifier: "registration.informe.retroativo")
    }
}

struct ProjectsFieldset: View {
    let catalog: [Project]
    let memberships: [String]
    let isLoading: Bool
    let languageCode: String
    let onMembershipToggled: (String) -> Void
    @State private var expanded: Bool

    init(
        catalog: [Project],
        memberships: [String],
        isLoading: Bool,
        languageCode: String,
        initiallyExpanded: Bool = false,
        onMembershipToggled: @escaping (String) -> Void
    ) {
        self.catalog = catalog
        self.memberships = memberships
        self.isLoading = isLoading
        self.languageCode = languageCode
        self.onMembershipToggled = onMembershipToggled
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var options: [String] { catalog.isEmpty ? memberships : catalog.map(\.name) }
    private var summary: String {
        if !memberships.isEmpty { return memberships.joined(separator: ", ") }
        return t(isLoading ? "projects.loadingProjects" : "projects.noneAvailableShort", lang: languageCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.itemGap) {
            sectionLabel(t("projects.label", lang: languageCode))
            fieldButton(text: summary, muted: memberships.isEmpty) { expanded.toggle() }
                .accessibilityIdentifier("projects.selector")
                .accessibilityLabel(t("projects.label", lang: languageCode))
                .accessibilityValue(summary)
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    if options.isEmpty {
                        Text(t(isLoading ? "projects.loadingProjects" : "projects.noneAvailableSentence", lang: languageCode))
                            .checkingText(CheckingTypography.bodySmall)
                            .foregroundStyle(CheckingColors.textMuted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(options, id: \.self) { name in
                            let checked = memberships.contains(name)
                            Button { if !isLoading { onMembershipToggled(name) } } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(checked ? CheckingColors.primary : CheckingColors.inputBorder)
                                        .accessibilityHidden(true)
                                    Text(name)
                                        .checkingText(CheckingTypography.bodyMedium)
                                        .foregroundStyle(checked ? CheckingColors.primary : CheckingColors.textStrong)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading)
                            .accessibilityAddTraits(checked ? .isSelected : [])
                            .accessibilityIdentifier("projects.option.\(name)")
                        }
                    }
                }
                .background(CheckingColors.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
                .overlay(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular)
                    .stroke(CheckingColors.inputBorder, lineWidth: 1))
            }
        }
    }
}

struct LocationSelectField: View {
    let locations: [String]
    let selected: String?
    let languageCode: String
    let onSelected: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.itemGap) {
            sectionLabel(t("location.title", lang: languageCode))
            fieldButton(
                text: selected ?? t("location.manualSelectPlaceholder", lang: languageCode),
                muted: selected == nil) { expanded.toggle() }
                .accessibilityIdentifier("location.selector")
                .accessibilityLabel(t("location.title", lang: languageCode))
                .accessibilityValue(selected ?? t("location.manualSelectPlaceholder", lang: languageCode))
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(locations, id: \.self) { location in
                        let isSelected = location == selected
                        Button {
                            onSelected(location)
                            expanded = false
                        } label: {
                            Text(location)
                                .checkingText(CheckingTypography.bodyMedium)
                                .foregroundStyle(isSelected ? CheckingColors.primary : CheckingColors.textStrong)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(isSelected ? CheckingColors.choiceSelectedBg : CheckingColors.cardBg)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("location.option.\(location)")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
                .overlay(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular)
                    .stroke(CheckingColors.inputBorder, lineWidth: 1))
            }
        }
    }
}

@MainActor
private func sectionLabel(_ text: String) -> some View {
    Text(text)
        .checkingText(CheckingTypography.labelLarge)
        .foregroundStyle(CheckingColors.textStrong)
        .accessibilityAddTraits(.isHeader)
}

@MainActor
private func fieldButton(text: String, muted: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 8) {
            Text(text)
                .checkingText(CheckingTypography.bodyLarge)
                .foregroundStyle(muted ? CheckingColors.textMutedSoft : CheckingColors.textStrong)
                .lineLimit(3)
            Spacer()
            Image(systemName: "chevron.down")
                .foregroundStyle(CheckingColors.textMutedSoft)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: Tokens.controlHeight)
    }
    .buttonStyle(.plain)
    .background(CheckingColors.cardBg)
    .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
    .overlay(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular)
        .stroke(CheckingColors.inputBorder, lineWidth: 1))
}
