import Foundation

// Funções puras de estado do cliente — port 1:1 de domain/clientstate/ClientStateFunctions.kt + PasswordRules.kt.
// Ver port_spec_auth_lifecycle.md §3.

/// chave: uppercase → remove tudo fora [A-Z0-9] → primeiros 4. nil/"" → "". (uppercase ANTES do regex.)
func sanitizeSettingsChave(_ value: String?) -> String {
    let stripped = (value ?? "").uppercased().filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    return String(stripped.prefix(4))
}

/// CRIAR senha: length 3..10 E trim não-vazio.
func isPasswordLengthValid(_ password: String?) -> Bool {
    let raw = password ?? ""
    return (3...10).contains(raw.count) && !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// VERIFICAR senha (gate do debounce): 1..10. SEM mínimo 3, SEM trim — mais frouxa de propósito.
func isPasswordVerificationInputValid(_ password: String?) -> Bool {
    (1...10).contains((password ?? "").count)
}

/// Normaliza um valor de projeto: trim+uppercase; retorna se em `allowedProjects`, senão `fallbackProject`.
func normalizeProjectValue(_ projectValue: String?, _ allowedProjects: [String], _ fallbackProject: String) -> String {
    let normalized = (projectValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return allowedProjects.contains(normalized) ? normalized : fallbackProject
}

/// Normaliza uma lista: trim/uppercase/descarta-vazio/dedup; filtra por `allowedProjects` (se não-vazio);
/// se vazia, retorna `fallbackProjects` normalizados.
func normalizeProjectValues(_ values: [String], _ allowedProjects: [String], _ fallbackProjects: [String]) -> [String] {
    let normalizedAllowed = allowedProjects.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty }
    let allowedSet = Set(normalizedAllowed)

    var result: [String] = []
    var seen = Set<String>()
    for raw in values {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if n.isEmpty || seen.contains(n) { continue }
        if !normalizedAllowed.isEmpty && !allowedSet.contains(n) { continue }
        seen.insert(n)
        result.append(n)
    }
    if !result.isEmpty { return result }

    var fallbackSeen = Set<String>()
    return fallbackProjects.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        .filter { !$0.isEmpty && fallbackSeen.insert($0).inserted }
}

/// `x@` (local não-vazio, domínio vazio) → `x@petrobras.com.br`; senão retorna verbatim.
func autofillPetrobrasEmailDomain(_ value: String?) -> String {
    let raw = value ?? ""
    guard let atIndex = raw.firstIndex(of: "@") else { return raw }
    let localPart = String(raw[raw.startIndex..<atIndex])
    let domainPart = String(raw[raw.index(after: atIndex)...])
    if localPart.isEmpty || !domainPart.isEmpty { return raw }
    return "\(localPart)@petrobras.com.br"
}

struct NotificationMessageSplit: Equatable, Sendable {
    let primary: String
    let secondary: String
}

/// Split em linhas fiel ao regex Kotlin `\r?\n` — NÃO usar `CharacterSet.newlines` (mais amplo: também
/// quebraria em CR solto, U+000B/U+000C/U+0085/U+2028/U+2029, que o Kotlin NÃO trata como quebra de linha).
private func splitOnExplicitNewline(_ text: String) -> [String] {
    let rawParts = text.components(separatedBy: "\n")
    return rawParts.enumerated().map { index, part in
        // um \r imediatamente antes do \n faz parte do delimitador (CRLF) — só remove se HOUVE um \n depois
        // (ou seja, não é a última parte); um \r sem \n seguinte NÃO é quebra e permanece no texto.
        (index < rawParts.count - 1 && part.hasSuffix("\r")) ? String(part.dropLast()) : part
    }
}

/// Split de notificação em (primary/secondary) — port cuidadoso do índice (limite 62, threshold 0.55). §3.
func splitNotificationMessage(_ message: String?, maxPrimaryLength: Int = 62) -> NotificationMessageSplit {
    let limit = maxPrimaryLength > 8 ? maxPrimaryLength : 62
    let rawText = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if rawText.isEmpty { return NotificationMessageSplit(primary: "", secondary: "") }

    let explicitLines = splitOnExplicitNewline(rawText)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    if explicitLines.count > 1 {
        return NotificationMessageSplit(primary: explicitLines[0], secondary: explicitLines.dropFirst().joined(separator: " "))
    }

    let normalized = rawText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    let chars = Array(normalized)
    if chars.count <= limit { return NotificationMessageSplit(primary: normalized, secondary: "") }

    // lastIndexOf(' ', limit) — para trás a partir de `limit` (inclusivo).
    var splitIndex = -1
    var i = limit
    while i >= 0 { if chars[i] == " " { splitIndex = i; break }; i -= 1 }
    if splitIndex < Int(Double(limit) * 0.55) {
        // indexOf(' ', limit) — para frente a partir de `limit`.
        splitIndex = -1
        var j = limit
        while j < chars.count { if chars[j] == " " { splitIndex = j; break }; j += 1 }
    }
    if splitIndex == -1 { splitIndex = limit }
    let primary = String(chars[0..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    let secondary = String(chars[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return NotificationMessageSplit(primary: primary, secondary: secondary)
}

// MARK: - Multi-conta (senha por chave) — port de PersistedSettings.kt

/// Senha guardada da chave (gate `count==4`, valida com `isPasswordLengthValid`; senão "").
func resolvePersistedPassword(_ passwordsByChave: [String: String]?, _ chave: String) -> String {
    let normalizedChave = sanitizeSettingsChave(chave)
    guard normalizedChave.count == 4 else { return "" }
    let stored = passwordsByChave?[normalizedChave] ?? ""
    return isPasswordLengthValid(stored) ? stored : ""
}

/// Grava/remove a senha da chave no mapa (retorna o mapa novo). Inválida → remove.
func withPersistedPassword(_ passwordsByChave: [String: String]?, _ chave: String, _ password: String?) -> [String: String] {
    let normalizedChave = sanitizeSettingsChave(chave)
    var map = passwordsByChave ?? [:]
    guard normalizedChave.count == 4 else { return map }
    if isPasswordLengthValid(password) {
        map[normalizedChave] = password!
    } else {
        map.removeValue(forKey: normalizedChave)
    }
    return map
}
