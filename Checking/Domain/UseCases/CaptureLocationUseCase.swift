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

/// Orçamento explícito de aquisição para uma avaliação automática.
///
/// `seedCandidate` pode iniciar ou melhorar uma única aquisição. `finalSample` afirma que a aquisição
/// física desta avaliação já ocorreu e, portanto, nunca pode chamar o provider novamente.
enum LocationAttemptInput: Sendable, Equatable {
    case acquire
    case seedCandidate(LocationSample)
    case finalSample(LocationSample)
}

/// Resultado interno da etapa de aquisição. A fachada legada continua projetando esses casos para
/// `LocationCaptureResult`, enquanto o envelope operacional preserva a causa tipada em memória.
enum LocationAcquisitionResult: Sendable, Equatable {
    case sample(LocationSample, reused: Bool)
    case rejected(LocationSampleValidity)
    case failure(LocationAcquisitionFailure)
}

/// Resultado interno da etapa de resolução/match, preservando a falha tipada sem mudar a fachada legada.
enum LocationResolutionResult: Sendable, Equatable {
    case matched(LocationMatch)
    case matchFailure(error: ApiError, reading: LocationReading?)
    case rejected(LocationSampleValidity)
    case cancelled(EvaluationCancellationReason)
}

/// Contrato do caso de uso de captura (permite mock nos testes do motor).
protocol LocationCapturing: Sendable {
    func callAsFunction(_ accuracyThresholdMeters: Int) async -> LocationCaptureResult
}

/// Extensão sample-aware usada pelo motor automático. A UI/manual continuam dependendo somente da
/// fachada `LocationCapturing`.
protocol SampleAwareLocationCapturing: LocationCapturing {
    func execute(
        _ accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput
    ) async -> LocationCaptureExecution

    func execute(
        _ accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> LocationCaptureExecution
}

extension SampleAwareLocationCapturing {
    /// Compatibilidade para fakes/adapters que ainda não participam do pipeline protegido. Produção
    /// implementa este overload explicitamente, de modo que o fence seja despachado pelo existential.
    func execute(
        _ accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> LocationCaptureExecution {
        await execute(
            accuracyThresholdMeters,
            locationAttempt: locationAttempt
        )
    }

    func callAsFunction(
        _ accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput
    ) async -> LocationCaptureResult {
        await execute(
            accuracyThresholdMeters,
            locationAttempt: locationAttempt
        ).result
    }
}

/// Compartilha uma captura estritamente sem seed que já esteja em andamento para o mesmo limite de
/// precisão. Cada consumidor possui sua própria continuation: cancelar um não cancela os demais; o task
/// base só é cancelado quando o último consumidor sai.
///
/// A identidade é somente o threshold para `.acquire`. Seeds e amostras finais bypassam o broker: duas
/// avaliações com amostras diferentes nunca compartilham um resultado por engano.
actor CoalescingLocationCapture: SampleAwareLocationCapturing {
    private struct Waiter {
        let joinedExistingCapture: Bool
        let continuation: CheckedContinuation<LocationCaptureExecution, Never>
    }

    private struct InFlight {
        let id: UUID
        let task: Task<LocationCaptureExecution, Never>
        var waiters: [UUID: Waiter]
    }

    private let base: any SampleAwareLocationCapturing
    private var inFlightByAccuracy: [Int: InFlight] = [:]

    init(base: any SampleAwareLocationCapturing) {
        self.base = base
    }

    func callAsFunction(_ accuracyThresholdMeters: Int) async -> LocationCaptureResult {
        await execute(
            accuracyThresholdMeters,
            locationAttempt: .acquire
        ).result
    }

    func execute(
        _ accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput
    ) async -> LocationCaptureExecution {
        switch locationAttempt {
        case .acquire:
            return await executeAcquire(accuracyThresholdMeters)
        case .seedCandidate, .finalSample:
            let execution = await base.execute(
                accuracyThresholdMeters,
                locationAttempt: locationAttempt
            )
            return Task.isCancelled ? .cancelled() : execution
        }
    }

    /// Uma captura coalescida inclui o match e, portanto, não pode compartilhar o token efêmero de uma
    /// avaliação com outra. Chamadas protegidas bypassam somente o broker; a serialização do orquestrador
    /// continua limitando o motor automático a uma avaliação por vez. A fachada manual mantém o broker.
    func execute(
        _ accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> LocationCaptureExecution {
        let execution = await base.execute(
            accuracyThresholdMeters,
            locationAttempt: locationAttempt,
            effectGuard: effectGuard
        )
        return Task.isCancelled ? .cancelled() : execution
    }

    private func executeAcquire(
        _ accuracyThresholdMeters: Int
    ) async -> LocationCaptureExecution {
        let waiterID = UUID()
        let execution: LocationCaptureExecution = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled())
                    return
                }
                register(
                    waiterID: waiterID,
                    accuracyThresholdMeters: accuracyThresholdMeters,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    waiterID,
                    accuracyThresholdMeters: accuracyThresholdMeters
                )
            }
        }

