import SwiftUI

struct AutoActivitiesNudgeCard: View {
    let languageCode: String
    let onActivate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        TintedPanel {
            Text(t("autoActivities.nudgeQuestion", lang: languageCode))
                .checkingText(CheckingTypography.bodyMedium)
                .foregroundStyle(CheckingColors.textStrong)
            HStack(spacing: 8) {
                Button(t("autoActivities.nudgeLater", lang: languageCode), action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(CheckingColors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: Tokens.controlHeight)
                    .accessibilityIdentifier("automatic.nudge.later")
                PrimaryButton(
                    text: t("autoActivities.nudgeActivate", lang: languageCode),
                    action: onActivate)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("automatic.nudge.activate")
            }
        }
    }
}

struct AutoActivitiesDialog: View {
    let enabled: Bool
    let permissions: PermissionsStatus?
    let consentGranted: Bool
    let languageCode: String
    let onToggle: (Bool) -> Void
    let onRequestNotifications: () -> Void
    let onRequestLocation: () -> Void
    let onRequestAlways: () -> Void
    let onOpenSettings: () -> Void
    let onConsent: () -> Void
    let onDismiss: () -> Void
    @State private var showsBackgroundDisclosure = false
    @State private var enableAfterDisclosure = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        CheckingDialogScaffold(onDismiss: onDismiss) {
            Text(t("autoActivities.title", lang: languageCode))
                .checkingText(CheckingTypography.titleLarge)
                .foregroundStyle(CheckingColors.textStrong)
            Divider().overlay(CheckingColors.divider)
            Text(t("autoActivities.explanation", lang: languageCode))
                .checkingText(CheckingTypography.bodyMedium)
                .foregroundStyle(CheckingColors.textMuted)
            Toggle(
                t("autoActivities.enable", lang: languageCode),
                isOn: Binding(get: { enabled }, set: { next in
                    if next && !consentGranted {
                        enableAfterDisclosure = true
                        showsBackgroundDisclosure = true
                    } else {
                        onToggle(next)
                    }
                }))
                .tint(CheckingColors.primary)
                .accessibilityIdentifier("automatic.enabled")
            Divider().overlay(CheckingColors.divider)
            permissionRow(
                t("autoActivities.permNotifications", lang: languageCode),
                granted: permissions?.notificationsGranted == true,
                action: permissions?.notificationAuthorization == .denied ? onOpenSettings : onRequestNotifications)
            permissionRow(
                t("autoActivities.permPreciseLocation", lang: languageCode),
                granted: permissions?.preciseLocationGranted == true,
                action: permissions?.locationAuthorization == .denied ? onOpenSettings : onRequestLocation)
            permissionRow(
                t("autoActivities.permAlwaysLocation", lang: languageCode),
                granted: permissions?.alwaysLocationGranted == true,
                action: requestAlwaysPermission)
            permissionRow(
                t("autoActivities.permBackgroundRefresh", lang: languageCode),
                granted: permissions?.backgroundRefresh == .available,
                actionAvailable: permissions?.backgroundRefresh != .restricted,
                action: onOpenSettings)
            if enabled, permissions?.ladder.minimumToStartGranted != true {
                Text(t("autoActivities.insufficientPermissions", lang: languageCode))
                    .checkingText(CheckingTypography.bodySmall)
                    .foregroundStyle(CheckingColors.error)
            } else if enabled, permissions?.automationHealthLevel != .operational {
                Text(t("autoActivities.reducedReliability", lang: languageCode))
                    .checkingText(CheckingTypography.bodySmall)
                    .foregroundStyle(CheckingColors.textMuted)
            }
            PrimaryButton(
                text: t("autoActivities.reviewPermissions", lang: languageCode),
                action: reviewNextPermission,
                enabled: canReviewPermissions)
                .accessibilityIdentifier("automatic.reviewPermissions")
            closeButton(t("autoActivities.close", lang: languageCode), onDismiss)
        }
        .alert(t("autoActivities.bgDisclosureTitle", lang: languageCode), isPresented: $showsBackgroundDisclosure) {
            Button(t("autoActivities.bgDisclosureDecline", lang: languageCode), role: .cancel) {
                enableAfterDisclosure = false
            }
            Button(t("autoActivities.bgDisclosureAccept", lang: languageCode)) {
                onConsent()
                if enableAfterDisclosure { onToggle(true) }
                if permissions?.alwaysLocationGranted != true { continueAuthorizationAfterDisclosure() }
                enableAfterDisclosure = false
            }
        } message: {
            Text(t("autoActivities.bgDisclosureBody", lang: languageCode))
        }
    }

    private func reviewNextPermission() {
        guard let permissions else { onRequestNotifications(); return }
        switch permissions.ladder.nextStep {
        case .notifications: onRequestNotifications()
        case .preciseLocation: onRequestLocation()
        case .alwaysLocation:
            enableAfterDisclosure = false
            showsBackgroundDisclosure = true
        case nil:
            if permissions.backgroundRefresh == .denied { onOpenSettings() }
        }
    }

    private var canReviewPermissions: Bool {
        guard let permissions else { return true }
        return !permissions.ladder.allRecommendedGranted
            || permissions.backgroundRefresh == .denied
    }

    private func requestAlwaysPermission() {
        switch permissions?.locationAuthorization {
        case .none, .some(.notDetermined):
            // Primeiro estágio obrigatório. Depois de o usuário conceder "Durante o Uso",
            // a mesma linha passa a oferecer o upgrade in-app para "Sempre".
            onRequestLocation()
        case .some(.whenInUse):
            enableAfterDisclosure = false
            showsBackgroundDisclosure = true
        case .some(.denied):
            onOpenSettings()
        case .some(.always):
            break
        }
    }

    private func continueAuthorizationAfterDisclosure() {
        switch permissions?.locationAuthorization {
        case .none, .some(.notDetermined):
            onRequestLocation()
        case .some(.whenInUse):
            onRequestAlways()
        case .some(.denied):
            onOpenSettings()
        case .some(.always):
            break
        }
    }

    private func permissionRow(
        _ title: String,
        granted: Bool,
        actionAvailable: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let status = t(granted ? "autoActivities.allowed" : "autoActivities.notAllowed", lang: languageCode)
        return Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 5) {
                        permissionTitle(title, granted: granted)
                        Text(status)
                            .checkingText(CheckingTypography.labelSmall)
                            .foregroundStyle(granted ? CheckingColors.success : CheckingColors.warning)
                    }
                } else {
                    HStack(spacing: 10) {
                        permissionTitle(title, granted: granted)
                        Spacer()
                        Text(status)
                            .checkingText(CheckingTypography.labelSmall)
                            .foregroundStyle(granted ? CheckingColors.success : CheckingColors.warning)
                        if actionAvailable {
                            Image(systemName: "chevron.right")
                                .foregroundStyle(CheckingColors.textMutedSoft)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(actionAvailable)
        .accessibilityLabel(title)
        .accessibilityValue(status)
    }

    private func permissionTitle(_ title: String, granted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? CheckingColors.success : CheckingColors.warning)
                .accessibilityHidden(true)
            Text(title)
                .checkingText(CheckingTypography.bodyMedium)
                .foregroundStyle(CheckingColors.textStrong)
        }
    }
}

