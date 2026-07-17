import OSLog

/// Categorias centrais de `OSLog`. NUNCA logar senha/cookie/token/coordenada exata/descrição sensível
/// (plano §21/§24). Redaction explícita nos call-sites.
public enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "br.com.tscode.checking"

    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let location = Logger(subsystem: subsystem, category: "location")
    public static let background = Logger(subsystem: subsystem, category: "background")
    public static let auth = Logger(subsystem: subsystem, category: "auth")
}
