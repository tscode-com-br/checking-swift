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
    public init(method: HTTPMethod, path: String, query: [String: String] = [:], body: Data? = nil,
                contentType: String? = nil, accept: String = "application/json") {
        self.method = method; self.path = path; self.query = query; self.body = body
        self.contentType = contentType; self.accept = accept
    }
}

/// Cliente HTTP — seam testável. Lança `HTTPError` em não-2xx; deixa `URLError` propagar.
public protocol HTTPClient: Sendable {
    func data(for request: HTTPRequest) async throws -> Data
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
final class URLSessionHTTPClient: HTTPClient {
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
        if let cookieStore, let header = cookieStore.cookieHeader(for: url) {
            req.setValue(header, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw HTTPError(status: -1, body: nil) }

        if let cookieStore {
            let fields = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value -> (String, String)? in
                guard let k = key as? String, let v = value as? String else { return nil }
                return (k, v)
            })
            cookieStore.saveFromResponse(url, headerFields: fields)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        return data
    }
}
