import AVFoundation
import Foundation
@testable import Checking

/// Fake de `AccidentApi` no nível de DTO — para os testes de mapeamento do repositório.
final class FakeAccidentApi: AccidentApi, @unchecked Sendable {
    struct NotStubbed: Error {}
    var stateResult: WebAccidentStateResponse?
    var openResult: WebAccidentStateResponse?
    var uploadResult: AccidentVideoUploadResponse?
    var uploadError: Error?

    private let lock = NSLock()
    private var recordedOpenRequests: [WebAccidentOpenRequest] = []
    private var recordedUploadCalls: [(chave: String, idempotencyKey: String, filename: String, contentType: String)] = []
    var openRequests: [WebAccidentOpenRequest] { lock.withLock { recordedOpenRequests } }
    var uploadCalls: [(chave: String, idempotencyKey: String, filename: String, contentType: String)] { lock.withLock { recordedUploadCalls } }

    func getState(_ chave: String) async throws -> WebAccidentStateResponse {
        guard let r = stateResult else { throw NotStubbed() }; return r
    }
    func open(_ body: WebAccidentOpenRequest) async throws -> WebAccidentStateResponse {
        lock.withLock { recordedOpenRequests.append(body) }
        guard let r = openResult else { throw NotStubbed() }; return r
    }
    func report(_ body: WebAccidentReportRequest) async throws -> WebAccidentStateResponse { throw NotStubbed() }
    func acknowledge(_ body: WebAccidentAcknowledgeRequest) async throws -> WebAccidentStateResponse { throw NotStubbed() }
    func emergencyCall(_ body: EmergencyCallChaveRequest) async throws -> EmergencyCallResponse { throw NotStubbed() }
    func uploadVideo(chave: String, idempotencyKey: String, videoData: Data, filename: String, contentType: String) async throws -> AccidentVideoUploadResponse {
        lock.withLock { recordedUploadCalls.append((chave, idempotencyKey, filename, contentType)) }
        if let uploadError { throw uploadError }
        guard let r = uploadResult else { throw NotStubbed() }; return r
    }
    func wizardProjects(_ chave: String) async throws -> [AccidentProjectOption] { [] }
    func wizardLocations(_ chave: String, _ projectId: Int) async throws -> [AccidentLocationOption] { [] }
}

/// Fake de `AccidentRepository` no nível de domínio — para os testes da ViewModel.
final class FakeAccidentRepository: AccidentRepository, @unchecked Sendable {
    var stateResult: AppResult<AccidentState> = .failure(.network)
    /// Se setado, `getState` trava até `release()` — p/ forçar corridas de sessão em teste.
    var stateGate: AsyncGate?
    var openResult: AppResult<AccidentState> = .failure(.network)
    var reportResult: AppResult<AccidentState> = .failure(.network)
    var acknowledgeResult: AppResult<AccidentState> = .success(emptyState)
    var emergencyResult: AppResult<EmergencyCallResult> = .failure(.network)
    var uploadResult: AppResult<VideoUploadResult> = .failure(.network)
    var wizardProjectsResult: AppResult<[WizardProject]> = .success([])
    var wizardLocationsResult: AppResult<[WizardLocation]> = .success([])
    var sseEvents: [String] = []

    private let lock = NSLock()
    private var recordedGetStateCalls = 0
    private var recordedOpenCalls: [(locationId: Int?, customLocationName: String?, description: String?)] = []
    private var recordedReportCalls = 0
    private var recordedEmergencyCalls = 0
    private var recordedAcknowledgeCalls: [Int?] = []
    private var recordedUploadCalls: [(chave: String, idempotencyKey: String, file: URL)] = []
    var getStateCallCount: Int { lock.withLock { recordedGetStateCalls } }
    var openCalls: [(locationId: Int?, customLocationName: String?, description: String?)] { lock.withLock { recordedOpenCalls } }
    var reportCallCount: Int { lock.withLock { recordedReportCalls } }
    var emergencyCallCount: Int { lock.withLock { recordedEmergencyCalls } }
    var acknowledgeCalls: [Int?] { lock.withLock { recordedAcknowledgeCalls } }
    var uploadCalls: [(chave: String, idempotencyKey: String, file: URL)] { lock.withLock { recordedUploadCalls } }

    static let emptyState = AccidentState(isActive: false, accidentId: nil, accidentNumberLabel: nil, projectId: nil,
                                          projectName: nil, locationName: nil, description: nil, awarenessStatus: nil,
                                          currentUserReport: nil, activeAccidents: [])

