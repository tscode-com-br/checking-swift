import AVFoundation
import Foundation

enum VideoRecordingError: Error, Equatable {
    case cameraUnavailable
    case microphoneUnavailable
    case cannotAddInput
    case cannotAddOutput
    case recordingFailed
}

/// Contrato da captura audiovisual. Ele fica no ator principal porque o preview e o ciclo da tela
/// pertencem à UI; o `AVCaptureSession` mantém internamente a fila própria de captura do AVFoundation.
@MainActor
protocol VideoRecording: AnyObject, Sendable {
    var previewSession: AVCaptureSession? { get }
    func createTempFile() -> URL
    func prepare() throws
    func startRecording(outputFile: URL) throws -> URL
    /// Só retorna depois que o AVFoundation finalizou o contêiner MP4 no disco.
    func stopRecording() async throws
    /// Interrompe a captura ao abandonar a tela, sem iniciar upload.
    func cancelRecording()
    func isRecording() -> Bool
}

let videoContentType = "video/mp4"

/// Captura real: câmera traseira, microfone e MP4 em 1280×720.
/// A conclusão do delegate é aguardada antes do upload para impedir o envio de arquivo parcial.
final class AVFoundationVideoRecorder: NSObject, VideoRecording, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var prepared = false
    private var stopContinuation: CheckedContinuation<Void, Error>?

    var previewSession: AVCaptureSession? { session }

    func createTempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("accident_video_\(UUID().uuidString)")
            .appendingPathExtension("mp4")
    }

    func prepare() throws {
        guard !prepared else {
            if !session.isRunning { session.startRunning() }
            return
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw VideoRecordingError.cameraUnavailable
        }
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw VideoRecordingError.microphoneUnavailable
        }

        let cameraInput = try AVCaptureDeviceInput(device: camera)
        let microphoneInput = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(cameraInput), session.canAddInput(microphoneInput) else {
            throw VideoRecordingError.cannotAddInput
        }
        session.addInput(cameraInput)
        session.addInput(microphoneInput)

        guard session.canAddOutput(movieOutput) else { throw VideoRecordingError.cannotAddOutput }
        session.addOutput(movieOutput)
        movieOutput.movieFragmentInterval = .invalid

        prepared = true
        session.startRunning()
    }

    func startRecording(outputFile: URL) throws -> URL {
        try prepare()
        if FileManager.default.fileExists(atPath: outputFile.path) {
            try FileManager.default.removeItem(at: outputFile)
        }
        movieOutput.startRecording(to: outputFile, recordingDelegate: self)
        return outputFile
    }

    func stopRecording() async throws {
        guard movieOutput.isRecording else { return }
        try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            movieOutput.stopRecording()
        }
    }

    func cancelRecording() {
        if movieOutput.isRecording { movieOutput.stopRecording() }
        if session.isRunning { session.stopRunning() }
    }

    func isRecording() -> Bool { movieOutput.isRecording }
}

extension AVFoundationVideoRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let continuation = stopContinuation
            stopContinuation = nil
            if let error {
                continuation?.resume(throwing: error)
            } else if FileManager.default.fileExists(atPath: outputFileURL.path) {
                continuation?.resume()
            } else {
                continuation?.resume(throwing: VideoRecordingError.recordingFailed)
            }
        }
    }
}
