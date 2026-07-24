import Foundation

protocol AccidentVideoUploading: Sendable {
    func upload(
        chave: String,
        idempotencyKey: String,
        videoFile: URL,
        contentType: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data
}

/// Upload de acidente por `URLSessionConfiguration.background`.
///
/// O corpo multipart é materializado como arquivo em Application Support e enviado com
/// `uploadTask(fromFile:)`. O `taskDescription` guarda os caminhos necessários para que o delegate
/// conclua a limpeza mesmo se o iOS encerrar e relançar o processo durante o envio.
final class BackgroundAccidentVideoUploader: NSObject, AccidentVideoUploading, @unchecked Sendable {
    static let sessionIdentifier = "br.com.tscode.checking.accident-video-upload"

    private struct TaskMetadata: Codable, Sendable {
        let bodyPath: String
        let videoPath: String
    }

    private struct TaskContext {
        let continuation: CheckedContinuation<Data, Error>
        let onProgress: @Sendable (Double) -> Void
        var responseData = Data()
    }

    private final class CompletionBox: @unchecked Sendable {
        let closure: () -> Void
        init(_ closure: @escaping () -> Void) { self.closure = closure }
    }

    private let baseURL: URL
    private let xClient: String
    private let cookieStore: any SessionCookieStore
    private let lock = NSLock()
    private var contexts: [Int: TaskContext] = [:]
    private var restoredResponseData: [Int: Data] = [:]
    private var eventsCompletion: CompletionBox?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5 * 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(baseURL: URL, xClient: String, cookieStore: any SessionCookieStore) {
        self.baseURL = baseURL
        self.xClient = xClient
        self.cookieStore = cookieStore
        super.init()
    }

    /// Recria a sessão logo no launch para que tarefas restauradas voltem a ter delegate.
    func activate() { _ = session }

    func handlesSession(identifier: String) -> Bool { identifier == Self.sessionIdentifier }

    @MainActor
    func attachBackgroundEventsCompletion(_ completion: @escaping () -> Void) {
        lock.withLock { eventsCompletion = CompletionBox(completion) }
        activate()
    }

    func upload(
        chave: String,
        idempotencyKey: String,
        videoFile: URL,
        contentType: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyFile = try Self.makeMultipartBodyFile(
            boundary: boundary,
            chave: chave,
            idempotencyKey: idempotencyKey,
            videoFile: videoFile,
            contentType: contentType)

        let url = baseURL.appendingPathComponent("check/accident/video")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(xClient, forHTTPHeaderField: "X-Client")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let cookie = cookieStore.cookieHeader(for: url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: bodyFile)
            let metadata = TaskMetadata(bodyPath: bodyFile.path, videoPath: videoFile.path)
            task.taskDescription = (try? String(data: JSONCoding.encoder.encode(metadata), encoding: .utf8))
            lock.withLock {
                contexts[task.taskIdentifier] = TaskContext(
                    continuation: continuation,
                    onProgress: onProgress)
            }
            task.resume()
        }
    }

    static func makeMultipartBodyFile(
        boundary: String,
        chave: String,
        idempotencyKey: String,
        videoFile: URL,
        contentType: String
    ) throws -> URL {
        let directory = try uploadDirectory()
        let bodyFile = directory.appendingPathComponent("multipart_\(UUID().uuidString).body")
        guard FileManager.default.createFile(atPath: bodyFile.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: bodyFile.path)

        let output = try FileHandle(forWritingTo: bodyFile)
        do {
            try writeTextPart(name: "chave", value: chave, boundary: boundary, to: output)
            try writeTextPart(name: "idempotency_key", value: idempotencyKey, boundary: boundary, to: output)
            let filename = escaped(videoFile.lastPathComponent)
            let safeType = contentType.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            try output.write(contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"video\"; filename=\"\(filename)\"\r\nContent-Type: \(safeType)\r\n\r\n".utf8))

            let input = try FileHandle(forReadingFrom: videoFile)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try output.close()
            return bodyFile
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: bodyFile)
            throw error
        }
    }

    private static func writeTextPart(
        name: String,
        value: String,
        boundary: String,
        to output: FileHandle
    ) throws {
        let safeName = escaped(name)
        try output.write(contentsOf: Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(safeName)\"\r\n\r\n\(value)\r\n".utf8))
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    private static func uploadDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let directory = root.appendingPathComponent("AccidentVideoUploads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func metadata(for task: URLSessionTask) -> TaskMetadata? {
        guard let description = task.taskDescription,
              let data = description.data(using: .utf8)
        else { return nil }
        return try? JSONCoding.decoder.decode(TaskMetadata.self, from: data)
    }

    private func finish(task: URLSessionTask, error: Error?) {
        let taskID = task.taskIdentifier
        let context = lock.withLock { contexts.removeValue(forKey: taskID) }
        let restoredData = lock.withLock { restoredResponseData.removeValue(forKey: taskID) ?? Data() }
        let responseData = context?.responseData ?? restoredData
        let taskMetadata = metadata(for: task)

        if let bodyPath = taskMetadata?.bodyPath {
            try? FileManager.default.removeItem(atPath: bodyPath)
        }

        let result: Result<Data, Error>
        if let error {
            result = .failure(error)
        } else if let response = task.response as? HTTPURLResponse {
            let fields = Dictionary(uniqueKeysWithValues: response.allHeaderFields.compactMap { key, value -> (String, String)? in
                guard let key = key as? String, let value = value as? String else { return nil }
                return (key, value)
            })
            if let url = task.originalRequest?.url { cookieStore.saveFromResponse(url, headerFields: fields) }
            if (200..<300).contains(response.statusCode) {
                do {
                    _ = try JSONCoding.decoder.decode(AccidentVideoUploadResponse.self, from: responseData)
                    if let videoPath = taskMetadata?.videoPath {
                        try? FileManager.default.removeItem(atPath: videoPath)
                    }
                    result = .success(responseData)
                } catch {
                    // HTTP 2xx com corpo inválido não é sucesso funcional; conserva o vídeo para retry.
                    result = .failure(error)
                }
            } else {
                result = .failure(HTTPError(
                    status: response.statusCode,
                    body: String(data: responseData, encoding: .utf8)))
            }
        } else {
            result = .failure(HTTPError(status: -1, body: nil))
        }

        guard let context else { return }
        switch result {
        case .success(let data): context.continuation.resume(returning: data)
        case .failure(let error): context.continuation.resume(throwing: error)
        }
    }
}

extension BackgroundAccidentVideoUploader: URLSessionDataDelegate, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let callback = lock.withLock { contexts[task.taskIdentifier]?.onProgress }
        callback?(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.withLock {
            if contexts[dataTask.taskIdentifier] != nil {
                contexts[dataTask.taskIdentifier]?.responseData.append(data)
            } else {
                restoredResponseData[dataTask.taskIdentifier, default: Data()].append(data)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        finish(task: task, error: error)
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let box = lock.withLock { () -> CompletionBox? in
            defer { eventsCompletion = nil }
            return eventsCompletion
        }
        guard let box else { return }
        DispatchQueue.main.async { box.closure() }
    }
}