        // Fecha a corrida em que completion vence no actor logo depois de o consumidor ser cancelado.
        return Task.isCancelled ? .cancelled() : execution
    }

    private func register(
        waiterID: UUID,
        accuracyThresholdMeters: Int,
        continuation: CheckedContinuation<LocationCaptureExecution, Never>
    ) {
        if var existing = inFlightByAccuracy[accuracyThresholdMeters] {
            existing.waiters[waiterID] = Waiter(
                joinedExistingCapture: true,
                continuation: continuation
            )
            inFlightByAccuracy[accuracyThresholdMeters] = existing
            return
        }

        let inFlightID = UUID()
        let base = self.base
        let task = Task {
            await base.execute(
                accuracyThresholdMeters,
                locationAttempt: .acquire
            )
        }
        inFlightByAccuracy[accuracyThresholdMeters] = InFlight(
            id: inFlightID,
            task: task,
            waiters: [
                waiterID: Waiter(
                    joinedExistingCapture: false,
                    continuation: continuation
                ),
            ]
        )

        Task { [weak self] in
            let result = await task.value
            await self?.complete(
                result,
                accuracyThresholdMeters: accuracyThresholdMeters,
                inFlightID: inFlightID
            )
        }
    }

    private func cancelWaiter(_ waiterID: UUID, accuracyThresholdMeters: Int) {
        guard var inFlight = inFlightByAccuracy[accuracyThresholdMeters],
              let continuation = inFlight.waiters.removeValue(forKey: waiterID) else {
            return
        }

        if inFlight.waiters.isEmpty {
            inFlightByAccuracy[accuracyThresholdMeters] = nil
            inFlight.task.cancel()
        } else {
            inFlightByAccuracy[accuracyThresholdMeters] = inFlight
        }
        continuation.continuation.resume(returning: .cancelled())
    }

    private func complete(
        _ execution: LocationCaptureExecution,
        accuracyThresholdMeters: Int,
        inFlightID: UUID
    ) {
        guard let inFlight = inFlightByAccuracy[accuracyThresholdMeters],
              inFlight.id == inFlightID else {
            return
        }
        inFlightByAccuracy[accuracyThresholdMeters] = nil
        for waiter in inFlight.waiters.values {
            waiter.continuation.resume(
                returning: waiter.joinedExistingCapture
                    ? execution.markingCaptureReused()
                    : execution
            )
        }
    }

    var waiterCountsForTest: [Int: Int] {
        inFlightByAccuracy.mapValues(\.waiters.count)
    }
}

/// Captura GPS → match no servidor → log. Único chokepoint (manual + automático), então a linha de
/// LOCATION nunca é duplicada. Port de CaptureLocationUseCase.kt.
struct CaptureLocationUseCase: SampleAwareLocationCapturing {
    let locationProvider: any LocationProvider
    let checkRepository: any CheckRepository
    let activityLogger: any ActivityLogging
    let clock: any Clock
    let samplePolicy: LocationSamplePolicy
    let captureBehavior: LocationCaptureBehavior

