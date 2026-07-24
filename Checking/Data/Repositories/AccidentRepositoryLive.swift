import Foundation

/// Implementação viva de `AccidentRepository` — port de data/repository/AccidentRepositoryImpl.kt.
/// Ver port_spec_accident_video.md §8.
struct AccidentRepositoryLive: AccidentRepository {
    let api: any AccidentApi
    let checkEventStream: CheckEventStream
    var videoUploader: (any AccidentVideoUploading)? = nil

    func getState(_ chave: String) async -> AppResult<AccidentState> {
        await safeApiCall { try await api.getState(chave).toDomain() }
    }

    func open(chave: String, projectId: Int, locationId: Int?, customLocationName: String?,
             zone: AccidentZone, status: AccidentSafetyStatus, description: String?) async -> AppResult<AccidentState> {
        await safeApiCall {
            // O servidor tipa `description` como `str = ""` (não-nullable) — manda "" quando ausente,
            // NUNCA null (que dá 422). `description?.takeIf{ isNotBlank } ?: ""` — port exato.
            let nonBlankDescription = description.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let request = WebAccidentOpenRequest(chave: chave, projectId: projectId, locationId: locationId,
                customLocationName: customLocationName, zone: zone.toDto(), status: status.toDto(),
                description: nonBlankDescription ?? "")
            return try await api.open(request).toDomain()
        }
    }

    func report(chave: String, zone: AccidentZone, status: AccidentSafetyStatus) async -> AppResult<AccidentState> {
        await safeApiCall { try await api.report(WebAccidentReportRequest(chave: chave, zone: zone.toDto(), status: status.toDto())).toDomain() }
    }

    func acknowledge(chave: String, accidentId: Int?) async -> AppResult<AccidentState> {
        await safeApiCall { try await api.acknowledge(WebAccidentAcknowledgeRequest(chave: chave, accidentId: accidentId)).toDomain() }
    }

    func emergencyCall(chave: String) async -> AppResult<EmergencyCallResult> {
        await safeApiCall {
            let r = try await api.emergencyCall(EmergencyCallChaveRequest(chave: chave))
            return EmergencyCallResult(callNumber: r.callNumber, callNumberLabel: r.callNumberLabel,
                                       callSid: r.callSid, callStatus: r.callStatus, message: r.message)
        }
    }

    /// D4: exclusão do arquivo temporário SÓ em sucesso HTTP confirmado (dentro do `safeApiCall`, DEPOIS
    /// da resposta) — em falha, o `runCatching{delete}` nunca roda e o arquivo é RETIDO p/ re-tentativa.
    func uploadVideo(chave: String, idempotencyKey: String, videoFile: URL, contentType: String,
                     onProgress: @escaping @Sendable (Double) -> Void) async -> AppResult<VideoUploadResult> {
        await safeApiCall {
            let r: AccidentVideoUploadResponse
            if let videoUploader {
                let responseData = try await videoUploader.upload(
                    chave: chave,
                    idempotencyKey: idempotencyKey,
                    videoFile: videoFile,
                    contentType: contentType,
                    onProgress: onProgress)
                r = try JSONCoding.decoder.decode(AccidentVideoUploadResponse.self, from: responseData)
            } else {
                let videoData = try Data(contentsOf: videoFile)
                onProgress(0)
                r = try await api.uploadVideo(
                    chave: chave,
                    idempotencyKey: idempotencyKey,
                    videoData: videoData,
                    filename: videoFile.lastPathComponent,
                    contentType: contentType)
                onProgress(1)
                try? FileManager.default.removeItem(at: videoFile)
            }
            return VideoUploadResult(videoId: r.videoId, publicUrl: r.publicUrl,
                                     capturedAt: ISOInstant.parse(r.capturedAt) ?? Date())
        }
    }

    func wizardProjects(chave: String) async -> AppResult<[WizardProject]> {
        await safeApiCall { try await api.wizardProjects(chave).map { WizardProject(id: $0.id, name: $0.name) } }
    }

    func wizardLocations(chave: String, projectId: Int) async -> AppResult<[WizardLocation]> {
        await safeApiCall {
            try await api.wizardLocations(chave, projectId).map { WizardLocation(id: $0.id, name: $0.name, registered: $0.registered) }
        }
    }

    func streamCheckEvents(chave: String) -> AsyncStream<String> {
        checkEventStream.events(chave: chave)
    }
}

// MARK: - DTO → domínio

private extension WebAccidentStateResponse {
    func toDomain() -> AccidentState {
        AccidentState(isActive: isActive, accidentId: accidentId, accidentNumberLabel: accidentNumberLabel,
                      projectId: projectId, projectName: projectName, locationName: locationName,
                      description: description, awarenessStatus: awarenessStatus,
                      currentUserReport: currentUserReport?.toDomain(), activeAccidents: activeAccidents.map { $0.toDomain() })
    }
}
private extension WebAccidentActiveItem {
    func toDomain() -> AccidentActiveItem {
        AccidentActiveItem(accidentId: accidentId, accidentNumberLabel: accidentNumberLabel, projectId: projectId,
                           projectName: projectName, locationName: locationName, description: description,
                           awarenessStatus: awarenessStatus, currentUserReport: currentUserReport?.toDomain())
    }
}
private extension WebAccidentUserReport {
    // reportedAt: fallback nil em parse falho (SEM fallback pra "agora" — diferente do capturedAt do vídeo).
    func toDomain() -> AccidentUserReport {
        AccidentUserReport(zone: zone?.toDomain(), status: status?.toDomain(), reportedAt: ISOInstant.parse(reportedAt))
    }
}
