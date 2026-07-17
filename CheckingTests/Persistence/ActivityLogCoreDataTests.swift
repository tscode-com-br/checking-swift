import XCTest
@testable import Checking

// Port de ActivityLogDaoTest.kt (6) + ActivityLogStoreRoomTest.kt (2) sobre Core Data in-memory.
// Ver port_spec_persistence_foundation.md §10.
final class ActivityLogCoreDataTests: XCTestCase {

    private func makeDao() -> CoreDataActivityLogDao {
        CoreDataActivityLogDao(stack: CoreDataStack(inMemory: true))
    }
    private func row(at: Int64, desc: String = "d") -> ActivityLogRow {
        ActivityLogRow(id: 0, atEpochMs: at, actor: "SYS", kind: "ACTIVE", severity: "INFO", description: desc, location: nil)
    }

    // MARK: DAO (6)

    func test_insert_and_count() throws {
        let dao = makeDao()
        for i in 0..<3 { try dao.insert(row(at: Int64(i))) }
        XCTAssertEqual(dao.count(), 3)
    }

    func test_pageNewestFirst_returnsDisjointNewestFirstBlocks() throws {
        let dao = makeDao()
        for i in 1...65 { try dao.insert(row(at: Int64(i), desc: "d\(i)")) }
        let page0 = dao.pageNewestFirst(limit: 30, offset: 0)
        let page1 = dao.pageNewestFirst(limit: 30, offset: 30)
        XCTAssertEqual(page0.count, 30)
        XCTAssertEqual(page1.count, 30)
        XCTAssertEqual(page0.first?.atEpochMs, 65)          // newest first
        XCTAssertEqual(page0.last?.atEpochMs, 36)
        XCTAssertEqual(page1.first?.atEpochMs, 35)
        let ids0 = Set(page0.map(\.id)); let ids1 = Set(page1.map(\.id))
        XCTAssertTrue(ids0.isDisjoint(with: ids1))
    }

    func test_deleteOlderThan_removesOnlyOld() throws {
        let dao = makeDao()
        try dao.insert(row(at: 100)); try dao.insert(row(at: 200)); try dao.insert(row(at: 300))
        dao.deleteOlderThan(200)                            // remove atEpochMs < 200 → só o 100
        XCTAssertEqual(dao.count(), 2)
        XCTAssertTrue(dao.pageNewestFirst(limit: 10, offset: 0).allSatisfy { $0.atEpochMs >= 200 })
    }

    func test_trimToMax_keepsNewestN() throws {
        let dao = makeDao()
        for i in 1...10 { try dao.insert(row(at: Int64(i))) }
        dao.trimToMax(4)
        XCTAssertEqual(dao.count(), 4)
        XCTAssertEqual(dao.pageNewestFirst(limit: 10, offset: 0).map(\.atEpochMs), [10, 9, 8, 7])
    }

    func test_trimToMax_at5000_keepsNewest5000() throws {
        let dao = makeDao()
        for i in 1...5001 { try dao.insert(row(at: Int64(i))) }
        dao.trimToMax(5000)
        XCTAssertEqual(dao.count(), 5000)
        let page = dao.pageNewestFirst(limit: 5000, offset: 0)
        XCTAssertEqual(page.first?.atEpochMs, 5001)         // mais novo mantido
        XCTAssertEqual(page.last?.atEpochMs, 2)             // sobrevivente mais antigo (o 1 sumiu)
        XCTAssertFalse(page.contains { $0.atEpochMs == 1 })
    }

    func test_clearAll_empties() throws {
        let dao = makeDao()
        try dao.insert(row(at: 1))
        dao.clearAll()
        XCTAssertEqual(dao.count(), 0)
    }

    // MARK: Store sobre Core Data real (2)

    private func makeStore() -> ActivityLog {
        ActivityLog(dao: CoreDataActivityLogDao(stack: CoreDataStack(inMemory: true)))
    }
    private func entry(_ at: Date, actor: ActivityActor = .sys, kind: ActivityKind = .active,
                       severity: ActivitySeverity = .info, desc: String = "d", loc: String? = nil) -> ActivityLogEntry {
        ActivityLogEntry(at: at, actor: actor, kind: kind, severity: severity, description: desc, location: loc)
    }

    func test_record_then_page_roundTrips_newestFirst_withAllFields() throws {
        let store = makeStore()
        try store.record(entry(iso("2026-06-19T10:00:00Z"), desc: "older"))
        try store.record(entry(iso("2026-06-19T11:00:00Z"), actor: .user, kind: .checkIn, severity: .success,
                               desc: "Check-in at Gate 3.", loc: "Gate 3"))
        let page = try store.page(offset: 0, limit: 30)
        XCTAssertEqual(page.count, 2)
        let newest = page.first!
        XCTAssertEqual(newest.description, "Check-in at Gate 3.")
        XCTAssertEqual(newest.actor, .user)
        XCTAssertEqual(newest.kind, .checkIn)
        XCTAssertEqual(newest.severity, .success)
        XCTAssertEqual(newest.location, "Gate 3")
        XCTAssertEqual(newest.at, iso("2026-06-19T11:00:00Z"))
        XCTAssertEqual(page[1].description, "older")
    }

    func test_record_prunesEntriesOlderThan30Days_onWrite() throws {
        let store = makeStore()
        let old = iso("2026-05-01T00:00:00Z")
        try store.record(entry(old, desc: "ancient"))
        XCTAssertEqual(store.count(), 1)
        try store.record(entry(old.addingTimeInterval(31 * 24 * 60 * 60), desc: "fresh"))   // +31 dias
        XCTAssertEqual(store.count(), 1)
        XCTAssertEqual(try store.page(offset: 0, limit: 30).first?.description, "fresh")
    }
}
