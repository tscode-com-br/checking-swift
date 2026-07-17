import Foundation

/// Endpoints de acidente — port de data/api/AccidentApi.kt. Lança em não-2xx; o repo envolve em `safeApiCall`.
/// Ver port_spec_accident_video.md §8.
protocol AccidentApi: Sendable {
    func getState(_ chave: String) async throws -> WebAccidentStateResponse
    func open(_ body: WebAccidentOpenRequest) async throws -> WebAccidentStateResponse
    func report(_ body: WebAccidentReportRequest) async throws -> WebAccidentStateResponse
    func acknowledge(_ body: WebAccidentAcknowledgeRequest) async throws -> WebAccidentStateResponse
    func emergencyCall(_ body: EmergencyCallChaveRequest) async throws -> EmergencyCallResponse
    /// Multipart: parts `chave`, `idempotency_key`, `video` (spec §5/§7 — espelhar exatamente).
    func uploadVideo(chave: String, idempotencyKey: String, videoData: Data, filename: String, contentType: String) async throws -> AccidentVideoUploadResponse
    func wizardProjects(_ chave: String) async throws -> [AccidentProjectOption]
    func wizardLocations(_ chave: String, _ projectId: Int) async throws -> [AccidentLocationOption]
}

struct AccidentApiLive: AccidentApi {
    let http: any HTTPClient

    func getState(_ chave: String) async throws -> WebAccidentStateResponse {
        try decode(await http.data(for: HTTPRequest(method: .get, path: "check/accident/state", query: ["chave": chave])))
    }
    func open(_ body: WebAccidentOpenRequest) async throws -> WebAccidentStateResponse {
        try decode(await http.data(for: HTTPRequest(method: .post, path: "check/accident/open", body: try JSONCoding.encoder.encode(body))))
    }
    func report(_ body: WebAccidentReportRequest) async throws -> WebAccidentStateResponse {
        try decode(await http.data(for: HTTPRequest(method: .post, path: "check/accident/report", body: try JSONCoding.encoder.encode(body))))
    }
    func acknowledge(_ body: WebAccidentAcknowledgeRequest) async throws -> WebAccidentStateResponse {
        try decode(await http.data(for: HTTPRequest(method: .post, path: "check/accident/acknowledge", body: try JSONCoding.encoder.encode(body))))
    }
    func emergencyCall(_ body: EmergencyCallChaveRequest) async throws -> EmergencyCallResponse {
        try decode(await http.data(for: HTTPRequest(method: .post, path: "check/accident/emergency-call", body: try JSONCoding.encoder.encode(body))))
    }
    func uploadVideo(chave: String, idempotencyKey: String, videoData: Data, filename: String, contentType: String) async throws -> AccidentVideoUploadResponse {
        var form = MultipartFormBuilder()
        form.addTextField(name: "chave", value: chave)
        form.addTextField(name: "idempotency_key", value: idempotencyKey)
        form.addFileField(name: "video", filename: filename, contentType: contentType, fileData: videoData)
        let body = form.finish()
        return try decode(await http.data(for: HTTPRequest(method: .post, path: "check/accident/video", body: body, contentType: form.contentTypeHeader)))
    }
    func wizardProjects(_ chave: String) async throws -> [AccidentProjectOption] {
        try decode(await http.data(for: HTTPRequest(method: .get, path: "check/accident/wizard/projects", query: ["chave": chave])))
    }
    func wizardLocations(_ chave: String, _ projectId: Int) async throws -> [AccidentLocationOption] {
        try decode(await http.data(for: HTTPRequest(method: .get, path: "check/accident/wizard/locations",
                                                     query: ["chave": chave, "project_id": String(projectId)])))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T { try JSONCoding.decoder.decode(T.self, from: data) }
}

/// Corpo multipart/form-data manual (URLSession não tem builder nativo). Port do `MultipartBody` do OkHttp.
struct MultipartFormBuilder {
    let boundary = "Boundary-\(UUID().uuidString)"
    private var data = Data()

    mutating func addTextField(name: String, value: String) {
        appendPartHeader(name: name)
        data.append(Data("\r\n\r\n".utf8))
        data.append(Data(value.utf8))
        data.append(Data("\r\n".utf8))
    }
    mutating func addFileField(name: String, filename: String, contentType: String, fileData: Data) {
        appendPartHeader(name: name, filename: filename)
        let safeContentType = contentType.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        data.append(Data("\r\nContent-Type: \(safeContentType)\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))
    }
    mutating func finish() -> Data {
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }
    var contentTypeHeader: String { "multipart/form-data; boundary=\(boundary)" }

    private mutating func appendPartHeader(name: String, filename: String? = nil) {
        data.append(Data("--\(boundary)\r\n".utf8))
        let safeName = escape(name)
        let disposition = filename.map { "Content-Disposition: form-data; name=\"\(safeName)\"; filename=\"\(escape($0))\"" }
            ?? "Content-Disposition: form-data; name=\"\(safeName)\""
        data.append(Data(disposition.utf8))
    }

    /// Escapa `"` e remove CR/LF — evita corromper o corpo multipart ou injetar headers via um valor
    /// hostil (hoje os call-sites só passam literais fixos + um filename gerado por UUID, mas o builder
    /// é geral). Espelha o comportamento do `MultipartBody` do OkHttp (escapa `"` como `%22`... aqui
    /// usamos `\"`, equivalente em efeito: nunca fecha a aspa do header prematuramente).
    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