struct ScheduledPauseDialog: View {
    let enabled: Bool
    let from: String
    let to: String
    let suspendSaturdays: Bool
    let suspendSundays: Bool
    let languageCode: String
    let onChanged: (Bool, String, String, Bool, Bool) -> Void
    let onDismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        CheckingDialogScaffold(onDismiss: onDismiss) {
            Text(t("scheduledPause.title", lang: languageCode))
                .checkingText(CheckingTypography.titleLarge)
                .foregroundStyle(CheckingColors.textStrong)
            Text(t("scheduledPause.explanation", lang: languageCode))
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.textMuted)
            TintedPanel {
                settingToggle(t("scheduledPause.enable", lang: languageCode), enabled) {
                    onChanged($0, from, to, suspendSaturdays, suspendSundays)
                }
                .padding(.vertical, 2)
            }
            if enabled {
                Divider().overlay(CheckingColors.divider)
                Text(t("scheduledPause.periodTitle", lang: languageCode))
                    .checkingText(CheckingTypography.titleSmall)
                    .foregroundStyle(CheckingColors.textStrong)
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 10) { timePickers }
                    } else {
                        HStack(alignment: .top, spacing: 10) { timePickers }
                    }
                }
                Text(t("scheduledPause.overnightHint", lang: languageCode))
                    .checkingText(CheckingTypography.labelSmall)
                    .foregroundStyle(CheckingColors.textMuted)
            }
            Divider().overlay(CheckingColors.divider)
            Text(t("scheduledPause.fullDaysTitle", lang: languageCode))
                .checkingText(CheckingTypography.titleSmall)
                .foregroundStyle(CheckingColors.textStrong)
            VStack(spacing: 0) {
                settingToggle(t("scheduledPause.saturday", lang: languageCode), suspendSaturdays) {
                    onChanged(enabled, from, to, $0, suspendSundays)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider().overlay(CheckingColors.divider)
                settingToggle(t("scheduledPause.sunday", lang: languageCode), suspendSundays) {
                    onChanged(enabled, from, to, suspendSaturdays, $0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(CheckingColors.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular)
                    .stroke(CheckingColors.inputBorder, lineWidth: 1))
            closeButton(t("scheduledPause.close", lang: languageCode), onDismiss)
        }
    }

    @ViewBuilder private var timePickers: some View {
        timePicker(t("scheduledPause.start", lang: languageCode), from) {
            onChanged(enabled, Self.hhmm($0), to, suspendSaturdays, suspendSundays)
        }
        timePicker(t("scheduledPause.end", lang: languageCode), to) {
            onChanged(enabled, from, Self.hhmm($0), suspendSaturdays, suspendSundays)
        }
    }

    private func settingToggle(_ title: String, _ value: Bool, action: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .checkingText(CheckingTypography.bodyMedium)
                .foregroundStyle(CheckingColors.textStrong)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: Binding(get: { value }, set: { action($0) }))
                .labelsHidden()
                .tint(CheckingColors.primary)
                .accessibilityLabel(title)
        }
        .contentShape(Rectangle())
    }

    private func timePicker(_ title: String, _ value: String, action: @escaping (Date) -> Void) -> some View {
        VStack(alignment: .center, spacing: 8) {
            Text(title)
                .checkingText(CheckingTypography.labelMedium)
                .foregroundStyle(CheckingColors.textMuted)
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .foregroundStyle(CheckingColors.primary)
                DatePicker(
                    "",
                    selection: Binding(get: { Self.date(value) }, set: { action($0) }),
                    displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .environment(\.locale, HistoryCardPresentation.locale(for: languageCode))
                    .accessibilityLabel(title)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(CheckingColors.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.controlRadius, style: .circular)
                .stroke(CheckingColors.inputBorder, lineWidth: 1))
    }

    private static func date(_ value: String) -> Date {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(hour: parts.first ?? 20, minute: parts.dropFirst().first ?? 0)) ?? Date()
    }

    private static func hhmm(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

struct NotificationsDialog: View {
    let activities: Bool
    let scheduledPause: Bool
    let accident: Bool
    let languageCode: String
    let onChanged: (Bool, Bool, Bool) -> Void
    let onDismiss: () -> Void

    var body: some View {
        CheckingDialogScaffold(onDismiss: onDismiss) {
            Text(t("notifications.title", lang: languageCode))
                .checkingText(CheckingTypography.titleLarge)
                .foregroundStyle(CheckingColors.textStrong)
            Divider().overlay(CheckingColors.divider)
            Text(t("notifications.intro", lang: languageCode))
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.textMuted)
            notificationToggle(t("notifications.checkboxActivities", lang: languageCode), activities) {
                onChanged($0, scheduledPause, accident)
            }
            notificationToggle(t("notifications.checkboxScheduledPause", lang: languageCode), scheduledPause) {
                onChanged(activities, $0, accident)
            }
            notificationToggle(t("notifications.checkboxAccident", lang: languageCode), accident) {
                onChanged(activities, scheduledPause, $0)
            }
            closeButton(t("notifications.backButton", lang: languageCode), onDismiss)
        }
    }

    private func notificationToggle(_ title: String, _ value: Bool, action: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .checkingText(CheckingTypography.bodyMedium)
                .foregroundStyle(CheckingColors.textStrong)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: Binding(get: { value }, set: { action($0) }))
                .labelsHidden()
                .tint(CheckingColors.primary)
                .accessibilityLabel(title)
        }
        .contentShape(Rectangle())
    }
}

