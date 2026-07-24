import SwiftUI

/// Port do ActivityLogDialog Android: conteúdo deliberadamente em inglês, newest-first,
/// agrupado por dia local e paginado em blocos de 30.
struct ActivityLogDialog: View {
    let entries: [ActivityLogEntry]
    let isLoading: Bool
    let canLoadMore: Bool
    let onLoadMore: () -> Void
    let onClear: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Button(action: onDismiss) {
                    Color.black.opacity(0.5).ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Tokens.sectionGap) {
                    Text("Activities")
                        .checkingText(CheckingTypography.titleLarge)
                        .foregroundStyle(CheckingColors.textStrong)
                        .accessibilityAddTraits(.isHeader)
                    Divider().overlay(CheckingColors.divider)

                    activityList
                        .frame(maxHeight: .infinity)

                    Divider().overlay(CheckingColors.divider)
                    HStack(spacing: 8) {
                        Button("Clear", action: onClear)
                            .buttonStyle(.plain)
                            .foregroundStyle(CheckingColors.textMuted)
                            .frame(minHeight: Tokens.controlHeight)
                            .accessibilityIdentifier("activities.clear")
                        Spacer()
                        Button("Close", action: onDismiss)
                            .buttonStyle(.plain)
                            .foregroundStyle(CheckingColors.primary)
                            .frame(minHeight: Tokens.controlHeight)
                            .accessibilityIdentifier("activities.close")
                    }
                }
                .padding(Tokens.cardPadding)
                .frame(
                    maxWidth: Tokens.cardMaxWidth,
                    maxHeight: min(650, max(300, proxy.size.height - 64)),
                    alignment: .topLeading)
                .background(CheckingColors.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadiusLarge, style: .circular))
                .shadow(color: .black.opacity(0.2), radius: Tokens.dialogElevation, y: 3)
                .padding(.horizontal, 16)
                .padding(.vertical, 32)
            }
        }
        .transition(.opacity)
        .zIndex(100)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder private var activityList: some View {
        if entries.isEmpty && !isLoading {
            Text("No activity recorded yet.")
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        if showsDayHeader(at: index) {
                            Text(dayText(entry.at))
                                .checkingText(CheckingTypography.labelMedium)
                                .foregroundStyle(CheckingColors.textMuted)
                                .padding(.top, index == 0 ? 0 : 4)
                        }
                        activityRow(entry)
                        Divider().overlay(CheckingColors.divider)
                            .onAppear {
                                if index >= entries.count - 3, canLoadMore, !isLoading {
                                    onLoadMore()
                                }
                            }
                    }
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(CheckingColors.primary)
                            Text("Loading…")
                                .checkingText(CheckingTypography.labelSmall)
                                .foregroundStyle(CheckingColors.textMuted)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .accessibilityIdentifier("activities.list")
        }
    }

    private func activityRow(_ entry: ActivityLogEntry) -> some View {
        let color = severityColor(entry.severity)
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(timeText(entry.at))
                    .font(.system(.caption2, design: .monospaced, weight: .semibold))
                    .foregroundStyle(CheckingColors.textMuted)
                Spacer()
                Text(entry.actor == .user ? "user" : "sys")
                    .checkingText(CheckingTypography.labelSmall)
                    .foregroundStyle(CheckingColors.textMuted)
                Text(kindText(entry.kind))
                    .checkingText(CheckingTypography.labelSmall)
                    .foregroundStyle(color)
            }
            Text(entry.description)
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func showsDayHeader(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(entries[index].at, inSameDayAs: entries[index - 1].at)
    }

    private func timeText(_ date: Date) -> String { Self.format(date, pattern: "HH:mm:ss") }
    private func dayText(_ date: Date) -> String { Self.format(date, pattern: "EEE, dd MMM yyyy") }

    private static func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private func severityColor(_ severity: ActivitySeverity) -> Color {
        switch severity {
        case .success: CheckingColors.success
        case .failure: CheckingColors.errorVivid
        case .warning: CheckingColors.activityWarning
        case .info: CheckingColors.activityInfo
        }
    }

    private func kindText(_ kind: ActivityKind) -> String {
        switch kind {
        case .checkIn: "check-in"
        case .checkOut: "check-out"
        case .active: "active"
        case .inactive: "inactive"
        case .trigger: "trigger"
        case .location: "location"
        case .sync: "sync"
        case .auth: "auth"
        case .system: "system"
        case .error: "error"
        }
    }
}
