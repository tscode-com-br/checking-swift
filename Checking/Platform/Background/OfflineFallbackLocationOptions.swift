import Foundation

/// Gate de precisão default usado só offline sem cache (espelha o `?: 30` da UI). Port_spec_background §5.
let DEFAULT_ACCURACY_THRESHOLD_METERS = 30

/// Fallback offline de opções — port de `offlineFallbackLocationOptions`. Só `ApiError.network` dá resultado
/// usável (cache ou default 30/0, para seguir capturando offline); qualquer outro erro → nil (a run aborta).
func offlineFallbackLocationOptions(_ cached: LocationOptions?, _ error: ApiError) -> LocationOptions? {
    guard case .network = error else { return nil }
    return cached ?? LocationOptions(items: [], accuracyThresholdMeters: DEFAULT_ACCURACY_THRESHOLD_METERS, mixedZoneIntervalMinutes: 0)
}
