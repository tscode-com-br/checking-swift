import SwiftUI

struct LocationCard: View {
    let locationMatch: LocationMatch?
    let isLoading: Bool
    let languageCode: String
    let onRefresh: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var valueColor: Color {
        guard let locationMatch else { return CheckingColors.locationMuted }
        if locationMatch.matched { return CheckingColors.locationSuccess }
        if locationMatch.status == .accuracyTooLow { return CheckingColors.locationError }
        return CheckingColors.textStrong
    }

    private var accuracy: String {
        guard let meters = locationMatch?.accuracyMeters else { return "--" }
        return t("location.accuracyTemplate", ["accuracy": "±\(Int(meters.rounded())) m"], lang: languageCode)
    }

    var body: some View {
        TintedPanel {
            VStack(alignment: .leading, spacing: Tokens.itemGap) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 4) {
                            locationTitle
                            accuracyText
                        }
                    } else {
                        HStack {
                            locationTitle
                            Spacer()
                            accuracyText
                        }
                    }
                }
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) { locationValueAndRefresh }
                    } else {
                        HStack(spacing: 12) { locationValueAndRefresh }
                    }
                }
            }
        }
    }

    private var locationTitle: some View {
        Text(t("location.title", lang: languageCode).uppercased())
            .checkingText(CheckingTypography.labelSmall)
            .foregroundStyle(CheckingColors.textMutedLight)
            .accessibilityAddTraits(.isHeader)
    }

    private var accuracyText: some View {
        Text(accuracy)
            .checkingText(CheckingTypography.labelSmall)
            .foregroundStyle(locationMatch?.status == .accuracyTooLow
                ? CheckingColors.locationError : CheckingColors.textMutedLight)
    }

    @ViewBuilder private var locationValueAndRefresh: some View {
        Text(locationMatch?.label ?? t("location.waitingLabel", lang: languageCode))
            .checkingText(CheckingTypography.bodyLarge)
            .foregroundStyle(valueColor)
            .frame(maxWidth: .infinity, alignment: .leading)
        Button(action: onRefresh) {
            Group {
                if isLoading { ProgressView().tint(CheckingColors.teal).scaleEffect(0.75) }
                else { Image(systemName: "arrow.clockwise").foregroundStyle(CheckingColors.teal) }
            }
            .frame(minWidth: Tokens.controlHeight, minHeight: Tokens.controlHeight)
        }
        .buttonStyle(.plain)
        .background(CheckingColors.teal.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
        .overlay(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular)
            .stroke(CheckingColors.teal.opacity(0.24), lineWidth: 1))
        .disabled(isLoading)
        .accessibilityLabel(t("location.refreshLabel", lang: languageCode))
        .accessibilityIdentifier("location.refresh")
    }
}