    init(
        locationProvider: any LocationProvider,
        checkRepository: any CheckRepository,
        activityLogger: any ActivityLogging,
        clock: any Clock = SystemClock(),
        samplePolicy: LocationSamplePolicy = .candidateTrial,
        captureBehavior: LocationCaptureBehavior = .legacyCompatible
    ) {
        self.locationProvider = locationProvider
        self.checkRepository = checkRepository
        self.activityLogger = activityLogger
        self.clock = clock
        self.samplePolicy = samplePolicy
        self.captureBehavior = captureBehavior
    }

    /// Fachada histórica de UI/manual. O perfil legado preserva a resolução observável anterior; o
    /// candidato passa pelo mesmo seam sample-aware usado pelas avaliações automáticas.
    func callAsFunction(_ accuracyThresholdMeters: Int) async -> LocationCaptureResult {
        await execute(
            accuracyThresholdMeters,
            locationAttempt: .acquire
        ).result
    }

    func execute(
        _ accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput
    ) async -> LocationCaptureExecution {
        await execute(
            accuracyThresholdMeters,
            locationAttempt: locationAttempt,
            effectGuard: .unrestricted
        )
    }

    func execute(
        _ accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> LocationCaptureExecution {
        guard effectGuard.allowsIrreversibleEffect() else {
            return .cancelled(reason: .contextInvalidated)
        }
        if case .acquire = locationAttempt,
           captureBehavior == .legacyCompatible {
            return await runLegacyCompatible(
                accuracyThresholdMeters,
                effectGuard: effectGuard
            )
        }
        switch await acquireSample(
            accuracyThresholdMeters,
            input: locationAttempt
        ) {
        case .sample(let sample, let reused):
            // O mesmo instante governa a revalidação e os buckets de diagnóstico. Assim uma chamada lenta
            // ao matcher/state não envelhece artificialmente o fix que foi efetivamente enviado.
            let resolvedAt = clock.now()
            let validity = samplePolicy.validity(
                of: sample,
                now: resolvedAt,
                requiredAccuracyMeters: accuracyThresholdMeters
            )
            let resolution: LocationResolutionResult
            if isMatchable(validity) {
                resolution = await resolveAcceptedSample(
                    sample,
                    effectGuard: effectGuard
                )
            } else {
                resolution = .rejected(validity)
            }
            return captureExecution(
                from: resolution,
                sample: sample,
                trace: captureTrace(
                    for: sample,
                    accuracyThresholdMeters: accuracyThresholdMeters,
                    reused: reused,
                    input: locationAttempt,
                    rejected: isMatchable(validity) ? nil : validity,
                    evaluatedAt: resolvedAt
                )
            )
        case .rejected(let validity):
            let trace = rejectedCaptureTrace(
                for: locationAttempt,
                accuracyThresholdMeters: accuracyThresholdMeters,
                validity: validity,
                evaluatedAt: clock.now()
            )
            return LocationCaptureExecution(
                result: .timeout,
                maximumStage: trace == nil ? .captureStarted : .captured,
                capture: trace,
                failure: .sampleRejected(validity)
            )
        case .failure(let failure):
            return LocationCaptureExecution(
                result: legacyResult(from: failure),
                maximumStage: .captureStarted,
                capture: nil,
                failure: .acquisition(failure)
            )
        }
    }

    private func runLegacyCompatible(
        _ accuracyThresholdMeters: Int,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> LocationCaptureExecution {
        let acquisition = await captureFromProvider(
            accuracyThresholdMeters,
            seed: nil
        )
        switch acquisition {
        case .sample(let sample, let reused):
            let resolvedAt = clock.now()
            return captureExecution(
                from: await resolveAcceptedSample(
                    sample,
                    effectGuard: effectGuard
                ),
                sample: sample,
                trace: captureTrace(
                    for: sample,
                    accuracyThresholdMeters: accuracyThresholdMeters,
                    reused: reused,
                    input: .acquire,
                    rejected: nil,
                    evaluatedAt: resolvedAt
                )
            )
        case .rejected(let validity):
            return LocationCaptureExecution(
                result: .timeout,
                maximumStage: .captureStarted,
                capture: nil,
                failure: .sampleRejected(validity)
            )
        case .failure(let failure):
            return LocationCaptureExecution(
                result: legacyResult(from: failure),
                maximumStage: .captureStarted,
                capture: nil,
                failure: .acquisition(failure)
            )
        }
    }

    /// Executa no máximo uma chamada ao provider. `finalSample` nunca chama o provider.
    func acquireSample(
        _ accuracyThresholdMeters: Int,
        input: LocationAttemptInput
    ) async -> LocationAcquisitionResult {
        guard !Task.isCancelled else {
            return .failure(.cancelled(.taskCancelled))
        }

        switch input {
        case .finalSample(let sample):
            let validity = samplePolicy.validity(
                of: sample,
                now: clock.now(),
                requiredAccuracyMeters: accuracyThresholdMeters
            )
            guard isMatchable(validity) else {
                return .rejected(validity)
            }
            return .sample(sample, reused: true)
        case .acquire:
            return await captureFromProvider(
                accuracyThresholdMeters,
                seed: nil
            )
        case .seedCandidate(let sample):
            let validity = samplePolicy.validity(
                of: sample,
                now: clock.now(),
                requiredAccuracyMeters: accuracyThresholdMeters
            )
            let admittedSeed = isMatchable(validity) ? sample : nil
            return await captureFromProvider(
                accuracyThresholdMeters,
                seed: admittedSeed
            )
        }
    }

    private func captureFromProvider(
        _ accuracyThresholdMeters: Int,
        seed: LocationSample?
    ) async -> LocationAcquisitionResult {
        let capture = await locationProvider.capture(
            accuracyThresholdMeters,
            seed: seed
        )
        guard !Task.isCancelled else {
            return .failure(.cancelled(.taskCancelled))
        }
        switch capture {
        case .success(let sample):
            return .sample(sample, reused: seed != nil && sample == seed)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private func resolveAcceptedSample(
        _ sample: LocationSample,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> LocationResolutionResult {
        guard !Task.isCancelled else {
            return .cancelled(.taskCancelled)
        }
        guard effectGuard.allowsIrreversibleEffect() else {
            return .cancelled(.contextInvalidated)
        }
        let guardedMatchResult = await checkRepository.matchLocation(
            sample.latitude,
            sample.longitude,
            sample.horizontalAccuracyMeters,
            effectGuard: effectGuard
        )
        guard case .dispatched(let matchResult) = guardedMatchResult else {
            return .cancelled(.contextInvalidated)
        }
        guard !Task.isCancelled else {
            return .cancelled(.taskCancelled)
        }
        guard effectGuard.allowsIrreversibleEffect() else {
            return .cancelled(.contextInvalidated)
        }

        switch matchResult {
        case .success(let match):
            if match.status == .accuracyTooLow {
                activityLogger.logLocation(
                    "Location accuracy too low (±\(Int(sample.horizontalAccuracyMeters))m).",
                    nil,
                    .warning
                )
            } else {
                let loc = nonBlank(match.resolvedLocal) ?? "unknown"
                activityLogger.logLocation(
                    "Location fixed (±\(Int(sample.horizontalAccuracyMeters))m) → \(loc).",
                    match.resolvedLocal,
                    .info
                )
            }
            return .matched(match)
        case .failure(let error):
            let reading: LocationReading?
            if case .network = error {
                reading = LocationReading(
                    lat: sample.latitude,
                    lon: sample.longitude,
                    accuracyMeters: sample.horizontalAccuracyMeters
                )
            } else {
                reading = nil
            }
            return .matchFailure(error: error, reading: reading)
        }
    }

    private func captureExecution(
        from resolution: LocationResolutionResult,
        sample: LocationSample,
        trace: AutomaticCaptureTrace
    ) -> LocationCaptureExecution {
        switch resolution {
        case .matched(let match):
            return LocationCaptureExecution(
                result: .matched(match),
                maximumStage: .matched,
                capture: trace,
                failure: nil,
                retryableMatchSample: nil
            )
        case .matchFailure(let error, let reading):
            let retryableMatchSample: LocationSample?
            if case .unauthorized = error {
                retryableMatchSample = sample
            } else {
                retryableMatchSample = nil
            }
            return LocationCaptureExecution(
                result: .networkError(reading: reading),
                maximumStage: .matched,
                capture: trace,
                failure: .match(error),
                retryableMatchSample: retryableMatchSample
            )
        case .rejected(let validity):
            return LocationCaptureExecution(
                result: .timeout,
                maximumStage: .captured,
                capture: trace,
                failure: .sampleRejected(validity),
                retryableMatchSample: nil
            )
        case .cancelled(let reason):
            return LocationCaptureExecution(
                result: .timeout,
                maximumStage: .captured,
                capture: trace,
                failure: .cancelled(reason),
                retryableMatchSample: nil
            )
        }
    }

    private func captureTrace(
        for sample: LocationSample,
        accuracyThresholdMeters: Int,
        reused: Bool,
        input: LocationAttemptInput,
        rejected: LocationSampleValidity?,
        evaluatedAt: Date
    ) -> AutomaticCaptureTrace {
        let quality: AutomaticCaptureQuality
        if let rejected {
            quality = .rejected(rejected)
        } else if sample.horizontalAccuracyMeters.isFinite,
                  sample.horizontalAccuracyMeters >= 0,
                  sample.horizontalAccuracyMeters <= Double(accuracyThresholdMeters) {
            quality = .usable
        } else {
            quality = .coarse
        }
        let source: AutomaticCaptureSource
        if case .seedCandidate = input, reused {
            source = .seed
        } else if quality == .coarse {
            source = .bestPartial
        } else {
            source = .freshCapture
        }
        return AutomaticCaptureTrace(
            source: source,
            physicalSource: sample.source,
            reused: reused,
            quality: quality,
            accuracyBucket: .classify(meters: sample.horizontalAccuracyMeters),
            ageBucket: .classify(
                seconds: evaluatedAt.timeIntervalSince(sample.capturedAt)
            )
        )
    }

    private func rejectedCaptureTrace(
        for input: LocationAttemptInput,
        accuracyThresholdMeters: Int,
        validity: LocationSampleValidity,
        evaluatedAt: Date
    ) -> AutomaticCaptureTrace? {
        guard case .finalSample(let sample) = input else { return nil }
        return captureTrace(
            for: sample,
            accuracyThresholdMeters: accuracyThresholdMeters,
            reused: true,
            input: input,
            rejected: validity,
            evaluatedAt: evaluatedAt
        )
    }

    private func legacyResult(
        from resolution: LocationResolutionResult
    ) -> LocationCaptureResult {
        switch resolution {
        case .matched(let match):
            return .matched(match)
        case .matchFailure(_, let reading):
            return .networkError(reading: reading)
        case .rejected, .cancelled:
            return .timeout
        }
    }

    private func legacyResult(
        from failure: LocationAcquisitionFailure
    ) -> LocationCaptureResult {
        switch failure {
        case .timeout, .cancelled:
            return .timeout
        case .unavailable, .permissionDenied:
            return .noPermission
        }
    }

    private func isMatchable(_ validity: LocationSampleValidity) -> Bool {
        switch validity {
        case .usable, .freshButTooInaccurate:
            return true
        case .stale, .invalid, .fromFuture:
            return false
        }
    }

    private func nonBlank(_ value: String?) -> String? {
        guard let value = value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
