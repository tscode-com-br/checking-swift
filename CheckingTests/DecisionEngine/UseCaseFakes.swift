import Foundation
@testable import Checking

// ── Fakes ─────────────────────────────────────────────────────────────────────

final class FakeCaptureLocation: SampleAwareLocationCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var executionValue: LocationCaptureExecution
    private var executionGate: AsyncGate?
    private var recordedThresholds: [Int] = []
    private var recordedAttempts: [LocationAttemptInput] = []

    init(_ result: LocationCaptureResult) {
        executionValue = Self.inferredExecution(for: result)
    }

    init(execution: LocationCaptureExecution) {
        executionValue = execution
    }

    var result: LocationCaptureResult {
        get { lock.withLock { executionValue.result } }
        set { lock.withLock { executionValue = Self.inferredExecution(for: newValue) } }
    }
    var execution: LocationCaptureExecution {
        get { lock.withLock { executionValue } }
        set { lock.withLock { executionValue = newValue } }
    }
    var callCount: Int { lock.withLock { recordedAttempts.count } }
    var thresholds: [Int] { lock.withLock { recordedThresholds } }
    var attempts: [LocationAttemptInput] { lock.withLock { recordedAttempts } }

    func setExecutionGate(_ gate: AsyncGate?) {
        lock.withLock { executionGate = gate }
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
        let (execution, gate) = lock.withLock {
            recordedThresholds.append(accuracyThresholdMeters)
            recordedAttempts.append(locationAttempt)
            return (executionValue, executionGate)
        }
        await gate?.wait()
        return execution
    }

    private static func inferredExecution(
        for result: LocationCaptureResult
    ) -> LocationCaptureExecution {
        switch result {
        case .matched:
            LocationCaptureExecution(
                result: result,
                maximumStage: .matched,
                capture: nil,
                failure: nil
            )
        case .timeout:
            LocationCaptureExecution(
                result: result,
                maximumStage: .captureStarted,
                capture: nil,
                failure: .acquisition(.timeout)
            )
        case .noPermission:
            LocationCaptureExecution(
                result: result,
                maximumStage: .captureStarted,
                capture: nil,
                failure: .acquisition(.unavailable)
            )
        case .networkError:
            LocationCaptureExecution(
                result: result,
                maximumStage: .matched,
                capture: nil,
                failure: .match(.network)
            )
        }
    }
}

final class FakeLocationProvider: LocationProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var recordedSeed: LocationSample?
    var result: LocationCapture
    init(_ result: LocationCapture) { self.result = result }
    var callCount: Int { lock.withLock { calls } }
    var lastSeed: LocationSample? { lock.withLock { recordedSeed } }

    func capture(
        _ accuracyThresholdMeters: Int,
        seed: LocationSample?
    ) async -> LocationCapture {
        lock.withLock {
            calls += 1
            recordedSeed = seed
        }
        return result
    }
}

final class FakeCheckRepository: CheckRepository, @unchecked Sendable {
    struct MatchLocationCall: Equatable {
        let latitude: Double
        let longitude: Double
        let accuracyMeters: Double?
    }

    struct SubmitCall: Equatable {
        let chave: String
        let projeto: String
        let action: CheckAction
        let local: String?
        let informe: InformeType
        let eventTime: Date
        let clientEventId: String
        let fillForms: Bool
    }
    var matchLocationResult: AppResult<LocationMatch> = .failure(.unknown(description: nil))
    var queuedMatchLocationResults: [AppResult<LocationMatch>] = []
    var getStateResult: AppResult<HistoryState> = .failure(.unknown(description: nil))
    var queuedGetStateResults: [AppResult<HistoryState>] = []
    var getHistoryResult: AppResult<[CheckHistoryEntry]> = .success([])
    var getGeofencesResult: AppResult<[GeofenceCircle]> = .success([])
    var getLocationsResult: AppResult<LocationOptions> =
        .success(LocationOptions(items: ["Unidade P80"], accuracyThresholdMeters: 50, mixedZoneIntervalMinutes: 15))
    var queuedGetLocationsResults: [AppResult<LocationOptions>] = []
    var submitResult: AppResult<HistoryState> = .success(ucHistory(.checkIn))
    var submitHandler: (@Sendable (CheckAction, String?) -> AppResult<HistoryState>)?
    var matchLocationGate: AsyncGate?
    var submitGate: AsyncGate?
    var getStateGate: AsyncGate?
    var getStateStarted: AsyncGate?
    var getLocationsGate: AsyncGate?
    var getLocationsStarted: AsyncGate?
    private let getStateLock = NSLock()
    private let getLocationsLock = NSLock()
    private let matchLocationLock = NSLock()
    private var getStateCalls = 0
    private var getLocationsCalls = 0
    private var matchLocationCalls = 0
    private var recordedMatchLocationCalls: [MatchLocationCall] = []
    private var lastMatchLocationCallValue: MatchLocationCall?
    private(set) var submitCount = 0
    private(set) var lastSubmitAction: CheckAction?
    private(set) var lastSubmitLocal: String?
    private(set) var submitCalls: [SubmitCall] = []

    var matchLocationCallCount: Int { matchLocationLock.withLock { matchLocationCalls } }
    var getStateCallCount: Int { getStateLock.withLock { getStateCalls } }
    var getLocationsCallCount: Int { getLocationsLock.withLock { getLocationsCalls } }
    var lastMatchLocationCall: MatchLocationCall? {
        matchLocationLock.withLock { lastMatchLocationCallValue }
    }
    var matchLocationCallsSnapshot: [MatchLocationCall] {
        matchLocationLock.withLock { recordedMatchLocationCalls }
    }

