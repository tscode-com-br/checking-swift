import XCTest
@testable import Checking

// D4 — vídeo inspeciona o Result: DONE só em sucesso (temp deletado no repo); ERROR em falha (temp retido). §14.
@MainActor
final class VideoUploadTests: XCTestCase {

    private func makeController(uploadResult: AppResult<VideoUploadResult>, recorder: FakeVideoRecording = FakeVideoRecording()) -> VideoRecordController {
        VideoRecordController(videoRecorder: recorder) { _, _, onProgress in
            onProgress(0.5); onProgress(1.0)
            return uploadResult
        }
    }

    func test_success_transitions_to_done() async {
        let result = VideoUploadResult(videoId: 1, publicUrl: "https://x/1.mp4", capturedAt: Date())
        let controller = makeController(uploadResult: .success(result))
        controller.startRecording()
        await controller.stopRecordingAndUpload()
        XCTAssertEqual(controller.phase, .done)
        XCTAssertEqual(controller.statusMessage, t("accident.video.sent"))
        XCTAssertEqual(controller.uploadProgress, 1.0)
    }

    func test_failure_transitions_to_error_not_done() async {
        let controller = makeController(uploadResult: .failure(.network))
        controller.startRecording()
        await controller.stopRecordingAndUpload()
        XCTAssertEqual(controller.phase, .error)
        XCTAssertNotEqual(controller.phase, .done)
        XCTAssertEqual(controller.statusMessage, t("accident.video.error"))
    }

    func test_http_failure_also_transitions_to_error() async {
        let controller = makeController(uploadResult: .failure(.http(status: 500, detail: "boom")))
        controller.startRecording()
        await controller.stopRecordingAndUpload()
        XCTAssertEqual(controller.phase, .error)
    }

    func test_recorder_stopped_on_upload() async {
        let recorder = FakeVideoRecording()
        let result = VideoUploadResult(videoId: 1, publicUrl: "https://x/1.mp4", capturedAt: Date())
        let controller = makeController(uploadResult: .success(result), recorder: recorder)
        controller.startRecording()
        XCTAssertTrue(recorder.isRecording())
        await controller.stopRecordingAndUpload()
        XCTAssertFalse(recorder.isRecording())
    }

    func test_screen_disposed_while_recording_stops_it() {
        let recorder = FakeVideoRecording()
        let controller = VideoRecordController(videoRecorder: recorder) { _, _, _ in .failure(.network) }
        controller.startRecording()
        XCTAssertTrue(recorder.isRecording())
        controller.onScreenDisposed()
        XCTAssertFalse(recorder.isRecording())
    }

    // MARK: - Repositório: delete do temp SÓ em sucesso (a peça de fidelidade do D4)

    func test_repository_deletes_temp_file_only_on_success() async throws {
        let api = FakeAccidentApi()
        api.uploadResult = AccidentVideoUploadResponse(videoId: 1, publicUrl: "https://x/1.mp4", capturedAt: "2026-06-15T01:00:00Z")
        let repo = AccidentRepositoryLive(api: api, checkEventStream: CheckEventStream(makeStream: { _ in AsyncStream { $0.finish() } }))

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_upload_\(UUID()).mp4")
        try Data("fake video".utf8).write(to: tempFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path))

        let result = await repo.uploadVideo(chave: "STSM", idempotencyKey: "id-1", videoFile: tempFile, contentType: "video/mp4") { _ in }
        guard case .success = result else { return XCTFail("expected success") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))   // deletado em sucesso
    }

    func test_repository_retains_temp_file_on_failure() async throws {
        let api = FakeAccidentApi()
        api.uploadError = HTTPError(status: 500, body: "boom")
        let repo = AccidentRepositoryLive(api: api, checkEventStream: CheckEventStream(makeStream: { _ in AsyncStream { $0.finish() } }))

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_upload_fail_\(UUID()).mp4")
        try Data("fake video".utf8).write(to: tempFile)

        let result = await repo.uploadVideo(chave: "STSM", idempotencyKey: "id-1", videoFile: tempFile, contentType: "video/mp4") { _ in }
        guard case .failure = result else { return XCTFail("expected failure") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path))    // RETIDO p/ re-tentar

        try? FileManager.default.removeItem(at: tempFile)   // limpeza do teste
    }

    func test_multipart_parts_are_chave_idempotencyKey_video() async throws {
        let api = FakeAccidentApi()
        api.uploadResult = AccidentVideoUploadResponse(videoId: 1, publicUrl: "u", capturedAt: "2026-06-15T01:00:00Z")
        let repo = AccidentRepositoryLive(api: api, checkEventStream: CheckEventStream(makeStream: { _ in AsyncStream { $0.finish() } }))
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_parts_\(UUID()).mp4")
        try Data("x".utf8).write(to: tempFile)

        _ = await repo.uploadVideo(chave: "STSM", idempotencyKey: "id-xyz", videoFile: tempFile, contentType: "video/mp4") { _ in }

        XCTAssertEqual(api.uploadCalls.first?.chave, "STSM")
        XCTAssertEqual(api.uploadCalls.first?.idempotencyKey, "id-xyz")
        XCTAssertEqual(api.uploadCalls.first?.contentType, "video/mp4")
    }
}
