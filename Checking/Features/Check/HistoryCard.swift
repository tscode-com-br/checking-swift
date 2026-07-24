import SwiftUI

enum LatestHistoryActivity: Sendable, Equatable { case checkIn, checkOut, none }

struct HistoryCellPresentation: Sendable, Equatable {
    let day: String?
    let date: String?
    let time: String?
    let latest: Bool
}

enum HistoryCardPresentation {
    static let singapore = TimeZone(identifier: "Asia/Singapore")!

    static func latest(_ history: HistoryState?) -> LatestHistoryActivity {
        switch (history?.lastCheckinAt, history?.lastCheckoutAt) {
        case let (checkIn?, checkOut?): return checkIn >= checkOut ? .checkIn : .checkOut
        case (_?, nil): return .checkIn
        case (nil, _?): return .checkOut
        case (nil, nil): return .none
        }
    }

    static func cell(
        instant: Date?,
        isLatest: Bool,
        now: Date = Date(),
        lang: String
    ) -> HistoryCellPresentation {
        guard let instant else { return HistoryCellPresentation(day: nil, date: nil, time: nil, latest: isLatest) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = singapore
        let instantDay = calendar.startOfDay(for: instant)
        let today = calendar.startOfDay(for: now)
        let day: String
        if instantDay == today {
            day = t("history.today", lang: lang)
        } else if instantDay == calendar.date(byAdding: .day, value: -1, to: today) {
            day = t("history.yesterday", lang: lang)
        } else {
            let formatter = DateFormatter()
            formatter.locale = locale(for: lang)
            formatter.timeZone = singapore
            formatter.dateFormat = "EEEE"
            let weekday = formatter.string(from: instant)
            day = weekday.prefix(1).uppercased(with: formatter.locale) + weekday.dropFirst()
        }
        return HistoryCellPresentation(
            day: day,
            date: format(instant, pattern: "dd/MM/yy", lang: lang),
            time: format(instant, pattern: "HH:mm", lang: lang),
            latest: isLatest
        )
    }

    static func locale(for lang: String) -> Locale {
        switch lang {
        case "pt": Locale(identifier: "pt_BR")
        case "zh": Locale(identifier: "zh_CN")
        case "ms": Locale(identifier: "ms_MY")
        case "id": Locale(identifier: "id_ID")
        case "tl": Locale(identifier: "fil_PH")
        default: Locale(identifier: "en_US")
        }
    }

    private static func format(_ date: Date, pattern: String, lang: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale(for: lang)
        formatter.timeZone = singapore
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

struct HistoryCard: View {
    let history: HistoryState?
    let languageCode: String
    var now = Date()
    var onCheckInTap: () -> Void = {}
    var onCheckOutTap: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let latest = HistoryCardPresentation.latest(history)
        TintedPanel {
            Group {
                if dynamicTypeSize > .large {
                    VStack(spacing: 6) { cells(latest: latest) }
                } else {
                    HStack(spacing: 6) { cells(latest: latest) }
                }
            }
        }
    }

    @ViewBuilder private func cells(latest: LatestHistoryActivity) -> some View {
                cell(
                    label: t("history.lastCheckinLabel", lang: languageCode),
                    compactLabel: t("history.activityCheckin", lang: languageCode),
                    accessibilityIdentifier: "history.checkin",
                    presentation: HistoryCardPresentation.cell(
                        instant: history?.lastCheckinAt,
                        isLatest: latest == .checkIn,
                        now: now,
                        lang: languageCode),
                    action: onCheckInTap)
                cell(
                    label: t("history.lastCheckoutLabel", lang: languageCode),
                    compactLabel: t("history.activityCheckout", lang: languageCode),
                    accessibilityIdentifier: "history.checkout",
                    presentation: HistoryCardPresentation.cell(
                        instant: history?.lastCheckoutAt,
                        isLatest: latest == .checkOut,
                        now: now,
                        lang: languageCode),
                    action: onCheckOutTap)
    }

    private func cell(
        label: String,
        compactLabel: String,
        accessibilityIdentifier: String,
        presentation: HistoryCellPresentation,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text((dynamicTypeSize.isAccessibilitySize ? compactLabel : label)
                    .uppercased(with: HistoryCardPresentation.locale(for: languageCode)) + ":")
                    .checkingText(CheckingTypography.labelSmall)
                    .fontWeight(.bold)
                    .foregroundStyle(CheckingColors.textMutedLight)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
                if let day = presentation.day, let date = presentation.date, let time = presentation.time {
                    Text(day).checkingText(CheckingTypography.bodySmall)
                    Text(date).checkingText(CheckingTypography.titleSmall)
                    Text(time).checkingText(CheckingTypography.bodyMedium)
                } else {
                    Text("--").checkingText(CheckingTypography.titleSmall)
                }
            }
            .foregroundStyle(CheckingColors.textStrong)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.vertical, 12)
            .background(presentation.latest ? CheckingColors.latestBg : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular)
                    .stroke(presentation.latest ? CheckingColors.latestBorder : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(presentation.date ?? "--") \(presentation.time ?? "")")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
