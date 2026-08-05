import Foundation

enum LocationSampleValidity: Sendable, Equatable {
    case usable
    case freshButTooInaccurate
    case stale
    case invalid
    case fromFuture
}

/// Política pura de integridade, frescor e preferência de seeds.
///
/// `now` é sempre fornecido pelo chamador para manter a decisão determinística. A amostra escolhida por
/// `preferredSeed` ainda deve ser revalidada imediatamente antes do matcher quando a política for integrada
/// ao pipeline em uma fase posterior.
struct LocationSamplePolicy: Sendable, Equatable {
    /// Ponto de partida aprovado para o ensaio. Só é aplicado pelo perfil candidato; os configs
    /// distribuíveis atuais continuam selecionando o legado.
    static let candidateTrial = LocationSamplePolicy(
        maximumAge: 10,
        futureTolerance: 2
    )

    let maximumAge: TimeInterval
    let futureTolerance: TimeInterval

    func validity(
        of sample: LocationSample,
        now: Date,
        requiredAccuracyMeters: Int
    ) -> LocationSampleValidity {
        let nowValue = now.timeIntervalSinceReferenceDate
        let capturedAtValue = sample.capturedAt.timeIntervalSinceReferenceDate

        guard maximumAge.isFinite,
              maximumAge >= 0,
              futureTolerance.isFinite,
              futureTolerance >= 0,
              requiredAccuracyMeters >= 0,
              nowValue.isFinite,
              capturedAtValue.isFinite,
              sample.latitude.isFinite,
              (-90.0 ... 90.0).contains(sample.latitude),
              sample.longitude.isFinite,
              (-180.0 ... 180.0).contains(sample.longitude),
              sample.horizontalAccuracyMeters.isFinite,
              sample.horizontalAccuracyMeters >= 0
        else {
            return .invalid
        }

        let age = nowValue - capturedAtValue
        guard age.isFinite else { return .invalid }
        if age < -futureTolerance { return .fromFuture }
        if age > maximumAge { return .stale }
        if sample.horizontalAccuracyMeters <= Double(requiredAccuracyMeters) {
            return .usable
        }
        return .freshButTooInaccurate
    }

    /// Seleção total e estável para duas seeds:
    /// 1. descarta inválida, stale ou futura;
    /// 2. suficiente para o threshold vence coarse;
    /// 3. menor erro horizontal vence;
    /// 4. timestamp mais novo desempata;
    /// 5. empate completo preserva `current`.
    ///
    /// Coordenadas e origem nunca são critérios de preferência.
    func preferredSeed(
        current: LocationSample?,
        candidate: LocationSample?,
        now: Date,
        requiredAccuracyMeters: Int
    ) -> LocationSample? {
        let currentQuality = current.flatMap {
            seedQuality(of: $0, now: now, requiredAccuracyMeters: requiredAccuracyMeters)
        }
        let candidateQuality = candidate.flatMap {
            seedQuality(of: $0, now: now, requiredAccuracyMeters: requiredAccuracyMeters)
        }

        switch (current, currentQuality, candidate, candidateQuality) {
        case (_, nil, _, nil):
            return nil
        case (let current?, .some, _, nil):
            return current
        case (_, nil, let candidate?, .some):
            return candidate
        case (let current?, let currentQuality?, let candidate?, let candidateQuality?):
            if currentQuality != candidateQuality {
                return currentQuality.rawValue < candidateQuality.rawValue ? current : candidate
            }
            if current.horizontalAccuracyMeters != candidate.horizontalAccuracyMeters {
                return current.horizontalAccuracyMeters < candidate.horizontalAccuracyMeters
                    ? current
                    : candidate
            }
            if current.capturedAt != candidate.capturedAt {
                return current.capturedAt > candidate.capturedAt ? current : candidate
            }
            return current
        default:
            return nil
        }
    }

    private enum SeedQuality: Int {
        case usable = 0
        case coarse = 1
    }

    private func seedQuality(
        of sample: LocationSample,
        now: Date,
        requiredAccuracyMeters: Int
    ) -> SeedQuality? {
        switch validity(
            of: sample,
            now: now,
            requiredAccuracyMeters: requiredAccuracyMeters
        ) {
        case .usable:
            .usable
        case .freshButTooInaccurate:
            .coarse
        case .stale, .invalid, .fromFuture:
            nil
        }
    }
}
