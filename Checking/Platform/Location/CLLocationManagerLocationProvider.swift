import CoreLocation

enum LocationUpdateAuthorization: Sendable, Equatable {
    case allowed
    case permissionDenied
    case unavailable
}

enum LocationUpdateFailure: Sendable, Equatable {
    case permissionDenied
    case unavailable
    case locationUnknown
    case other
}

enum CoreLocationFailureSignal: Sendable, Equatable {
    case denied
    case locationUnknown
    case other
}

enum CoreLocationErrorClassifier {
    static func classify(_ error: Error) -> CoreLocationFailureSignal {
        let nsError = error as NSError
        guard nsError.domain == kCLErrorDomain,
              let code = CLError.Code(rawValue: nsError.code) else {
            return .other
        }

        switch code {
        case .denied:
            return .denied
        case .locationUnknown:
            return .locationUnknown
        default:
            return .other
        }
    }
}

/// Adapter mínimo: o `CLLocationManager` concreto nunca cruza o `MainActor`.
@MainActor
protocol LocationUpdateDriving: AnyObject {
    var authorization: LocationUpdateAuthorization { get }

    func start(
        onLocations: @escaping @MainActor @Sendable ([LocationSample]) -> Void,
        onFailure: @escaping @MainActor @Sendable (LocationUpdateFailure) -> Void
    )
    func stop()
}

@MainActor
protocol CaptureTimeoutCancellable: AnyObject {
    func cancel()
}

@MainActor
protocol CaptureTimeoutScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor @Sendable () -> Void
    ) -> any CaptureTimeoutCancellable
}

/// Implementação viva do contrato de captura de 15 segundos. O perfil escolhe um único caminho:
/// legado (sem seed/frescor) ou candidato (seed e política de 10 s/2 s); ambos compartilham somente
/// infraestrutura segura e nunca executam duas sessões para comparar resultados.
struct CLLocationManagerLocationProvider: LocationProvider {
    static let timeBudgetSeconds: TimeInterval = 15

    let behavior: LocationCaptureBehavior
    private let samplePolicy: LocationSamplePolicy
    private let now: @Sendable () -> Date
    private let makeDriver: @MainActor @Sendable () -> any LocationUpdateDriving
    private let makeTimeoutScheduler: @MainActor @Sendable () -> any CaptureTimeoutScheduling

    init(
        behavior: LocationCaptureBehavior = .legacyCompatible,
        samplePolicy: LocationSamplePolicy = .candidateTrial,
        now: @escaping @Sendable () -> Date = { Date() },
        makeDriver: @escaping @MainActor @Sendable () -> any LocationUpdateDriving = {
            CoreLocationUpdateDriver()
        },
        makeTimeoutScheduler: @escaping @MainActor @Sendable () -> any CaptureTimeoutScheduling = {
            TaskCaptureTimeoutScheduler()
        }
    ) {
        self.behavior = behavior
        self.samplePolicy = samplePolicy
        self.now = now
        self.makeDriver = makeDriver
        self.makeTimeoutScheduler = makeTimeoutScheduler
    }

    func capture(
        _ accuracyThresholdMeters: Int,
        seed: LocationSample?
    ) async -> LocationCapture {
        await CaptureSession(
            behavior: behavior,
            accuracyThresholdMeters: accuracyThresholdMeters,
            seed: seed,
            samplePolicy: samplePolicy,
            now: now,
            makeDriver: makeDriver,
            makeTimeoutScheduler: makeTimeoutScheduler
        ).run()
    }

    /// Compatibilidade da regra pura original usada por testes e pelo caminho legado.
    static func isBetter(_ candidate: CLLocation, than current: CLLocation?) -> Bool {
        guard let current else { return true }
        if !isValidAccuracy(candidate.horizontalAccuracy) { return false }
        if !isValidAccuracy(current.horizontalAccuracy) { return true }
        if candidate.horizontalAccuracy < current.horizontalAccuracy { return true }
        if candidate.horizontalAccuracy > current.horizontalAccuracy { return false }
        return candidate.timestamp > current.timestamp
    }

