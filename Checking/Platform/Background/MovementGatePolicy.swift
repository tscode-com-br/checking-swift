import Foundation

/// Regra pura do filtro de movimento aplicado exclusivamente ao `TIMER`.
///
/// A distância geográfica é calculada na fronteira Platform; esta política recebe somente metros para
/// manter as comparações de fronteira determinísticas e testáveis.
struct MovementGatePolicy: Sendable, Equatable {
    static let production = MovementGatePolicy(minimumDistanceMeters: 50)

    let minimumDistanceMeters: Double

    func thresholdMeters(horizontalAccuracyMeters: Double) -> Double? {
        guard minimumDistanceMeters.isFinite,
              minimumDistanceMeters >= 0,
              horizontalAccuracyMeters.isFinite,
              horizontalAccuracyMeters >= 0
        else {
            return nil
        }
        return max(minimumDistanceMeters, 2 * horizontalAccuracyMeters)
    }

    func shouldSkip(
        distanceMeters: Double,
        horizontalAccuracyMeters: Double
    ) -> Bool {
        guard distanceMeters.isFinite,
              distanceMeters >= 0,
              let threshold = thresholdMeters(
                  horizontalAccuracyMeters: horizontalAccuracyMeters
              )
        else {
            return false
        }
        // Igual ao limiar significa movimento suficiente e, portanto, deve prosseguir.
        return distanceMeters < threshold
    }
}
