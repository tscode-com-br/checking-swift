import Foundation

/// Captura de GPS — port de platform/location/LocationProvider.kt (só o contrato; a implementação
/// CLLocationManager com "15s melhor-fix" é `CLLocationManagerLocationProvider`, na camada Platform).
/// Ver port_spec_background_orchestrator §8.
enum LocationCapture: Sendable, Equatable {
    case success(lat: Double, lon: Double, accuracyMeters: Double)
    case timeout
    case unavailable
}

protocol LocationProvider: Sendable {
    func capture(_ accuracyThresholdMeters: Int) async -> LocationCapture
}

/// Sempre `.unavailable` — usado em previews/testes (nenhuma chamada real ao CoreLocation). Degrada
/// honestamente (nunca promete o que a plataforma não garante, §9) em vez de fingir GPS disponível.
struct UnavailableLocationProvider: LocationProvider {
    func capture(_ accuracyThresholdMeters: Int) async -> LocationCapture { .unavailable }
}