struct CheckHistoryDialog: View {
    let state: CheckHistoryDialogState
    let languageCode: String
    let onRetry: () -> Void
    let onDismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Button(action: onDismiss) {
                    Color.black.opacity(0.5).ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Tokens.sectionGap) {
                    Button(action: onDismiss) {
                        Label(t("history.back", lang: languageCode), systemImage: "chevron.left")
                            .checkingText(CheckingTypography.bodyMedium)
                            .foregroundStyle(CheckingColors.primary)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: Tokens.controlHeight)
                    .accessibilityIdentifier("history.back")

                    Text(t(state.action == .checkIn ? "history.dialogTitleCheckin" : "history.dialogTitleCheckout", lang: languageCode))
                        .checkingText(CheckingTypography.titleLarge)
                        .foregroundStyle(CheckingColors.textStrong)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilitySortPriority(2)
                    Divider().overlay(CheckingColors.divider)
                    historyContent
                        .frame(maxHeight: .infinity)
                }
                .padding(Tokens.cardPadding)
                .frame(maxWidth: Tokens.cardMaxWidth, maxHeight: max(240, proxy.size.height - 64), alignment: .topLeading)
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

    @ViewBuilder private var historyContent: some View {
        if state.isLoading {
            ProgressView(t("history.loadingMessage", lang: languageCode)).tint(CheckingColors.primary)
        } else if state.isError {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("history.loadError", lang: languageCode))
                    .checkingText(CheckingTypography.bodyMedium).foregroundStyle(CheckingColors.textMuted)
                Button(t("history.retry", lang: languageCode), action: onRetry)
                    .buttonStyle(.plain).foregroundStyle(CheckingColors.primary)
            }
        } else if state.entries.isEmpty {
            Text(t("history.empty", lang: languageCode))
                .checkingText(CheckingTypography.bodyMedium).foregroundStyle(CheckingColors.textMuted)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if !dynamicTypeSize.isAccessibilitySize {
                    historyRow(
                        date: t("history.colDate", lang: languageCode),
                        time: t("history.colTime", lang: languageCode),
                        action: t("history.colActivity", lang: languageCode),
                        local: t("history.colLocal", lang: languageCode),
                        header: true)
                    Divider().overlay(CheckingColors.divider)
                }
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(state.entries.enumerated()), id: \.offset) { _, entry in
                            historyRow(
                                date: format(entry.time, "dd/MM/yy"),
                                time: format(entry.time, "HH:mm"),
                                action: t(entry.action == .checkIn ? "history.activityCheckin" : "history.activityCheckout", lang: languageCode),
                                local: entry.local ?? "-")
                            Divider().overlay(CheckingColors.divider.opacity(0.6))
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func historyRow(date: String, time: String, action: String, local: String, header: Bool = false) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize && !header {
                VStack(alignment: .leading, spacing: 5) {
                    labeledHistoryValue("history.colDate", date)
                    labeledHistoryValue("history.colTime", time)
                    labeledHistoryValue("history.colActivity", action)
                    labeledHistoryValue("history.colLocal", local)
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    historyCell(date, width: 58, header: header)
                    historyCell(time, width: 38, header: header)
                    historyCell(action, width: 58, header: header)
                    historyCell(local, header: header)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(header ? "\(date), \(time), \(action), \(local)" : [
            "\(t("history.colDate", lang: languageCode)): \(date)",
            "\(t("history.colTime", lang: languageCode)): \(time)",
            "\(t("history.colActivity", lang: languageCode)): \(action)",
            "\(t("history.colLocal", lang: languageCode)): \(local)",
        ].joined(separator: ", "))
    }

    private func labeledHistoryValue(_ labelKey: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t(labelKey, lang: languageCode))
                .checkingText(CheckingTypography.labelSmall)
                .foregroundStyle(CheckingColors.textMuted)
            Text(value)
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.textStrong)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func historyCell(_ text: String, width: CGFloat? = nil, header: Bool = false) -> some View {
        let cell = Text(text)
            .font(.system(.caption2, design: .default, weight: header ? .semibold : .regular))
            .lineSpacing(2)
            .foregroundStyle(header ? CheckingColors.textMuted : CheckingColors.textStrong)
            .fixedSize(horizontal: false, vertical: true)

        return Group {
            if let width {
                cell.frame(width: width, alignment: .topLeading)
            } else {
                cell.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func format(_ date: Date?, _ pattern: String) -> String {
        guard let date else { return "-" }
        let formatter = DateFormatter()
        formatter.locale = HistoryCardPresentation.locale(for: languageCode)
        formatter.timeZone = HistoryCardPresentation.singapore
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

@MainActor private func closeButton(_ title: String, _ action: @escaping () -> Void) -> some View {
    Button(title, action: action)
        .buttonStyle(.plain)
        .foregroundStyle(CheckingColors.primary)
        .frame(maxWidth: .infinity, minHeight: Tokens.controlHeight)
}
