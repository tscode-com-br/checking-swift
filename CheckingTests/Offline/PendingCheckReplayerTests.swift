import XCTest
@testable import Checking

// Port de PendingCheckReplayerTest.kt — drain/decide/taxonomia/24h/exactly-once. §9.2.
final class PendingCheckReplayerTests: XCTestCase {

    private let chave = "HR70"
    private let projeto = "P80"
    private let dayMs: Int64 = 24 * 60 * 60 * 1000

    private func raw(_ id: String, at: Int64) -> PendingCheckEvent {
        .raw(.init(chave: chave, projeto: projeto, capturedAtEpochMs: at, clientEventId: id,
                   latitude: 1.3, longitude: 103.8, accuracyMeters: 10.0))
    }
    private func decided(_ id: String, at: Int64, action: String = "checkout", local: String? = "Zona Mista") -> PendingCheckEvent {
        .decided(.init(chave: chave, projeto: projeto, capturedAtEpochMs: at, clientEventId: id,
                       action: action, local: local, informe: "normal"))
    }
    private func state(_ last: CheckAction?) -> HistoryState {
        HistoryState(found: true, chave: chave, projeto: projeto, currentAction: last, currentLocal: nil,
                     hasCurrentDayCheckin: last == .checkIn,
                     lastCheckinAt: last == .checkIn ? Date() : nil,
                     lastCheckoutAt: last == .checkOut ? Date() : nil, transportEnabled: false)
    }
    private func match(_ status: MatchStatus, _ local: String? = nil) -> LocationMatch {
        LocationMatch(matched: status == .matched, resolvedLocal: local, label: local ?? "", status: status, message: "",
                      accuracyMeters: 10.0, accuracyThresholdMeters: 50, minimumCheckoutDistanceMeters: 2000, nearestWorkplaceDistanceMeters: nil)
    }
    private let options = LocationOptions(items: ["Unidade P80"], accuracyThresholdMeters: 50, mixedZoneIntervalMinutes: 15)

    private func fixture(_ events: [PendingCheckEvent]) -> (PendingCheckReplayer, FakePendingCheckQueue, ReplaySpyRepository, RecordingActivityLogger) {
        let queue = FakePendingCheckQueue(events)
        let spy = ReplaySpyRepository()
        let logger = RecordingActivityLogger()
        return (PendingCheckReplayer(queue: queue, repository: spy, logger: logger), queue, spy, logger)
    }

    func test_decided_replays_verbatim_with_original_time_and_id() async {
        let (replayer, queue, spy, _) = fixture([decided("d", at: 1000, action: "checkout", local: "Zona Mista")])
        spy.submitResult = .success(state(.checkOut))
        let result = await replayer.drain()
        XCTAssertEqual(result, .completed)
        let pending = await queue.pending
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(spy.submitCalls, [ReplaySpyRepository.SubmitCall(
            chave: chave, projeto: projeto, action: .checkOut, local: "Zona Mista", informe: .normal,
            eventTime: Date(timeIntervalSince1970: 1.0), clientEventId: "d", fillForms: true)])
    }

    func test_raw_matches_decides_and_submits_with_original_time_and_id() async {
        let (replayer, _, spy, _) = fixture([raw("r", at: 2000)])
        spy.matchLocationResult = .success(match(.matched, "Unidade P80"))
        spy.getStateResult = .success(state(.checkOut))
        spy.getLocationsResult = .success(options)
        spy.submitResult = .success(state(.checkIn))
        let result = await replayer.drain()
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(spy.submitCalls, [ReplaySpyRepository.SubmitCall(
            chave: chave, projeto: projeto, action: .checkIn, local: "Unidade P80", informe: .normal,
            eventTime: Date(timeIntervalSince1970: 2.0), clientEventId: "r", fillForms: true)])
    }

    func test_raw_with_no_action_is_consumed_without_submitting() async {
        let (replayer, queue, spy, _) = fixture([raw("r", at: 3000)])
        spy.matchLocationResult = .success(match(.notInKnownLocation))
        spy.getStateResult = .success(state(.checkOut))
        spy.getLocationsResult = .success(options)
        let result = await replayer.drain()
        XCTAssertEqual(result, .completed)
        let pending = await queue.pending
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(spy.submitCalls.isEmpty)
    }

