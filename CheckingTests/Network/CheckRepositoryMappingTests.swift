import XCTest
@testable import Checking

// Port de CheckHistoryMapperTest.kt (os 2 testes do spec §12) + provas dos dois deltas do mapper de submit
// (hasCurrentDayCheckin DERIVADO, transportEnabled HARDCODED) + construção do request.
final class CheckRepositoryMappingTests: XCTestCase {

    private func makeRepo(_ api: FakeCheckApi) -> CheckRepositoryLive {
        CheckRepositoryLive(api: api, clock: FixedClock(iso("2026-06-16T12:00:00Z")))
    }

    // MARK: getHistory (spec §12)

    func test_getHistory_mapsDtoToDomain_withLocationParsedTimeAndInforme() async {
        let api = FakeCheckApi()
        api.onGetHistory = { _ in
            WebCheckHistoryListResponseDto(items: [
                WebCheckHistoryItemDto(action: .checkin, projeto: "P80", local: "Área X", time: "2026-06-15T01:00:00Z", informe: .normal),
                WebCheckHistoryItemDto(action: .checkout, projeto: "P80", local: nil, time: "2026-06-15T03:00:00Z", informe: .retroativo),
            ])
        }
        let result = await makeRepo(api).getHistory("U3RD")
        guard case .success(let items) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].action, .checkIn)
        XCTAssertEqual(items[0].projeto, "P80")
        XCTAssertEqual(items[0].local, "Área X")
        XCTAssertEqual(items[0].time, iso("2026-06-15T01:00:00Z"))
        XCTAssertEqual(items[0].informe, .normal)
        XCTAssertEqual(items[1].action, .checkOut)
        XCTAssertNil(items[1].local)                       // null passa verbatim
        XCTAssertEqual(items[1].informe, .retroativo)
    }

    func test_getHistory_emptyList_mapsToEmptyDomainList() async {
        let api = FakeCheckApi()
        api.onGetHistory = { _ in WebCheckHistoryListResponseDto(items: []) }
        let result = await makeRepo(api).getHistory("U390")
        guard case .success(let items) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: submit mapper (os dois deltas vs getState)

    func test_submit_derives_hasCurrentDayCheckin_and_hardcodes_transportEnabled_false() async {
        let api = FakeCheckApi()
        api.onSubmit = { _ in
            MobileSubmitResponse(ok: true, state: MobileSyncStateResponse(
                found: true, chave: "STSM", projeto: "P80", currentAction: .checkin,
                currentLocal: "Unidade P80", lastCheckinAt: "2026-06-15T01:00:00Z"))
        }
        let result = await makeRepo(api).submit(chave: "STSM", projeto: "P80", action: .checkIn, local: "Unidade P80",
            informe: .normal, eventTime: iso("2026-06-16T12:00:00Z"), clientEventId: "cid", fillForms: true)
        guard case .success(let state) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertTrue(state.hasCurrentDayCheckin)           // DERIVADO de currentAction == checkin
        XCTAssertFalse(state.transportEnabled)              // HARDCODED false
        XCTAssertEqual(state.currentLocal, "Unidade P80")
        XCTAssertEqual(state.lastCheckinAt, iso("2026-06-15T01:00:00Z"))
    }

    func test_submit_checkout_state_yields_hasCurrentDayCheckin_false() async {
        let api = FakeCheckApi()
        api.onSubmit = { _ in
            MobileSubmitResponse(ok: true, state: MobileSyncStateResponse(found: true, chave: "STSM", currentAction: .checkout))
        }
        let result = await makeRepo(api).submit(chave: "STSM", projeto: "P80", action: .checkOut, local: nil,
            informe: .normal, eventTime: iso("2026-06-16T12:00:00Z"), clientEventId: "x", fillForms: true)
        guard case .success(let state) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertFalse(state.hasCurrentDayCheckin)
    }

    func test_submit_builds_request_with_iso_eventTime_and_passthrough_fields() async {
        let api = FakeCheckApi()
        api.onSubmit = { _ in MobileSubmitResponse(ok: true, state: MobileSyncStateResponse(found: true, chave: "STSM")) }
        _ = await makeRepo(api).submit(chave: "STSM", projeto: "P80", action: .checkOut, local: nil, informe: .retroativo,
            eventTime: iso("2026-06-15T01:00:00Z"), clientEventId: "cid-1", fillForms: false)
        let req = api.lastSubmitRequest!
        XCTAssertEqual(req.chave, "STSM")
        XCTAssertEqual(req.projeto, "P80")
        XCTAssertEqual(req.action, .checkout)
        XCTAssertNil(req.local)
        XCTAssertEqual(req.informe, .retroativo)
        XCTAssertEqual(req.eventTime, "2026-06-15T01:00:00Z")
        XCTAssertEqual(req.clientEventId, "cid-1")
        XCTAssertFalse(req.fillForms)
    }

    // MARK: getState / matchLocation / getLocations mappers

    func test_getState_maps_all_fields_from_dto() async {
        let api = FakeCheckApi()
        api.onGetState = { _ in
            WebCheckHistoryResponse(found: true, chave: "STSM", projeto: "P80", currentAction: .checkin,
                currentLocal: "Unidade P80", hasCurrentDayCheckin: true, lastCheckinAt: "2026-06-15T01:00:00Z",
                lastCheckoutAt: nil, transportEnabled: true)
        }
        let result = await makeRepo(api).getState("STSM")
        guard case .success(let s) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertTrue(s.hasCurrentDayCheckin)               // vem DIRETO do DTO (não derivado)
        XCTAssertTrue(s.transportEnabled)                   // vem DIRETO do DTO (não hardcoded)
        XCTAssertEqual(s.currentAction, .checkIn)
        XCTAssertEqual(s.lastCheckinAt, iso("2026-06-15T01:00:00Z"))
        XCTAssertNil(s.lastCheckoutAt)
    }

    func test_matchLocation_maps_status_and_builds_request() async {
        let api = FakeCheckApi()
        api.onMatchLocation = { _ in
            WebLocationMatchResponse(matched: false, resolvedLocal: nil, label: "", status: .accuracyTooLow,
                message: "", accuracyMeters: 80.0, accuracyThresholdMeters: 50, minimumCheckoutDistanceMeters: 2000,
                nearestWorkplaceDistanceMeters: nil)
        }
        let result = await makeRepo(api).matchLocation(1.3, 103.8, 80.0)
        guard case .success(let m) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(m.status, .accuracyTooLow)
        XCTAssertEqual(api.lastMatchRequest?.latitude, 1.3)
        XCTAssertEqual(api.lastMatchRequest?.accuracyMeters, 80.0)
    }

    func test_getLocations_renames_threshold_field() async {
        let api = FakeCheckApi()
        api.onGetLocations = { WebLocationOptionsResponse(items: ["Unidade P80"], locationAccuracyThresholdMeters: 50, mixedZoneIntervalMinutes: 15) }
        let result = await makeRepo(api).getLocations()
        guard case .success(let opts) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(opts.items, ["Unidade P80"])
        XCTAssertEqual(opts.accuracyThresholdMeters, 50)
        XCTAssertEqual(opts.mixedZoneIntervalMinutes, 15)
    }

    // MARK: getGeofences TTL cache

    func test_getGeofences_caches_within_ttl_and_refetches_on_chave_change() async {
        let api = FakeCheckApi()
        api.onGetGeofences = { _ in WebGeofencesResponse(locations: [GeofenceCircleDto(id: 1, local: "P80", centerLat: 1.0, centerLng: 2.0, radiusMeters: 100)]) }
        let repo = CheckRepositoryLive(api: api, clock: FixedClock(iso("2026-06-16T12:00:00Z")))
        _ = await repo.getGeofences("STSM")
        _ = await repo.getGeofences("STSM")               // dentro do TTL, mesma chave → cache
        XCTAssertEqual(api.getGeofencesCallCount, 1)
        _ = await repo.getGeofences("OTHER")              // chave mudou → refetch
        XCTAssertEqual(api.getGeofencesCallCount, 2)
    }

    func test_invalidateGeofenceCache_forcesRefetchForSameAccount() async {
        let api = FakeCheckApi()
        api.onGetGeofences = { _ in
            WebGeofencesResponse(locations: [
                GeofenceCircleDto(id: 1, local: "P80", centerLat: 1, centerLng: 2, radiusMeters: 100),
            ])
        }
        let repo = CheckRepositoryLive(api: api, clock: FixedClock(iso("2026-06-16T12:00:00Z")))
        _ = await repo.getGeofences("STSM")
        repo.invalidateGeofenceCache()
        _ = await repo.getGeofences("STSM")

        XCTAssertEqual(api.getGeofencesCallCount, 2)
    }

    // MARK: error propagation via safeApiCall

    func test_getState_http_error_maps_to_failure() async {
        let api = FakeCheckApi()
        api.onGetState = { _ in throw HTTPError(status: 500, body: "boom") }
        let result = await makeRepo(api).getState("STSM")
        XCTAssertEqual(result.error, .http(status: 500, detail: "boom"))
    }
}
