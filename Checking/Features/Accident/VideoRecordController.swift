import AVFoundation
import Foundation
import Observation

enum VideoRecordPhase: Sendable, Equatable { case recording, uploading, done, error }

/// Controller da tela de gravação — port de VideoRecordScreen.kt (o estado local da tela, não a VM).
/// **D4 aplicado aqui**: ao contrário do Kotlin (`runCatching { onUpload() }` — nunca lança porque
/// `safeApiCall` nunca relança, então SEMPRE cai em `.done`), este controller INSPECIONA o `AppResult`
/// devolvido por `uploadVideo`: `.done` só em `.success`; `.error` em `.failure` — nunca finge sucesso.
/// Ver port_spec_accident_video.md §7.
@Observable
@MainActor
final class VideoRecordController {
    private(set) var phase: VideoRecordPhase = .recording
    private(set) var uploadProgress: Double = 0
    private(set) var statusMessage: String = ""

    private let videoRecorder: any VideoRecording
    private let uploadVideo: @Sendable (URL, String, @escaping @Sendable (Double) -> Void) async -> AppResult<VideoUploadResult>
    private var recordedFile: URL?
    private var uploadResult: AppResult<VideoUploadResult>?    // última tentativa — p/ inspeção em teste

    var previewSession: AVCaptureSession? { videoRecorder.previewSession }
    var canRetryUpload: Bool { recordedFile != nil && phase == .error }

    init(videoRecorder: any VideoRecording,
         uploadVideo: @escaping @Sendable (URL, String, @escaping @Sendable (Double) -> Void) async -> AppResult<VideoUploadResult>) {
        self.videoRecorder = videoRecorder
        self.uploadVideo = uploadVideo
    }

    /// Gravação AUTO-INICIA ao entrar na tela (após bind câmera+mic — aqui: chamado quando ambas as
    /// permissões estão concedidas). Câmera/mic são pedidos NO MOMENTO da gravação (spec §7).
    func startRecording() {
        do {
            let file = videoRecorder.createTempFile()
            recordedFile = try videoRecorder.startRecording(outputFile: file)
            phase = .recording
        } catch {
            phase = .error
            statusMessage = t("accident.video.error")
        }
    }

    /// Para a gravação e envia. D4: transita p/ `.done` SÓ em `.success`; `.error` em `.failure`
    /// (o temp é deletado/retido pelo repositório — não aqui).
    func stopRecordingAndUpload() async {
        guard phase != .uploading else { return }   // reentrância: 2º toque durante upload em voo não duplica
        do {
            if videoRecorder.isRecording() { try await videoRecorder.stopRecording() }
        } catch {
            phase = .error
            statusMessage = t("accident.video.error")
            return
        }
        guard let file = recordedFile else { return }
        phase = .uploading
        statusMessage = t("accident.video.sending")
        let result = await uploadVideo(file, videoContentType) { [weak self] progress in
            Task { @MainActor in self?.uploadProgress = progress }
        }
        uploadResult = result
        switch result {
        case .success:
            phase = .done
            statusMessage = t("accident.video.sent")
        case .failure:
            phase = .error
            statusMessage = t("accident.video.error")
        }
    }

    /// Limpeza ao sair da tela — port do `DisposableEffect { onDispose { if isRecording stopRecording } }`.
    func onScreenDisposed() {
        if videoRecorder.isRecording() { videoRecorder.cancelRecording() }
    }
}