    static func isValidAccuracy(_ accuracy: CLLocationAccuracy) -> Bool {
        accuracy.isFinite && accuracy >= 0
    }
}

/// Sessão única e testável. Continuation, timer e driver são consumidos no primeiro terminal.
@MainActor
private final class CaptureSession {
    private let behavior: LocationCaptureBehavior
    private let accuracyThresholdMeters: Int
    private let seed: LocationSample?
    private let samplePolicy: LocationSamplePolicy
    private let now: @Sendable () -> Date
    private let makeDriver: @MainActor @Sendable () -> any LocationUpdateDriving
    private let makeTimeoutScheduler: @MainActor @Sendable () -> any CaptureTimeoutScheduling

    private var state: CaptureSessionState?
    private var driver: (any LocationUpdateDriving)?
    private var timeoutToken: (any CaptureTimeoutCancellable)?
    private var continuation: CheckedContinuation<LocationCapture, Never>?
    private var driverStarted = false
    private var cancellationRequested = false

    init(
        behavior: LocationCaptureBehavior,
        accuracyThresholdMeters: Int,
        seed: LocationSample?,
        samplePolicy: LocationSamplePolicy,
        now: @escaping @Sendable () -> Date,
        makeDriver: @escaping @MainActor @Sendable () -> any LocationUpdateDriving,
        makeTimeoutScheduler: @escaping @MainActor @Sendable () -> any CaptureTimeoutScheduling
    ) {
        self.behavior = behavior
        self.accuracyThresholdMeters = accuracyThresholdMeters
        self.seed = seed
        self.samplePolicy = samplePolicy
        self.now = now
        self.makeDriver = makeDriver
        self.makeTimeoutScheduler = makeTimeoutScheduler
    }

    func run() async -> LocationCapture {
        await withTaskCancellationHandler {
            await runProtected()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.requestCancellation()
            }
        }
    }

    private func runProtected() async -> LocationCapture {
        guard !Task.isCancelled, !cancellationRequested else {
            return .failure(.cancelled(.taskCancelled))
        }

        let captureStartedAt = now()
        state = CaptureSessionState(
            behavior: behavior,
            accuracyThresholdMeters: accuracyThresholdMeters,
            captureStartedAt: captureStartedAt,
            samplePolicy: samplePolicy
        )

        let admission = updateState {
            $0.admit(seed: seed, now: captureStartedAt)
        }
        if case .finish(let result) = admission {
            return result
        }

        guard !Task.isCancelled, !cancellationRequested else {
            return directCancellationResult()
        }

        let driver = makeDriver()
        self.driver = driver
        switch driver.authorization {
        case .allowed:
            break
        case .permissionDenied:
            return directFailureResult(.permissionDenied)
        case .unavailable:
            return directFailureResult(.unavailable)
        }

        guard !Task.isCancelled, !cancellationRequested else {
            return directCancellationResult()
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if Task.isCancelled || cancellationRequested {
                apply(updateState { $0.cancel(.taskCancelled) })
                return
            }

            timeoutToken = makeTimeoutScheduler().schedule(
                after: CLLocationManagerLocationProvider.timeBudgetSeconds
            ) { [weak self] in
                guard let self else { return }
                self.apply(self.updateState { $0.timeout(now: self.now()) })
            }

            driverStarted = true
            driver.start(
                onLocations: { [weak self] samples in
                    guard let self else { return }
                    self.apply(self.updateState { $0.receive(samples, now: self.now()) })
                },
                onFailure: { [weak self] failure in
                    self?.receive(failure)
                }
            )
        }
    }

    private func requestCancellation() {
        cancellationRequested = true
        guard state != nil else { return }
        apply(updateState { $0.cancel(.taskCancelled) })
    }

    private func receive(_ failure: LocationUpdateFailure) {
        let transition: CaptureSessionState.Transition
        switch failure {
        case .permissionDenied:
            transition = updateState { $0.fail(.permissionDenied) }
        case .unavailable:
            transition = updateState { $0.fail(.unavailable) }
        case .locationUnknown:
            transition = updateState { $0.locationUnknown() }
        case .other:
            transition = updateState { $0.locationUnknown() }
        }
        apply(transition)
    }

    private func updateState(
        _ mutation: (inout CaptureSessionState) -> CaptureSessionState.Transition
    ) -> CaptureSessionState.Transition {
        guard var state else { return .ignoredAfterFinish }
        let transition = mutation(&state)
        self.state = state
        return transition
    }

    private func directCancellationResult() -> LocationCapture {
        let transition = updateState { $0.cancel(.taskCancelled) }
        if case .finish(let result) = transition { return result }
        return .failure(.cancelled(.taskCancelled))
    }

    private func directFailureResult(_ failure: LocationAcquisitionFailure) -> LocationCapture {
        let transition = updateState { $0.fail(failure) }
        driver = nil
        if case .finish(let result) = transition { return result }
        return .failure(failure)
    }

    private func apply(_ transition: CaptureSessionState.Transition) {
        guard case .finish(let result) = transition,
              let continuation else { return }

        self.continuation = nil
        timeoutToken?.cancel()
        timeoutToken = nil
        if driverStarted {
            driverStarted = false
            driver?.stop()
        }
        driver = nil
        continuation.resume(returning: result)
    }
}

