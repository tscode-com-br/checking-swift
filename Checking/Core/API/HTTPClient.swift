import Foundation

/// Erro HTTP transportando status + corpo cru — espelha o que `retrofit2.HttpException` carrega
/// (`e.code()` + `errorBody().string()`). O `body` é a string BRUTA do FastAPI (sem parse de `{detail}`),
/// exatamente como o Android. Ver port_spec_network_contracts §2.
public struct HTTPError: Error, Equatable, Sendable {
    public let status: Int
    public let body: String?
    public init(status: Int, body: String?) { self.status = status; self.body = body }
}

public enum HTTPMethod: String, Sendable { case get = "GET", post = "POST", put = "PUT", delete = "DELETE" }

/// Resultado de uma operação cujo início precisa ser linearizado com uma revogação síncrona.
/// `notDispatched` significa que nenhum trabalho foi iniciado; uma operação que começou autorizada
/// continua sendo `dispatched`, mesmo que seu resultado seja posteriormente descartado pelo caller.
enum GuardedOperationResult<Value: Sendable>: Sendable {
    case notDispatched
    case dispatched(Value)
}

/// Fence efêmero e local ao processo. A closure fornecida pelo owner deve executar `operation` no mesmo
/// ponto de linearização em que testa seus tokens; nenhuma identidade ou credencial é carregada aqui.
struct HTTPRequestDispatchAuthorization: Sendable {
    private let performIfAuthorized: @Sendable (@Sendable () -> Void) -> Bool

    init(
        performIfAuthorized: @escaping @Sendable (@Sendable () -> Void) -> Bool
    ) {
        self.performIfAuthorized = performIfAuthorized
    }

    func start(_ operation: @escaping @Sendable () -> Void) -> Bool {
        performIfAuthorized(operation)
    }

    static let unrestricted = Self(performIfAuthorized: { operation in
        operation()
        return true
    })
}

/// Box mínimo usado pelas implementações default de protocolos. A `Task` nasce dentro do fence, de
/// modo que um fake conta somente operações realmente admitidas. O transporte URLSession usa um
/// `URLSessionDataTask` suspenso e lineariza o próprio `resume()` mais abaixo.
final class GuardedAsyncTaskBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Value, Error>?

    func install(_ task: Task<Value, Error>) {
        lock.withLock { self.task = task }
    }

    func installedTask() -> Task<Value, Error>? {
        lock.withLock { task }
    }
}

