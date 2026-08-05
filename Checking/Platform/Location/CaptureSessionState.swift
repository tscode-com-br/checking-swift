import Foundation

/// Máquina de estado pura da captura. Não conhece Core Location, timers, continuations ou logging.
struct CaptureSessionState: Sendable {
    enum Transition: Sendable, Equatable {
        case start
        case keepWaiting
        case finish(LocationCapture)
        case ignoredAfterFinish
    }

    let behavior: LocationCaptureBehavior
    let accuracyThresholdMeters: Int
    let captureStartedAt: Date
    let samplePolicy: LocationSamplePolicy

    private(set) var best: LocationSample?
    private(set) var isFinished = false

    init(
        behavior: LocationCaptureBehavior,
        accuracyThresholdMeters: Int,
        captureStartedAt: Date,
        samplePolicy: LocationSamplePolicy
    ) {
        self.behavior = behavior
        self.accuracyThresholdMeters = accuracyThresholdMeters
        self.captureStartedAt = captureStartedAt
        self.samplePolicy = samplePolicy
    }

    mutating func admit(seed: LocationSample?, now: Date) -> Transition {
        guard !isFinished else { return .ignoredAfterFinish }
        guard behavior == .freshnessValidated, let seed else { return .start }

        switch samplePolicy.validity(
            of: seed,
            now: now,
            requiredAccuracyMeters: accuracyThresholdMeters
        ) {
        case .usable:
            return finish(.success(seed))
        case .freshButTooInaccurate:
            best = seed
            return .start
        case .stale, .invalid, .fromFuture:
            return .start
        }
    }

    mutating func receive(_ samples: [LocationSample], now: Date) -> Transition {
        guard !isFinished else { return .ignoredAfterFinish }

        switch behavior {
        case .legacyCompatible:
            // Compatibilidade deliberada: o pipeline legado continua considerando somente o último
            // callback e não aplica frescor. O candidato abaixo é o único caminho corrigido.
            if let candidate = samples.last, isBetterLegacy(candidate, than: best) {
                best = candidate
            }
            guard let best,
                  best.horizontalAccuracyMeters.isFinite,
                  best.horizontalAccuracyMeters >= 0,
                  best.horizontalAccuracyMeters <= Double(accuracyThresholdMeters) else {
                return .keepWaiting
            }
            return finish(.success(best))

        case .freshnessValidated:
            if let best {
                switch samplePolicy.validity(
                    of: best,
                    now: now,
                    requiredAccuracyMeters: accuracyThresholdMeters
                ) {
                case .usable, .freshButTooInaccurate:
                    break
                case .stale, .invalid, .fromFuture:
                    self.best = nil
                }
            }

            for candidate in samples where isEligibleCandidate(candidate, now: now) {
                if isBetterCandidate(candidate, than: best) {
                    best = candidate
                }
            }

            guard let best,
                  samplePolicy.validity(
                    of: best,
                    now: now,
                    requiredAccuracyMeters: accuracyThresholdMeters
                  ) == .usable else {
                return .keepWaiting
            }
            return finish(.success(best))
        }
    }

    mutating func timeout(now: Date) -> Transition {
        guard !isFinished else { return .ignoredAfterFinish }

        if let best {
            switch behavior {
            case .legacyCompatible:
                return finish(.success(best))
            case .freshnessValidated:
                switch samplePolicy.validity(
                    of: best,
                    now: now,
                    requiredAccuracyMeters: accuracyThresholdMeters
                ) {
                case .usable, .freshButTooInaccurate:
                    return finish(.success(best))
                case .stale, .invalid, .fromFuture:
                    break
                }
            }
        }
        return finish(.failure(.timeout))
    }

    mutating func cancel(_ reason: EvaluationCancellationReason) -> Transition {
        guard !isFinished else { return .ignoredAfterFinish }
        // O best parcial não cruza esta fronteira: cancelamento nunca é sucesso consumível.
        return finish(.failure(.cancelled(reason)))
    }

    mutating func fail(_ failure: LocationAcquisitionFailure) -> Transition {
        guard !isFinished else { return .ignoredAfterFinish }
        return finish(.failure(failure))
    }

    mutating func locationUnknown() -> Transition {
        guard !isFinished else { return .ignoredAfterFinish }
        return .keepWaiting
    }

    private func isEligibleCandidate(_ sample: LocationSample, now: Date) -> Bool {
        let earliestAcceptedAt = captureStartedAt.addingTimeInterval(-samplePolicy.futureTolerance)
        guard sample.capturedAt >= earliestAcceptedAt else { return false }

        switch samplePolicy.validity(
            of: sample,
            now: now,
            requiredAccuracyMeters: accuracyThresholdMeters
        ) {
        case .usable, .freshButTooInaccurate:
            return true
        case .stale, .invalid, .fromFuture:
            return false
        }
    }

    private func isBetterCandidate(_ candidate: LocationSample, than current: LocationSample?) -> Bool {
        guard let current else { return true }
        if candidate.horizontalAccuracyMeters < current.horizontalAccuracyMeters { return true }
        if candidate.horizontalAccuracyMeters > current.horizontalAccuracyMeters { return false }
        return candidate.capturedAt > current.capturedAt
    }

    private func isBetterLegacy(_ candidate: LocationSample, than current: LocationSample?) -> Bool {
        guard let current else { return true }
        let candidateAccuracy = candidate.horizontalAccuracyMeters
        let currentAccuracy = current.horizontalAccuracyMeters
        guard candidateAccuracy.isFinite, candidateAccuracy >= 0 else { return false }
        guard currentAccuracy.isFinite, currentAccuracy >= 0 else { return true }
        if candidateAccuracy < currentAccuracy { return true }
        if candidateAccuracy > currentAccuracy { return false }
        return candidate.capturedAt > current.capturedAt
    }

    private mutating func finish(_ capture: LocationCapture) -> Transition {
        isFinished = true
        return .finish(capture)
    }
}