    func matchLocation(
        _ lat: Double,
        _ lon: Double,
        _ accuracyMeters: Double?
    ) async -> AppResult<LocationMatch> {
        let result = matchLocationLock.withLock {
            matchLocationCalls += 1
            let call = MatchLocationCall(
                latitude: lat,
                longitude: lon,
                accuracyMeters: accuracyMeters
            )
            lastMatchLocationCallValue = call
            recordedMatchLocationCalls.append(call)
            guard !queuedMatchLocationResults.isEmpty else {
                return matchLocationResult
            }
            return queuedMatchLocationResults.removeFirst()
        }
        await matchLocationGate?.wait()
        return result
    }
    func getState(_ chave: String) async -> AppResult<HistoryState> {
        let result = getStateLock.withLock {
            getStateCalls += 1
            guard !queuedGetStateResults.isEmpty else { return getStateResult }
            return queuedGetStateResults.removeFirst()
        }
        await getStateStarted?.release()
        await getStateGate?.wait()
        return result
    }
    func getHistory(_ chave: String) async -> AppResult<[CheckHistoryEntry]> { getHistoryResult }
    func getGeofences(_ chave: String) async -> AppResult<[GeofenceCircle]> { getGeofencesResult }
    func getLocations() async -> AppResult<LocationOptions> {
        let result = getLocationsLock.withLock {
            getLocationsCalls += 1
            guard !queuedGetLocationsResults.isEmpty else {
                return getLocationsResult
            }
            return queuedGetLocationsResults.removeFirst()
        }
        await getLocationsStarted?.release()
        await getLocationsGate?.wait()
        return result
    }
    func submit(chave: String, projeto: String, action: CheckAction, local: String?, informe: InformeType,
                eventTime: Date, clientEventId: String, fillForms: Bool) async -> AppResult<HistoryState> {
        submitCount += 1
        lastSubmitAction = action
        lastSubmitLocal = local
        submitCalls.append(SubmitCall(chave: chave, projeto: projeto, action: action, local: local,
                                      informe: informe, eventTime: eventTime, clientEventId: clientEventId,
                                      fillForms: fillForms))
        await submitGate?.wait()
        if let handler = submitHandler { return handler(action, local) }
        return submitResult
    }
}

final class FakeOfflineQueue: OfflineCheckQueueing, @unchecked Sendable {
    private(set) var enqueued: [PendingCheckEvent] = []
    private(set) var clearCount = 0
    var enqueueGate: AsyncGate?
    func enqueue(_ event: PendingCheckEvent) async {
        await enqueueGate?.wait()
        enqueued.append(event)
    }
    func enqueueIfCurrent(
        _ event: PendingCheckEvent,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> Bool {
        await enqueueGate?.wait()
        return effectGuard.performIfCurrent {
            enqueued.append(event)
        }
    }
    func clear() async { enqueued.removeAll(); clearCount += 1 }
}

struct NoopActivityLogger: ActivityLogging {}

final class CapturingDao: ActivityLogDao, @unchecked Sendable {
    struct Boom: Error {}
    let throwOnInsert: Bool
    private(set) var rows: [ActivityLogRow] = []
    init(throwOnInsert: Bool = false) { self.throwOnInsert = throwOnInsert }
    func insert(_ row: ActivityLogRow) throws {
        if throwOnInsert { throw Boom() }
        rows.append(row)
    }
    func deleteOlderThan(_ epochMs: Int64) {}
    func trimToMax(_ max: Int) {}
    func pageNewestFirst(limit: Int, offset: Int) -> [ActivityLogRow] { Array(rows.suffix(limit)) }
    func count() -> Int { rows.count }
    func clearAll() { rows.removeAll() }
}

// ── Builders (nível de caso de uso) ──────────────────────────────────────────

func ucMatch(_ status: MatchStatus, _ resolvedLocal: String? = nil, nearest: Double? = nil) -> LocationMatch {
    LocationMatch(matched: status == .matched, resolvedLocal: resolvedLocal, label: resolvedLocal ?? "",
                  status: status, message: "", accuracyMeters: 10.0, accuracyThresholdMeters: 50,
                  minimumCheckoutDistanceMeters: 2000, nearestWorkplaceDistanceMeters: nearest)
}

func ucLocationSample(
    lat: Double = 1.3,
    lon: Double = 103.8,
    accuracyMeters: Double = 12,
    capturedAt: Date = iso("2026-06-20T08:00:00Z"),
    source: LocationSampleSource = .standardCapture
) -> LocationSample {
    LocationSample(
        latitude: lat,
        longitude: lon,
        horizontalAccuracyMeters: accuracyMeters,
        capturedAt: capturedAt,
        source: source
    )
}

func ucHistory(_ last: CheckAction?, currentLocal: String? = nil,
               lastCheckinAt: Date? = nil, lastCheckoutAt: Date? = nil) -> HistoryState {
    HistoryState(found: true, chave: "STSM", projeto: "P80", currentAction: last, currentLocal: currentLocal,
                 hasCurrentDayCheckin: last == .checkIn,
                 lastCheckinAt: lastCheckinAt ?? (last == .checkIn ? Date() : nil),
                 lastCheckoutAt: lastCheckoutAt ?? (last == .checkOut ? Date() : nil),
                 transportEnabled: false)
}