func runGuardedAsyncOperation<Value: Sendable>(
    authorization: HTTPRequestDispatchAuthorization,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> GuardedOperationResult<Value> {
    let box = GuardedAsyncTaskBox<Value>()
    guard authorization.start({
        box.install(Task { try await operation() })
    }), let task = box.installedTask() else {
        return .notDispatched
    }
    return .dispatched(try await task.value)
}

/// Política local de adoção de cookies da resposta. Ela não altera método, URL, headers ou body no wire.
/// Respostas de mutações de sessão precisam vencer atomicamente respostas comuns que já estavam em voo.
enum SessionCookieResponsePolicy: Sendable {
    case ordinary
    case authoritativeSessionMutation
}

/// Descrição de uma requisição (relativa à baseURL). `path` sem barra inicial: "check/state".
public struct HTTPRequest: Sendable {
    public var method: HTTPMethod
    public var path: String
    public var query: [String: String] = [:]
    public var body: Data? = nil
    /// Content-Type do `body`. `nil` + `body` presente → "application/json" (default). Multipart passa
    /// "multipart/form-data; boundary=…" aqui.
    public var contentType: String? = nil
    public var accept: String = "application/json"
    var sessionCookieResponsePolicy: SessionCookieResponsePolicy
    var dispatchAuthorization: HTTPRequestDispatchAuthorization

    /// Contrato público original. Consumidores comuns sempre usam a política padrão de cookie.
    public init(method: HTTPMethod, path: String, query: [String: String] = [:], body: Data? = nil,
                contentType: String? = nil, accept: String = "application/json") {
        self.method = method; self.path = path; self.query = query; self.body = body
        self.contentType = contentType; self.accept = accept
        sessionCookieResponsePolicy = .ordinary
        dispatchAuthorization = .unrestricted
    }

    /// Inicializador interno reservado aos endpoints de mutação de sessão. A política é apenas
    /// metadado local do cliente; não altera URL, método, headers ou body transmitidos.
    init(method: HTTPMethod, path: String, query: [String: String] = [:], body: Data? = nil,
         contentType: String? = nil, accept: String = "application/json",
         sessionCookieResponsePolicy: SessionCookieResponsePolicy) {
        self.method = method; self.path = path; self.query = query; self.body = body
        self.contentType = contentType; self.accept = accept
        self.sessionCookieResponsePolicy = sessionCookieResponsePolicy
        dispatchAuthorization = .unrestricted
    }
}

/// Cliente HTTP — seam testável. Lança `HTTPError` em não-2xx; deixa `URLError` propagar.
public protocol HTTPClient: Sendable {
    func data(for request: HTTPRequest) async throws -> Data
}

/// Refinamento interno: o contrato público de `HTTPClient` e seus conformers permanece inalterado.
/// Somente o transporte real precisa expor uma task suspensa cujo `resume()` possa ser linearizado.
private protocol GuardedHTTPClient: HTTPClient {
    func guardedData(
        for request: HTTPRequest
    ) async throws -> GuardedOperationResult<Data>
}

extension HTTPClient {
    /// Fallback para fakes/adapters que não possuem uma task suspensa. A criação da `Task` é
    /// linearizada, portanto uma autorização já revogada produz zero chamadas a `data(for:)`.
    func dataIfAuthorized(
        for request: HTTPRequest
    ) async throws -> GuardedOperationResult<Data> {
        if let guarded = self as? any GuardedHTTPClient {
            return try await guarded.guardedData(for: request)
        }
        return try await runGuardedAsyncOperation(
            authorization: request.dispatchAuthorization,
            operation: { try await self.data(for: request) }
        )
    }
}

/// Codifica os pares de query escapando `+` (e sub-delims). O `URLQueryItem` da Foundation deixa `+`
/// LITERAL (é legal em query por RFC-3986), e o Starlette/FastAPI o interpreta como espaço (`unquote_plus`)
/// — corrompendo, p.ex., uma `chave` base64. O OkHttp escapa `+` → `%2B`; espelhamos isso. Ver §5/§10.
func percentEncodedQuery(_ query: [String: String]) -> String? {
    guard !query.isEmpty else { return nil }
    let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?#;%"))
    return query.sorted { $0.key < $1.key }.map { key, value in
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(encodedKey)=\(encodedValue)"
    }.joined(separator: "&")
}

/// Implementação `URLSession`. Injeta `X-Client` + `Accept` em TODO request (§1/§11). Gerência de cookie
/// manual (desliga a do URLSession) para honrar a cifragem/host-only do jar do Android (§4).
/// NOTA: exercitada só por integração contra staging — os testes unitários fakeiam `CheckApi` no nível de DTO.
final class URLSessionHTTPClient: GuardedHTTPClient {
    private let session: URLSession
    private let baseURL: URL
    private let xClient: String
    private let cookieStore: (any SessionCookieStore)?

    init(baseURL: URL, xClient: String, session: URLSession? = nil, cookieStore: (any SessionCookieStore)? = nil) {
        self.baseURL = baseURL
        self.xClient = xClient
        self.cookieStore = cookieStore
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            // Gerência própria de cookie (o jar cifrado do §4). Desliga o storage padrão.
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.httpCookieStorage = nil
            config.timeoutIntervalForRequest = 30   // read ~30s (§1)
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    func data(for request: HTTPRequest) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(request.path), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = percentEncodedQuery(request.query)   // escapa '+' (URLQueryItem não escaparia)
        let url = components.url!

        var req = URLRequest(url: url)
        req.httpMethod = request.method.rawValue
        req.setValue(xClient, forHTTPHeaderField: "X-Client")
        req.setValue(request.accept, forHTTPHeaderField: "Accept")
        if let body = request.body {
            req.httpBody = body
            req.setValue(request.contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        // O token precisa nascer junto com a requisição. Uma troca de identidade durante o await invalida
        // qualquer Set-Cookie da resposta sem persistir identificador adicional.
        let cookieSnapshot = cookieStore?.requestSnapshot(for: url)
        if let header = cookieSnapshot?.cookieHeader {
            req.setValue(header, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw HTTPError(status: -1, body: nil) }

        if let cookieStore, let cookieSnapshot {
            let fields = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value -> (String, String)? in
                guard let k = key as? String, let v = value as? String else { return nil }
                return (k, v)
            })
            switch request.sessionCookieResponsePolicy {
            case .ordinary:
                cookieStore.saveFromResponse(
                    url,
                    headerFields: fields,
                    requestGeneration: cookieSnapshot.generation)
            case .authoritativeSessionMutation:
                cookieStore.saveAuthoritativeSessionResponse(
                    url,
                    headerFields: fields,
                    requestGeneration: cookieSnapshot.generation)
            }
        }

        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        return data
    }

    func guardedData(
        for request: HTTPRequest
    ) async throws -> GuardedOperationResult<Data> {
        var components = URLComponents(url: baseURL.appendingPathComponent(request.path), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = percentEncodedQuery(request.query)   // escapa '+' (URLQueryItem não escaparia)
        let url = components.url!

        var req = URLRequest(url: url)
        req.httpMethod = request.method.rawValue
        req.setValue(xClient, forHTTPHeaderField: "X-Client")
        req.setValue(request.accept, forHTTPHeaderField: "Accept")
        if let body = request.body {
            req.httpBody = body
            req.setValue(request.contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        // O token precisa nascer junto com a requisição. Uma troca de identidade durante o await invalida
        // qualquer Set-Cookie da resposta sem persistir identificador adicional.
        let cookieSnapshot = cookieStore?.requestSnapshot(for: url)
        if let header = cookieSnapshot?.cookieHeader {
            req.setValue(header, forHTTPHeaderField: "Cookie")
        }

        let transport = try await performDataTask(
            req,
            authorization: request.dispatchAuthorization
        )
        guard case .dispatched(let payload) = transport else {
            return .notDispatched
        }
        let data = payload.data

        if let cookieStore, let cookieSnapshot {
            switch request.sessionCookieResponsePolicy {
            case .ordinary:
                cookieStore.saveFromResponse(
                    url,
                    headerFields: payload.headerFields,
                    requestGeneration: cookieSnapshot.generation)
            case .authoritativeSessionMutation:
                cookieStore.saveAuthoritativeSessionResponse(
                    url,
                    headerFields: payload.headerFields,
                    requestGeneration: cookieSnapshot.generation)
            }
        }

        guard (200..<300).contains(payload.statusCode) else {
            throw HTTPError(status: payload.statusCode, body: String(data: data, encoding: .utf8))
        }
        return .dispatched(data)
    }

    /// `URLSession.data(for:)` não expõe o instante em que a task é iniciada. Criamos a data task
    /// suspensa e executamos seu `resume()` dentro do mesmo fence que a revogação. Assim há somente
    /// duas ordens possíveis: revogação vence e a task nunca inicia, ou o `resume()` vence enquanto os
    /// tokens ainda são válidos. Cancelamento e callback competem por um finalizador first-wins.
    private func performDataTask(
        _ request: URLRequest,
        authorization: HTTPRequestDispatchAuthorization
    ) async throws -> GuardedOperationResult<URLSessionTransportPayload> {
        let state = URLSessionDataTaskState<URLSessionTransportCompletion>(
            cancellationValue: .failure(.cancelled)
        )
        let completion = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.install(continuation)
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        if let urlError = error as? URLError {
                            state.finish(.failure(.url(urlError.code)))
                        } else if error is CancellationError {
                            state.finish(.failure(.cancelled))
                        } else {
                            state.finish(.failure(.unknown))
                        }
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        state.finish(.failure(.invalidResponse))
                        return
                    }
                    state.finish(.success(.dispatched(URLSessionTransportPayload(
                        data: data ?? Data(),
                        statusCode: http.statusCode,
                        headerFields: Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap {
                            key, value -> (String, String)? in
                            guard let key = key as? String,
                                  let value = value as? String else { return nil }
                            return (key, value)
                        })
                    ))))
                }
                guard state.attach(task) else {
                    task.cancel()
                    return
                }
                guard authorization.start({ state.resumeIfActive(task) }) else {
                    state.finish(.success(.notDispatched))
                    task.cancel()
                    return
                }
            }
        } onCancel: {
            state.cancel()
        }
        switch completion {
        case .success(let result):
            return result
        case .failure(.cancelled):
            throw CancellationError()
        case .failure(.url(let code)):
            throw URLError(code)
        case .failure(.invalidResponse):
            throw HTTPError(status: -1, body: nil)
        case .failure(.unknown):
            throw URLSessionTransportUnknownError()
        }
    }
}