    func test_raw_not_in_known_location_after_checkin_replays_unregistered_checkin() async {
        let (replayer, queue, spy, _) = fixture([raw("r", at: 3000)])
        var checkedIn = state(.checkIn); checkedIn.currentLocal = "Unidade P80"
        spy.matchLocationResult = .success(match(.notInKnownLocation))
        spy.getStateResult = .success(checkedIn)
        spy.getLocationsResult = .success(options)
        spy.submitResult = .success(state(.checkIn))
        let result = await replayer.drain()
        XCTAssertEqual(result, .completed)
        let pending = await queue.pending
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(spy.submitCalls, [ReplaySpyRepository.SubmitCall(
            chave: chave, projeto: projeto, action: .checkIn, local: "Localização não Cadastrada", informe: .normal,
            eventTime: Date(timeIntervalSince1970: 3.0), clientEventId: "r", fillForms: true)])
    }

    func test_network_failure_retries_and_keeps_event() async {
        let (replayer, queue, spy, _) = fixture([decided("d", at: 1000)])
        spy.submitResult = .failure(.network)
        let result = await replayer.drain()
        XCTAssertEqual(result, .retry)
        let pending = await queue.pending
        XCTAssertEqual(pending.count, 1)
    }

    func test_http_4xx_drops_event() async {
        let (replayer, queue, spy, _) = fixture([decided("d", at: 1000)])
        spy.submitResult = .failure(.http(status: 422, detail: "bad local"))
        let result = await replayer.drain()
        XCTAssertEqual(result, .completed)
        let pending = await queue.pending
        XCTAssertTrue(pending.isEmpty)
    }

    func test_http_5xx_retries_and_keeps_event() async {
        let (replayer, queue, spy, _) = fixture([decided("d", at: 1000)])
        spy.submitResult = .failure(.http(status: 503, detail: "service unavailable"))
        let result = await replayer.drain()
        XCTAssertEqual(result, .retry)
        let pending = await queue.pending
        XCTAssertEqual(pending.count, 1)
    }

    func test_drain_logs_syncing_count_and_synced_on_success() async {
        let (replayer, _, spy, logger) = fixture([decided("d", at: 1000, action: "checkout", local: "Zona Mista")])
        spy.submitResult = .success(state(.checkOut))
        _ = await replayer.drain()
        XCTAssertEqual(logger.syncingCounts, [1])
        XCTAssertEqual(logger.synced.count, 1)
        XCTAssertEqual(logger.synced.first?.kind, .checkOut)
        XCTAssertEqual(logger.synced.first?.location, "Zona Mista")
    }

    func test_drain_logs_dropped_on_permanent_4xx() async {
        let (replayer, _, spy, logger) = fixture([decided("d", at: 1000, action: "checkin", local: "Unidade P80")])
        spy.submitResult = .failure(.http(status: 422, detail: "bad local"))
        _ = await replayer.drain()
        XCTAssertEqual(logger.dropped, [.checkIn])
        XCTAssertTrue(logger.synced.isEmpty)
    }

    func test_drains_in_capture_order_oldest_first() async {
        let (replayer, _, spy, _) = fixture([decided("late", at: 2000), decided("early", at: 1000)])
        spy.submitResult = .success(state(.checkOut))
        _ = await replayer.drain()
        XCTAssertEqual(spy.submitCalls.map(\.clientEventId), ["early", "late"])
    }

    func test_multi_day_backlog_fills_forms_only_within_24h_of_newest() async {
        let (replayer, _, spy, _) = fixture([
            decided("stale", at: 0, action: "checkin", local: "Unidade P80"),
            decided("recent", at: 2 * dayMs + 1000, action: "checkin", local: "Unidade P80"),
        ])
        spy.submitResult = .success(state(.checkIn))
        let result = await replayer.drain()
        XCTAssertEqual(result, .completed)
        let fillByEvent = Dictionary(uniqueKeysWithValues: spy.submitCalls.map { ($0.clientEventId, $0.fillForms) })
        XCTAssertEqual(fillByEvent["stale"], false)     // >24h antes do mais novo → sem FORMS
        XCTAssertEqual(fillByEvent["recent"], true)     // o mais novo → FORMS
    }
}
