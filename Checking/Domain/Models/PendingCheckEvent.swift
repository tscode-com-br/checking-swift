import Foundation

/// Evento da fila offline (P8) — port de domain/offline/PendingCheckEvent.kt.
/// `Codable` com discriminador polimórfico ACHATADO (`"type":"raw"/"decided"` no mesmo nível dos campos),
/// espelhando o formato kotlinx. Ver port_spec_offline_replay.md §2.
enum PendingCheckEvent: Sendable, Equatable {
    case raw(Raw)
    case decided(Decided)

    struct Raw: Sendable, Equatable, Codable {
        var chave: String
        var projeto: String
        var capturedAtEpochMs: Int64
        var clientEventId: String
        var latitude: Double
        var longitude: Double
        var accuracyMeters: Double?
    }

    struct Decided: Sendable, Equatable, Codable {
        var chave: String
        var projeto: String
        var capturedAtEpochMs: Int64
        var clientEventId: String
        var action: String   // "checkin" | "checkout"
        var local: String?
        var informe: String  // "normal" | "retroativo"
    }

    // Campos comuns (abstract no Kotlin) — chave de idempotência (clientEventId) e de ordenação/despejo (capturedAtEpochMs).
    var chave: String { switch self { case .raw(let r): return r.chave; case .decided(let d): return d.chave } }
    var projeto: String { switch self { case .raw(let r): return r.projeto; case .decided(let d): return d.projeto } }
    var capturedAtEpochMs: Int64 { switch self { case .raw(let r): return r.capturedAtEpochMs; case .decided(let d): return d.capturedAtEpochMs } }
    var clientEventId: String { switch self { case .raw(let r): return r.clientEventId; case .decided(let d): return d.clientEventId } }
}

// Discriminador achatado {"type":"raw"/"decided", ...campos...} — round-trip interno (store iOS parte vazio).
extension PendingCheckEvent: Codable {
    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "raw":     self = .raw(try Raw(from: decoder))
        case "decided": self = .decided(try Decided(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                     debugDescription: "unknown PendingCheckEvent type \(type)"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        switch self {
        case .raw(let raw):
            try container.encode("raw", forKey: .type)
            try raw.encode(to: encoder)
        case .decided(let decided):
            try container.encode("decided", forKey: .type)
            try decided.encode(to: encoder)
        }
    }
}