private struct URLSessionTransportPayload: Sendable {
    let data: Data
    let statusCode: Int
    let headerFields: [String: String]
}

private enum URLSessionTransportFailure: Sendable {
    case cancelled
    case url(URLError.Code)
    case invalidResponse
    case unknown
}

private enum URLSessionTransportCompletion: Sendable {
    case success(GuardedOperationResult<URLSessionTransportPayload>)
    case failure(URLSessionTransportFailure)
}

private struct URLSessionTransportUnknownError: Error, Sendable {}

/// Estado lock-backed porque o cancellation handler é síncrono e pode vencer a instalação da
/// continuation/task. Nenhum lock é mantido ao chamar Foundation ou resumir a continuation.
private final class URLSessionDataTaskState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationValue: Value
    private var continuation: CheckedContinuation<Value, Never>?
    private var completedValue: Value?
    private var task: URLSessionDataTask?

    init(cancellationValue: Value) {
        self.cancellationValue = cancellationValue
    }

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        let completed = lock.withLock { () -> Value? in
            if let completedValue { return completedValue }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(returning: completed) }
    }

    func attach(_ task: URLSessionDataTask) -> Bool {
        lock.withLock {
            guard completedValue == nil else { return false }
            self.task = task
            return true
        }
    }

    func resumeIfActive(_ task: URLSessionDataTask) {
        let shouldResume = lock.withLock { completedValue == nil }
        if shouldResume { task.resume() }
    }

    func finish(_ value: Value) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            guard completedValue == nil else { return nil }
            completedValue = value
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }

    func cancel() {
        let task = lock.withLock { self.task }
        finish(cancellationValue)
        task?.cancel()
    }
}