    func getState(_ chave: String) async -> AppResult<AccidentState> {
        lock.withLock { recordedGetStateCalls += 1 }
        if let stateGate { await stateGate.wait() }
        return stateResult
    }
    func open(chave: String, projectId: Int, locationId: Int?, customLocationName: String?,
             zone: AccidentZone, status: AccidentSafetyStatus, description: String?) async -> AppResult<AccidentState> {
        lock.withLock { recordedOpenCalls.append((locationId, customLocationName, description)) }
        return openResult
    }
    func report(chave: String, zone: AccidentZone, status: AccidentSafetyStatus) async -> AppResult<AccidentState> {
        lock.withLock { recordedReportCalls += 1 }
        return reportResult
    }
    func acknowledge(chave: String, accidentId: Int?) async -> AppResult<AccidentState> {
        lock.withLock { recordedAcknowledgeCalls.append(accidentId) }
        return acknowledgeResult
    }
    func emergencyCall(chave: String) async -> AppResult<EmergencyCallResult> {
        lock.withLock { recordedEmergencyCalls += 1 }
        return emergencyResult
    }
    func uploadVideo(chave: String, idempotencyKey: String, videoFile: URL, contentType: String,
                     onProgress: @escaping @Sendable (Double) -> Void) async -> AppResult<VideoUploadResult> {
        lock.withLock { recordedUploadCalls.append((chave, idempotencyKey, videoFile)) }
        onProgress(1.0)
        return uploadResult
    }
    func wizardProjects(chave: String) async -> AppResult<[WizardProject]> { wizardProjectsResult }
    func wizardLocations(chave: String, projectId: Int) async -> AppResult<[WizardLocation]> { wizardLocationsResult }
    func streamCheckEvents(chave: String) -> AsyncStream<String> {
        let events = sseEvents
        return AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Fake de `VideoRecording` — grava start/stop/isRecording.
final class FakeVideoRecording: VideoRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var recording = false
    private var startCalls = 0
    private var stopCalls = 0
    var startCallCount: Int { lock.withLock { startCalls } }
    var stopCallCount: Int { lock.withLock { stopCalls } }
    var tempFile = URL(fileURLWithPath: "/tmp/accident_video_test.mp4")

    var previewSession: AVCaptureSession? { nil }

    func createTempFile() -> URL { tempFile }
    func prepare() throws {}
    func startRecording(outputFile: URL) throws -> URL {
        lock.withLock { recording = true; startCalls += 1 }
        return outputFile
    }
    func stopRecording() async throws { lock.withLock { recording = false; stopCalls += 1 } }
    func cancelRecording() { lock.withLock { recording = false; stopCalls += 1 } }
    func isRecording() -> Bool { lock.withLock { recording } }
}

final class FakeAccidentVideoUploader: AccidentVideoUploading, @unchecked Sendable {
    private let lock = NSLock()
    var responseData = Data()
    var error: Error?
    private(set) var receivedChave = ""
    private(set) var receivedIdempotencyKey = ""
    private(set) var receivedVideoFile: URL?

    func upload(
        chave: String,
        idempotencyKey: String,
        videoFile: URL,
        contentType: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        lock.withLock {
            receivedChave = chave
            receivedIdempotencyKey = idempotencyKey
            receivedVideoFile = videoFile
        }
        if let error { throw error }
        onProgress(0.5)
        onProgress(1)
        return responseData
    }
}

/// Contador thread-safe — p/ closures `@Sendable` que precisam mutar um contador capturado em teste.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@MainActor
func makeAccidentViewModel(repository: FakeAccidentRepository = FakeAccidentRepository(),
                           videoRecorder: any VideoRecording = FakeVideoRecording()) -> AccidentViewModel {
    // RecordingSleeper: não espera de verdade — os 3s reais entre tentativas de auto-checkin (D3)
    // travariam os testes por até 6s (2 delays); aqui a lógica de retry/contagem continua exata.
    AccidentViewModel(repository: repository, videoRecorder: videoRecorder, sleeper: RecordingSleeper())
}

func accidentItem(_ id: Int, projectName: String = "P80", reportedAt: Date? = nil) -> AccidentActiveItem {
    AccidentActiveItem(accidentId: id, accidentNumberLabel: "AC-\(id)", projectId: 1, projectName: projectName,
                       locationName: "L", description: nil, awarenessStatus: "open",
                       currentUserReport: reportedAt.map { AccidentUserReport(zone: nil, status: nil, reportedAt: $0) })
}

func accidentStateWith(_ items: [AccidentActiveItem], isActive: Bool = true, projectName: String? = "P80") -> AccidentState {
    AccidentState(isActive: isActive, accidentId: items.first?.accidentId, accidentNumberLabel: nil, projectId: nil,
                 projectName: projectName, locationName: nil, description: nil, awarenessStatus: nil,
                 currentUserReport: nil, activeAccidents: items)
}
