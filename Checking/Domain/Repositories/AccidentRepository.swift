import Foundation

/// Repositório de acidente — port de domain/repository/AccidentRepository.kt. Refina `AccidentStateReading`
/// (getState) — assim `AccidentRepositoryLive` serve tanto o slice de acidente quanto o seam do orquestrador.
/// Ver port_spec_accident_video.md §8.
protocol AccidentRepository: AccidentStateReading {
    // getState herdado de AccidentStateReading
    func open(chave: String, projectId: Int, locationId: Int?, customLocationName: String?,
             zone: AccidentZone, status: AccidentSafetyStatus, description: String?) async -> AppResult<AccidentState>
    func report(chave: String, zone: AccidentZone, status: AccidentSafetyStatus) async -> AppResult<AccidentState>
    func acknowledge(chave: String, accidentId: Int?) async -> AppResult<AccidentState>
    func emergencyCall(chave: String) async -> AppResult<EmergencyCallResult>
    /// `onProgress` em [0,1]. Ver §7 (D4 — o caller DEVE inspecionar o `AppResult`, nunca descartar).
    func uploadVideo(chave: String, idempotencyKey: String, videoFile: URL, contentType: String,
                     onProgress: @escaping @Sendable (Double) -> Void) async -> AppResult<VideoUploadResult>
    func wizardProjects(chave: String) async -> AppResult<[WizardProject]>
    func wizardLocations(chave: String, projectId: Int) async -> AppResult<[WizardLocation]>
    func streamCheckEvents(chave: String) -> AsyncStream<String>
}
