import Foundation

// DTOs de auth — port de data/dto/AuthDtos.kt. Respostas com defaults; requests com null explícito. §2.

// MARK: - Responses

struct WebPasswordStatusResponse: Decodable, Sendable {
    let found: Bool
    let chave: String
    let hasPassword: Bool
    let authenticated: Bool
    let message: String
    let pendingApproval: Bool

    enum CodingKeys: String, CodingKey {
        case found, chave, authenticated, message
        case hasPassword = "has_password"
        case pendingApproval = "pending_approval"
    }
    init(found: Bool, chave: String, hasPassword: Bool, authenticated: Bool, message: String, pendingApproval: Bool = false) {
        self.found = found; self.chave = chave; self.hasPassword = hasPassword
        self.authenticated = authenticated; self.message = message; self.pendingApproval = pendingApproval
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        found = try c.decode(Bool.self, forKey: .found)
        chave = try c.decode(String.self, forKey: .chave)
        hasPassword = try c.decode(Bool.self, forKey: .hasPassword)
        authenticated = try c.decode(Bool.self, forKey: .authenticated)
        message = try c.decode(String.self, forKey: .message)
        pendingApproval = try c.decodeIfPresent(Bool.self, forKey: .pendingApproval) ?? false
    }
}

struct WebUserSelfRegistrationResponse: Decodable, Sendable {
    let ok: Bool
    let authenticated: Bool
    let hasPassword: Bool
    let message: String
    let status: String
    let pendingApproval: Bool
    let queueFull: Bool
    let projects: [String]
    let activeProject: String

    enum CodingKeys: String, CodingKey {
        case ok, authenticated, message, status, projects
        case hasPassword = "has_password"
        case pendingApproval = "pending_approval"
        case queueFull = "queue_full"
        case activeProject = "active_project"
    }
    init(ok: Bool, authenticated: Bool, hasPassword: Bool, message: String, status: String = "registered",
         pendingApproval: Bool = false, queueFull: Bool = false, projects: [String] = [], activeProject: String = "") {
        self.ok = ok; self.authenticated = authenticated; self.hasPassword = hasPassword; self.message = message
        self.status = status; self.pendingApproval = pendingApproval; self.queueFull = queueFull
        self.projects = projects; self.activeProject = activeProject
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        authenticated = try c.decode(Bool.self, forKey: .authenticated)
        hasPassword = try c.decode(Bool.self, forKey: .hasPassword)
        message = try c.decode(String.self, forKey: .message)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "registered"
        pendingApproval = try c.decodeIfPresent(Bool.self, forKey: .pendingApproval) ?? false
        queueFull = try c.decodeIfPresent(Bool.self, forKey: .queueFull) ?? false
        projects = try c.decodeIfPresent([String].self, forKey: .projects) ?? []
        activeProject = try c.decodeIfPresent(String.self, forKey: .activeProject) ?? ""
    }
}

struct WebPasswordActionResponse: Decodable, Sendable {
    let ok: Bool
    let authenticated: Bool
    let hasPassword: Bool
    let message: String

    enum CodingKeys: String, CodingKey {
        case ok, authenticated, message
        case hasPassword = "has_password"
    }
    init(ok: Bool, authenticated: Bool, hasPassword: Bool, message: String) {
        self.ok = ok; self.authenticated = authenticated; self.hasPassword = hasPassword; self.message = message
    }
}

// MARK: - Requests (null explícito p/ opcionais)

struct WebPasswordRegisterRequest: Encodable, Sendable {
    let chave: String
    let projeto: String?
    let senha: String
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chave, forKey: .chave)
        if let projeto { try c.encode(projeto, forKey: .projeto) } else { try c.encodeNil(forKey: .projeto) }
        try c.encode(senha, forKey: .senha)
    }
    enum CodingKeys: String, CodingKey { case chave, projeto, senha }
}

struct WebUserSelfRegistrationRequest: Encodable, Sendable {
    let chave: String
    let nome: String
    let projetos: [String]
    let email: String?
    let senha: String
    let confirmarSenha: String
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chave, forKey: .chave)
        try c.encode(nome, forKey: .nome)
        try c.encode(projetos, forKey: .projetos)
        if let email { try c.encode(email, forKey: .email) } else { try c.encodeNil(forKey: .email) }
        try c.encode(senha, forKey: .senha)
        try c.encode(confirmarSenha, forKey: .confirmarSenha)
    }
    enum CodingKeys: String, CodingKey {
        case chave, nome, projetos, email, senha
        case confirmarSenha = "confirmar_senha"
    }
}

struct WebPasswordLoginRequest: Encodable, Sendable {
    let chave: String
    let senha: String
}

struct WebPasswordChangeRequest: Encodable, Sendable {
    let chave: String
    let senhaAntiga: String
    let novaSenha: String
    enum CodingKeys: String, CodingKey {
        case chave
        case senhaAntiga = "senha_antiga"
        case novaSenha = "nova_senha"
    }
}
