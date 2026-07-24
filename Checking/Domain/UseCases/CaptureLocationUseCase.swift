import Foundation

/// Resultado da captura — port de LocationCaptureResult (CaptureLocationUseCase.kt).
enum LocationCaptureResult: Sendable, Equatable {
    case matched(LocationMatch)
    case noPermission
    case timeout
    /// `reading` != nil só quando ApiError.network E houve fix GPS; erros HTTP carregam nil.
    case networkError(reading: LocationReading?)
}

struct LocationReading: Sendable, Equatable {
    var lat: Double
    var lon: Double
    var accuracyMeters: Double?
}

/// Contrato do caso de uso de captura (permite mock nos testes do motor).
protocol LocationCapturing: Sendable {
    func callAsFunction(_ accuracyThresholdMeters: Int) async -> LocationCaptureResult
}

/// Compartilha uma captura que já esteja em andamento para o mesmo limite de precisão. No retorno ao
/// foreground, UI e orquestrador podem pedir a posição quase simultaneamente; sem esta camada o aparelho
/// liga o GPS duas vezes e grava duas linhas LOCATION idênticas.
actor CoalescingLocationCapture: LocationCapturing {
    private struct InFlight {
        let id: UUID
        let task: Task<LocationCaptureResult, Never>
    }

    private let base: any LocationCapturing
    private var inFlightByAccuracy: [Int: InFlight] = [:]

    init(base: any LocationCapturing) {
        self.base = base
    }

    func callAsFunction(_ accuracyThresholdMeters: Int) async -> LocationCaptureResult {
        if let existing = inFlightByAccuracy[accuracyThresholdMeters] {
            return await existing.task.value
        }

        let id = UUID()
        let base = self.base
        let task = Task { await base(accuracyThresholdMeters) }
        inFlightByAccuracy[accuracyThresholdMeters] = InFlight(id: id, task: task)
        let result = await task.value
        if inFlightByAccuracy[accuracyThresholdMeters]?.id == id {
            inFlightByAccuracy[accuracyThresholdMeters] = nil
        }
        return result
    }
}

/// Captura GPS → match no servidor → log. Único chokepoint (manual + automático), então a linha de
/// LOCATION nunca é duplicada. Port de CaptureLocationUseCase.kt.
struct CaptureLocationUseCase: LocationCapturing {
    let locationProvider: any LocationProvider
    let checkRepository: any CheckRepository
    let activityLogger: any ActivityLogging

    func callAsFunction(_ accuracyThresholdMeters: Int) async -> LocationCaptureResult {
        switch await locationProvider.capture(accuracyThresholdMeters) {
        case .success(let lat, let lon, let acc):
            switch await checkRepository.matchLocation(lat, lon, acc) {
            case .success(let match):
                if match.status == .accuracyTooLow {
                    activityLogger.logLocation("Location accuracy too low (±\(Int(acc))m).", nil, .warning)
                } else {
                    let loc = nonBlank(match.resolvedLocal) ?? "unknown"
                    activityLogger.logLocation("Location fixed (±\(Int(acc))m) → \(loc).", match.resolvedLocal, .info)
                }
                return .matched(match)
            case .failure(let error):
                if case .network = error {
                    return .networkError(reading: LocationReading(lat: lat, lon: lon, accuracyMeters: acc))
                }
                return .networkError(reading: nil)
            }
        case .timeout:
            return .timeout
        case .unavailable:
            return .noPermission
        }
    }

    private func nonBlank(_ value: String?) -> String? {
        guard let value = value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
