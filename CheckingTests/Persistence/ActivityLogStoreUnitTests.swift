import XCTest
@testable import Checking

// Port de ActivityLogStoreTest.kt — prune-on-write args + mapeamento newest-first sobre um DAO spy. §10.

private final class RecordingActivityLogDao: ActivityLogDao, @unchecked Sendable {
    private(set) var rows: [ActivityLogRow] = []
    private(set) var lastDeleteOlderThan: Int64?
    private(set) var lastTrimMax: Int?
    private var nextId: Int64 = 1

    func insert(_ row: ActivityLogRow) throws {
        var withId = row; withId.id = nextId; nextId += 1; rows.append(withId)
    }
    func deleteOlderThan(_ epochMs: Int64) {
        lastDeleteOlderThan = epochMs
        rows.removeAll { $0.atEpochMs < epochMs }                 // `<` estrito
    }
    func trimToMax(_ max: Int) {
        lastTrimMax = max
        guard rows.count > max else { return }
        let keep = Set(sortedNewestFirst().prefix(max).map(\.id))
        rows.removeAll { !keep.contains($0.id) }
    }
    func pageNewestFirst(limit: Int, offset: Int) -> [ActivityLogRow] {
        Array(sortedNewestFirst().dropFirst(offset).prefix(limit))
    }
    func count() -> Int { rows.count }
    func clearAll() { rows.removeAll() }
    private func sortedNewestFirst() -> [ActivityLogRow] {
        rows.sorted { ($0.atEpochMs, $0.id) > ($1.atEpochMs, $1.id) }
    }
}

final class ActivityLogStoreUnitTests: XCTestCase {

    private func entry(_ at: Date, _ desc: String = "d") -> ActivityLogEntry {
        ActivityLogEntry(at: at, actor: .sys, kind: .active, severity: .info, description: desc, location: nil)
    }

    func test_record_inserts_and_prunes_on_write() throws {
        let dao = RecordingActivityLogDao()
        let store = ActivityLog(dao: dao)
        let at = iso("2026-06-19T10:00:00Z")
        try store.record(entry(at))
        XCTAssertEqual(dao.rows.count, 1)
        XCTAssertEqual(dao.lastDeleteOlderThan, epochMs(at) - ActivityLog.retentionMs)   // corte = at − 30d
        XCTAssertEqual(dao.lastTrimMax, ActivityLog.maxRows)
    }

    func test_page_maps_rows_to_entries_newest_first() throws {
        let dao = RecordingActivityLogDao()
        let store = ActivityLog(dao: dao)
        try store.record(entry(iso("2026-06-19T10:00:00Z"), "older"))
        try store.record(entry(iso("2026-06-19T11:00:00Z"), "newer"))
        let page = try store.page(offset: 0, limit: 30)
        XCTAssertEqual(page.count, 2)
        XCTAssertEqual(page.first?.description, "newer")
        XCTAssertEqual(page.first?.kind, .active)
        XCTAssertEqual(page.first?.severity, .info)
        XCTAssertEqual(page.first?.actor, .sys)
    }

    func test_toEntry_throws_on_unknown_enum_rawValue() {
        // Espelha o `valueOf` do Kotlin: rawValue desconhecido LANÇA (capturável), não trapa nem faz default.
        let corrupt = ActivityLogRow(id: 1, atEpochMs: 0, actor: "SYS", kind: "BOGUS_KIND", severity: "INFO", description: "x", location: nil)
        XCTAssertThrowsError(try corrupt.toEntry()) { error in
            XCTAssertEqual(error as? ActivityLogDecodingError, ActivityLogDecodingError(field: "kind", rawValue: "BOGUS_KIND"))
        }
    }

    func test_retention_and_cap_constants_are_pinned() {
        XCTAssertEqual(ActivityLog.retentionDays, 30)
        XCTAssertEqual(ActivityLog.retentionMs, 2_592_000_000)      // guard de overflow (Int64)
        XCTAssertEqual(ActivityLog.maxRows, 5000)
        XCTAssertEqual(ActivityLog.pageSize, 30)
    }
}
