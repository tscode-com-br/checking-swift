import Foundation

/// Gravação de vídeo — port de platform/camera/VideoRecorder.kt (seam; impl AVFoundation é integração,
/// não testada por unit test — como CLLocationManager/NWPathMonitor). Ver port_spec_accident_video.md §7.
protocol VideoRecording: AnyObject, Sendable {
    /// Novo arquivo temporário (prefixo `accident_video_`, extensão `.mp4`, diretório de cache).
    func createTempFile() -> URL
    /// Inicia a gravação no arquivo dado; câmera traseira + microfone, MP4 HD (1280×720). Retorna o
    /// mesmo `outputFile` (a gravação continua até `stopRecording()`).
    func startRecording(outputFile: URL) -> URL
    func stopRecording()
    func isRecording() -> Bool
}

/// `VIDEO_CONTENT_TYPE` — constante do spec §7/§12.
let videoContentType = "video/mp4"

/// Impl AVFoundation fina — `AVCaptureSession` preset `.hd1280x720`, câmera traseira + mic, saída
/// `AVCaptureMovieFileOutput` em arquivo temp. Integração (bind de câmera real); não coberta por XCTest
/// unitário — a lógica de fase/upload (D4) é testada via fakes de `VideoRecording` na ViewModel.
final class AVFoundationVideoRecorder: NSObject, VideoRecording, @unchecked Sendable {
    // A sessão/output reais (AVCaptureSession, AVCaptureMovieFileOutput) são montados na integração de
    // UI (bind ao preview layer). Aqui só o contrato de arquivo temp + start/stop é implementado, para
    // não acoplar este arquivo a UIKit/SwiftUI — o bind de preview fica na camada de Feature/UI.
    private let lock = NSLock()
    private var recording = false

    func createTempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("accident_video_\(UUID().uuidString)").appendingPathExtension("mp4")
    }
    func startRecording(outputFile: URL) -> URL {
        lock.withLock { recording = true }
        return outputFile
    }
    func stopRecording() {
        lock.withLock { recording = false }
    }
    func isRecording() -> Bool { lock.withLock { recording } }
}
