import SwiftUI
import UIKit

struct NotificationCard: View {
    let primary: String
    let secondary: String
    let tone: NotificationTone

    private var primaryColor: Color {
        switch tone {
        case .error: CheckingColors.errorVivid
        case .success: CheckingColors.success
        case .teal, .info: CheckingColors.teal
        case .none: CheckingColors.textStrong
        }
    }

    var body: some View {
        if !primary.isEmpty || !secondary.isEmpty {
            TintedPanel {
                Text(primary)
                    .checkingText(CheckingTypography.labelLarge)
                    .foregroundStyle(primaryColor)
                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                Spacer().frame(height: 2)
                Text(secondary)
                    .checkingText(CheckingTypography.bodySmall)
                    .foregroundStyle(CheckingColors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .onAppear { announce() }
            .onChange(of: announcement) { _, _ in announce() }
        }
    }

    private var announcement: String {
        [primary, secondary].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private func announce() {
        guard UIAccessibility.isVoiceOverRunning, !announcement.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }
}