/// Único owner do objeto Core Location real. Coordenadas são convertidas para o tipo de domínio antes de
/// saírem do `MainActor`; erros externos são reduzidos a uma whitelist tipada.
@MainActor
private final class CoreLocationUpdateDriver: NSObject, LocationUpdateDriving, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private var onLocations: (@MainActor @Sendable ([LocationSample]) -> Void)?
    private var onFailure: (@MainActor @Sendable (LocationUpdateFailure) -> Void)?

    override init() {
        manager = CLLocationManager()
        super.init()
    }

    var authorization: LocationUpdateAuthorization {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            .allowed
        case .denied, .restricted:
            .permissionDenied
        case .notDetermined:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    func start(
        onLocations: @escaping @MainActor @Sendable ([LocationSample]) -> Void,
        onFailure: @escaping @MainActor @Sendable (LocationUpdateFailure) -> Void
    ) {
        self.onLocations = onLocations
        self.onFailure = onFailure
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.delegate = self
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.delegate = nil
        onLocations = nil
        onFailure = nil
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let samples = locations.map {
            LocationSample(
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude,
                horizontalAccuracyMeters: $0.horizontalAccuracy,
                capturedAt: $0.timestamp,
                source: .standardCapture
            )
        }
        Task { @MainActor [weak self, samples] in
            self?.onLocations?(samples)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        let signal = CoreLocationErrorClassifier.classify(error)

        Task { @MainActor [weak self, signal] in
            self?.receive(signal)
        }
    }

    private func receive(_ signal: CoreLocationFailureSignal) {
        let failure: LocationUpdateFailure
        switch signal {
        case .denied:
            switch manager.authorizationStatus {
            case .denied, .restricted:
                failure = .permissionDenied
            default:
                failure = .unavailable
            }
        case .locationUnknown:
            failure = .locationUnknown
        case .other:
            failure = .other
        }
        onFailure?(failure)
    }
}

@MainActor
private final class TaskCaptureTimeoutScheduler: CaptureTimeoutScheduling {
    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor @Sendable () -> Void
    ) -> any CaptureTimeoutCancellable {
        TaskCaptureTimeoutToken(delay: delay, operation: operation)
    }
}

@MainActor
private final class TaskCaptureTimeoutToken: CaptureTimeoutCancellable {
    private var task: Task<Void, Never>?

    init(
        delay: TimeInterval,
        operation: @escaping @MainActor @Sendable () -> Void
    ) {
        let safeDelay = delay.isFinite ? max(0, delay) : 0
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(safeDelay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            operation()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
