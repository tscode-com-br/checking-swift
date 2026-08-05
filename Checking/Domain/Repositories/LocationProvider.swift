import Foundation

/// Captura de GPS — port de platform/location/LocationProvider.kt (só o contrato; a implementação
/// CLLocationManager com "15s melhor-fix" é `CLLocationManagerLocationProvider`, na camada Platform).
/// Ver port_spec_background_orchestrator §8.
enum LocationCapture: Sendable, Equatable {
    case success(LocationSample)
    case failure(LocationAcquisitionFailure)

    /// Conveniências temporárias para fixtures e adapters ainda não migrados para falhas tipadas.
    static var timeout: LocationCapture { .failure(.timeout) }
    static var unavailable: LocationCapture { .failure(.unavailable) }
}

/// Seleciona um único comportamento operacional por build. Os dois caminhos usam o mesmo contrato
/// tipado; somente o candidato reutiliza seed e aplica a política de frescor.
enum LocationCaptureBehavior: Sendable, Equatable {
    case legacyCompatible
    case freshnessValidated
}

protocol LocationProvider: Sendable {
    func capture(
        _ accuracyThresholdMeters: Int,
        seed: LocationSample?
    ) async -> LocationCapture
}

extension LocationProvider {
    func capture(_ accuracyThresholdMeters: Int) async -> LocationCapture {
        await capture(accuracyThresholdMeters, seed: nil)
    }
}

/// Sempre `.unavailable` — usado em previews/testes (nenhuma chamada real ao CoreLocation). Degrada
/// honestamente (nunca promete o que a plataforma não garante, §9) em vez de fingir GPS disponível.
struct UnavailableLocationProvider: LocationProvider {
    func capture(
        _ accuracyThresholdMeters: Int,
        seed: LocationSample?
    ) async -> LocationCapture {
        .failure(.unavailable)
    }
}
