import XCTest
@testable import Checking

// Mapeamento DTO→domínio + a regra `open.description` nunca-null (servidor tipa str="", 422 em null). §8/§14.
final class AccidentRepositoryMappingTests: XCTestCase {

    private func makeRepo(_ api: FakeAccidentApi) -> AccidentRepositoryLive {
        AccidentRepositoryLive(api: api, checkEventStream: CheckEventStream(makeStream: { _ in AsyncStream { $0.finish() } }))
    }

    func test_open_sends_empty_string_when_description_nil() async {
        let api = FakeAccidentApi()
        api.openResult = WebAccidentStateResponse(isActive: true, activeAccidents: [])
        let repo = makeRepo(api)
        _ = await repo.open(chave: "STSM", projectId: 1, locationId: 2, customLocationName: nil, zone: .safety, status: .ok, description: nil)
        XCTAssertEqual(api.openRequests.first?.description, "")   // NUNCA null no wire
    }

    func test_open_sends_empty_string_when_description_blank() async {
        let api = FakeAccidentApi()
        api.openResult = WebAccidentStateResponse(isActive: true, activeAccidents: [])
        let repo = makeRepo(api)
        _ = await repo.open(chave: "STSM", projectId: 1, locationId: 2, customLocationName: nil, zone: .safety, status: .ok, description: "   ")
        XCTAssertEqual(api.openRequests.first?.description, "")
    }

    func test_open_passes_through_nonblank_description() async {
        let api = FakeAccidentApi()
        api.openResult = WebAccidentStateResponse(isActive: true, activeAccidents: [])
        let repo = makeRepo(api)
        _ = await repo.open(chave: "STSM", projectId: 1, locationId: 2, customLocationName: nil, zone: .safety, status: .ok, description: "Queda de escada")
        XCTAssertEqual(api.openRequests.first?.description, "Queda de escada")
    }

    func test_getState_maps_active_item_and_user_report() async {
        let api = FakeAccidentApi()
        api.stateResult = WebAccidentStateResponse(
            isActive: true, accidentId: 42, accidentNumberLabel: "AC-42", projectId: 1, projectName: "P80",
            locationName: "Portaria", description: "d", awarenessStatus: "open",
            currentUserReport: WebAccidentUserReport(zone: .accident, status: .help, reportedAt: "2026-06-15T01:00:00Z"),
            activeAccidents: [WebAccidentActiveItem(accidentId: 42, accidentNumberLabel: "AC-42", projectId: 1,
                                                    projectName: "P80", locationName: "Portaria", description: "d",
                                                    awarenessStatus: "open", currentUserReport: nil)])
        let repo = makeRepo(api)
        guard case .success(let state) = await repo.getState("STSM") else { return XCTFail("expected success") }
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.accidentId, 42)
        XCTAssertEqual(state.currentUserReport?.zone, .accident)
        XCTAssertEqual(state.currentUserReport?.status, .help)
        XCTAssertEqual(state.currentUserReport?.reportedAt, iso("2026-06-15T01:00:00Z"))
        XCTAssertEqual(state.activeAccidents.first?.accidentId, 42)
    }

    func test_reportedAt_parse_failure_falls_back_to_nil_not_now() async {
        let api = FakeAccidentApi()
        api.stateResult = WebAccidentStateResponse(
            isActive: false, currentUserReport: WebAccidentUserReport(zone: .safety, status: .ok, reportedAt: "not-a-date"),
            activeAccidents: [])
        let repo = makeRepo(api)
        guard case .success(let state) = await repo.getState("STSM") else { return XCTFail("expected success") }
        XCTAssertNil(state.currentUserReport?.reportedAt)   // fallback nil (SEM fallback p/ "agora" — diferente do vídeo)
    }

    func test_video_capturedAt_parse_failure_falls_back_to_now_not_nil() async throws {
        let api = FakeAccidentApi()
        api.uploadResult = AccidentVideoUploadResponse(videoId: 1, publicUrl: "u", capturedAt: "not-a-date")
        let repo = makeRepo(api)
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_capturedat_\(UUID()).mp4")
        try Data("x".utf8).write(to: tempFile)
        let result = await repo.uploadVideo(chave: "STSM", idempotencyKey: "id", videoFile: tempFile, contentType: "video/mp4") { _ in }
        guard case .success(let upload) = result else { return XCTFail("expected success") }
        XCTAssertNotNil(upload.capturedAt)   // fallback "agora" — nunca nil (diferente do reportedAt)
    }

    func test_wizardProjects_and_wizardLocations_map_tuples() async {
        let api = FakeAccidentApi()
        let repo = makeRepo(api)
        // sem stub explícito → api retorna [] por padrão nos fakes; confirma o tipo/mapeamento não quebra.
        guard case .success(let projects) = await repo.wizardProjects(chave: "STSM") else { return XCTFail("expected success") }
        XCTAssertTrue(projects.isEmpty)
        guard case .success(let locations) = await repo.wizardLocations(chave: "STSM", projectId: 1) else { return XCTFail("expected success") }
        XCTAssertTrue(locations.isEmpty)
    }
}
