#if DEBUG || PHYSICAL_VALIDATION
import SwiftUI

/// Superfície local de leitura do estado técnico por geração. A configuração `PhysicalValidation` usa
/// exclusivamente esta tela: ela não inicia monitores, captura, avaliação, recorder, exportação ou share.
@MainActor
struct PhysicalValidationSnapshotScreen: View {
    let environment: AppEnvironment

    @State private var presentation = PhysicalValidationGeofenceSnapshotPresentation(snapshot: nil)

    var body: some View {
        CheckScreenShell(
            accidentActive: false,
            banner: { EmptyView() },
            cardBody: {
                VStack(alignment: .leading, spacing: Tokens.sectionGapLarge) {
                    Text("Validação física — geofences")
                        .checkingText(CheckingTypography.titleMedium)
                        .foregroundStyle(CheckingColors.textStrong)
                    Text("Snapshot técnico local. Não confirma presença nem inicia automação.")
                        .checkingText(CheckingTypography.bodySmall)
                        .foregroundStyle(CheckingColors.textMutedLight)

                    Divider()

                    snapshotSection

                    Button("Atualizar snapshot") {
                        Task { await refreshSnapshot() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("physical-validation-refresh-geofences")
                }
            }
        )
        .task { await refreshSnapshot() }
    }

    private var snapshotSection: some View {
        VStack(alignment: .leading, spacing: Tokens.itemGap) {
            Text("Monitoramento de regiões")
                .checkingText(CheckingTypography.titleSmall)
                .foregroundStyle(CheckingColors.textStrong)

            Text("Geração: \(presentation.generationOrdinalText)")
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.textStrong)
            Text("Estado: \(presentation.confirmationStateText)")
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(CheckingColors.textStrong)
            Text("confirmationUncertain: \(presentation.confirmationUncertain ? "true" : "false")")
                .checkingText(CheckingTypography.bodySmall)
                .foregroundStyle(presentation.confirmationUncertain ? CheckingColors.warning : CheckingColors.textMuted)

            ForEach(presentation.counts) { count in
                Text("\(count.name): \(count.value)")
                    .checkingText(CheckingTypography.bodySmall)
                    .foregroundStyle(CheckingColors.textStrong)
            }

            if presentation.failureCodes.isEmpty {
                Text("Códigos de falha: nenhum")
                    .checkingText(CheckingTypography.bodySmall)
                    .foregroundStyle(CheckingColors.textMuted)
            } else {
                Text("Códigos de falha: \(presentation.failureCodes.joined(separator: ", "))")
                    .checkingText(CheckingTypography.bodySmall)
                    .foregroundStyle(CheckingColors.textMuted)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("physical-validation-geofence-snapshot")
    }

    private func refreshSnapshot() async {
        let snapshot = await environment.geofenceRegionManager.monitoringSnapshot()
        presentation = PhysicalValidationGeofenceSnapshotPresentation(snapshot: snapshot)
    }
}

/// Adaptador puro de apresentação. Seu input já é o snapshot privado e tipado; não aceita nem transporta
/// IDs físicos/lógicos, tokens, local, coordenadas ou erros crus para a tela.
struct PhysicalValidationGeofenceSnapshotPresentation: Equatable {
    struct Count: Identifiable, Equatable {
        let name: String
        let value: Int

        var id: String { name }
    }

    let generationOrdinalText: String
    let confirmationStateText: String
    let confirmationUncertain: Bool
    let counts: [Count]
    let failureCodes: [String]

    init(snapshot: GeofenceMonitoringSnapshot?) {
        guard let snapshot else {
            generationOrdinalText = "indisponível"
            confirmationStateText = "notRequested"
            confirmationUncertain = false
            counts = Self.zeroCounts
            failureCodes = []
            return
        }

        generationOrdinalText = String(snapshot.syncGeneration)
        confirmationStateText = Self.confirmationStateText(snapshot.confirmationState)
        confirmationUncertain = snapshot.confirmationState == .confirmationUncertain
        counts = [
            Count(name: "requested", value: snapshot.requestedCount),
            Count(name: "confirmed", value: snapshot.confirmedCount),
            Count(name: "failed", value: snapshot.failedCount),
            Count(name: "omitted", value: snapshot.omittedCount),
            Count(name: "pending", value: snapshot.pendingCount),
            Count(name: "inheritedUnknown", value: snapshot.inheritedUnknownCount),
        ]
        failureCodes = GeofenceMonitoringFailureCode.allCases.compactMap { code in
            guard let count = snapshot.failedCodes[code], count > 0 else { return nil }
            return "\(Self.failureCodeText(code)): \(count)"
        }
    }

    private static let zeroCounts = [
        Count(name: "requested", value: 0),
        Count(name: "confirmed", value: 0),
        Count(name: "failed", value: 0),
        Count(name: "omitted", value: 0),
        Count(name: "pending", value: 0),
        Count(name: "inheritedUnknown", value: 0),
    ]

    private static func confirmationStateText(_ state: GeofenceMonitoringConfirmationState) -> String {
        switch state {
        case .notRequested: "notRequested"
        case .requested: "requested"
        case .partiallyConfirmed: "partiallyConfirmed"
        case .confirmed: "confirmed"
        case .failed: "failed"
        case .confirmationUncertain: "confirmationUncertain"
        }
    }

    private static func failureCodeText(_ code: GeofenceMonitoringFailureCode) -> String {
        switch code {
        case .denied: "denied"
        case .regionMonitoringDenied: "regionMonitoringDenied"
        case .regionMonitoringFailure: "regionMonitoringFailure"
        case .other: "other"
        }
    }
}
#endif
