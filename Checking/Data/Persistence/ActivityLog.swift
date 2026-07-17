import Foundation

// Store do log de atividades — port de data/local/activitylog/ActivityLog.kt + Dao + Row.
// Ver port_spec_persistence_foundation.md §2/§3. (DAO síncrono; a impl Core Data vem no slice de
// persistência — o motor/logger só precisam do contrato + fake em teste.)

struct ActivityLogRow: Sendable, Equatable {
    var id: Int64
    var atEpochMs: Int64
    var actor: String
    var kind: String
    var severity: String
    var description: String
    var location: String?
}

protocol ActivityLogDao: AnyObject, Sendable {
    func insert(_ row: ActivityLogRow) throws
    func deleteOlderThan(_ epochMs: Int64)
    func trimToMax(_ max: Int)
    func pageNewestFirst(limit: Int, offset: Int) -> [ActivityLogRow]
    func count() -> Int
    func clearAll()
}

/// Retenção "30 dias OU 5.000 linhas" — prune a CADA escrita. Corte de idade = `at` do próprio evento.
final class ActivityLog: @unchecked Sendable {
    static let pageSize = 30
    static let maxRows = 5000
    static let retentionDays: Int64 = 30
    static let retentionMs: Int64 = 2_592_000_000 // 30 * 24 * 60 * 60 * 1000 (Int64 — excede Int32)

    private let dao: any ActivityLogDao
    init(dao: any ActivityLogDao) { self.dao = dao }

    func record(_ entry: ActivityLogEntry) throws {
        try dao.insert(entry.toRow())
        dao.deleteOlderThan(epochMs(entry.at) - Self.retentionMs)
        dao.trimToMax(Self.maxRows)
    }
    // `throws` (não trap): espelha o `enum.valueOf` do Kotlin, que LANÇA em rawValue desconhecido — falha
    // alto (não default silencioso, spec §1), mas CAPTURÁVEL, ao contrário de um `!`. Uma linha corrompida
    // erra a leitura da tela do log, como no Android; não derruba o app.
    func page(offset: Int, limit: Int = ActivityLog.pageSize) throws -> [ActivityLogEntry] {
        try dao.pageNewestFirst(limit: limit, offset: offset).map { try $0.toEntry() }
    }
    func count() -> Int { dao.count() }
    func clear() { dao.clearAll() }
}

/// Erro de leitura do log — rawValue de enum persistido desconhecido (espelha `IllegalArgumentException` do `valueOf`).
struct ActivityLogDecodingError: Error, Equatable {
    let field: String
    let rawValue: String
}

func epochMs(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

extension ActivityLogEntry {
    func toRow() -> ActivityLogRow {
        ActivityLogRow(id: 0, atEpochMs: epochMs(at), actor: actor.rawValue, kind: kind.rawValue,
                       severity: severity.rawValue, description: description, location: location)
    }
}
extension ActivityLogRow {
    func toEntry() throws -> ActivityLogEntry {
        guard let actor = ActivityActor(rawValue: actor) else { throw ActivityLogDecodingError(field: "actor", rawValue: self.actor) }
        guard let kind = ActivityKind(rawValue: kind) else { throw ActivityLogDecodingError(field: "kind", rawValue: self.kind) }
        guard let severity = ActivitySeverity(rawValue: severity) else { throw ActivityLogDecodingError(field: "severity", rawValue: self.severity) }
        return ActivityLogEntry(at: Date(timeIntervalSince1970: Double(atEpochMs) / 1000),
                                actor: actor, kind: kind, severity: severity, description: description, location: location)
    }
}
