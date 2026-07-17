import XCTest
@testable import Checking

// Port de ScheduledPauseTest.kt (32). Zona fixada em UTC. Ver docs/port_spec_decision_engine.md §9.4.
// Datas âncora: 2024-01-13 sáb · -14 dom · -15 seg · -16 ter.
final class ScheduledPauseTests: XCTestCase {

    private let cal = utcCalendar()

    private func settings(enabled: Bool = false, from: String = "22:00", to: String = "06:00",
                          suspendSat: Bool = false, suspendSun: Bool = false) -> ScheduledPauseSettings {
        ScheduledPauseSettings(scheduledPauseEnabled: enabled, scheduledPauseFrom: from, scheduledPauseTo: to,
                               suspendSaturdays: suspendSat, suspendSundays: suspendSun)
    }
    private func active(_ ts: String, _ s: ScheduledPauseSettings, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        isScheduledPauseActiveNow(iso(ts), cal, s)
    }
    private func resume(_ ts: String, _ s: ScheduledPauseSettings) -> Date? { nextResumeInstant(iso(ts), cal, s) }

    // ── isScheduledPauseActiveNow ──
    func test_all_disabled_never_paused() {
        let s = settings()
        XCTAssertFalse(active("2024-01-15T10:00:00Z", s))
        XCTAssertFalse(active("2024-01-13T10:00:00Z", s))
        XCTAssertFalse(active("2024-01-14T10:00:00Z", s))
    }
    func test_same_day_window() {
        let s = settings(enabled: true, from: "09:00", to: "17:00")
        XCTAssertFalse(active("2024-01-15T08:59:00Z", s))
        XCTAssertTrue(active("2024-01-15T09:00:00Z", s))
        XCTAssertTrue(active("2024-01-15T12:30:00Z", s))
        XCTAssertTrue(active("2024-01-15T16:59:00Z", s))
        XCTAssertFalse(active("2024-01-15T17:00:00Z", s))
        XCTAssertFalse(active("2024-01-15T20:00:00Z", s))
    }
    func test_wrap_midnight_window() {
        let s = settings(enabled: true, from: "22:00", to: "06:00")
        XCTAssertFalse(active("2024-01-15T21:59:00Z", s))
        XCTAssertTrue(active("2024-01-15T22:00:00Z", s))
        XCTAssertTrue(active("2024-01-15T23:59:00Z", s))
        XCTAssertTrue(active("2024-01-16T00:00:00Z", s))
        XCTAssertTrue(active("2024-01-16T05:59:00Z", s))
        XCTAssertFalse(active("2024-01-16T06:00:00Z", s))
    }
    func test_equal_endpoints_never_paused() {
        let s = settings(enabled: true, from: "09:00", to: "09:00")
        XCTAssertFalse(active("2024-01-15T09:00:00Z", s))
        XCTAssertFalse(active("2024-01-15T00:00:00Z", s))
        XCTAssertFalse(active("2024-01-15T23:59:00Z", s))
    }
    func test_suspend_saturdays() {
        let s = settings(suspendSat: true)
        XCTAssertTrue(active("2024-01-13T00:00:00Z", s))
        XCTAssertTrue(active("2024-01-13T12:00:00Z", s))
        XCTAssertTrue(active("2024-01-13T23:59:00Z", s))
        XCTAssertFalse(active("2024-01-14T10:00:00Z", s)) // domingo
    }
    func test_suspend_sundays() {
        let s = settings(suspendSun: true)
        XCTAssertTrue(active("2024-01-14T00:00:00Z", s))
        XCTAssertTrue(active("2024-01-14T12:00:00Z", s))
        XCTAssertFalse(active("2024-01-13T10:00:00Z", s)) // sábado
    }
    func test_suspend_both_weekends() {
        let s = settings(suspendSat: true, suspendSun: true)
        XCTAssertTrue(active("2024-01-13T10:00:00Z", s))
        XCTAssertTrue(active("2024-01-14T10:00:00Z", s))
        XCTAssertFalse(active("2024-01-15T10:00:00Z", s))
    }
    func test_suspend_saturday_window_disabled_still_paused() {
        XCTAssertTrue(active("2024-01-13T12:00:00Z", settings(enabled: false, suspendSat: true)))
    }

    // ── nextResumeInstant ──
    func test_resume_not_paused_returns_null() { XCTAssertNil(resume("2024-01-15T10:00:00Z", settings())) }
    func test_resume_window_disabled_no_weekend_returns_null() { XCTAssertNil(resume("2024-01-15T10:00:00Z", settings(enabled: false))) }
    func test_resume_same_day_window_paused() {
        XCTAssertEqual(resume("2024-01-15T10:00:00Z", settings(enabled: true, from: "09:00", to: "17:00")), iso("2024-01-15T17:00:00Z"))
    }
    func test_resume_same_day_at_start_boundary() {
        XCTAssertEqual(resume("2024-01-15T09:00:00Z", settings(enabled: true, from: "09:00", to: "17:00")), iso("2024-01-15T17:00:00Z"))
    }
    func test_resume_wrap_evening_tomorrow_at_end() {
        XCTAssertEqual(resume("2024-01-15T23:00:00Z", settings(enabled: true, from: "22:00", to: "06:00")), iso("2024-01-16T06:00:00Z"))
    }
    func test_resume_wrap_morning_today_at_end() {
        XCTAssertEqual(resume("2024-01-16T02:00:00Z", settings(enabled: true, from: "22:00", to: "06:00")), iso("2024-01-16T06:00:00Z"))
    }
    func test_resume_wrap_midnight_today_at_end() {
        XCTAssertEqual(resume("2024-01-16T00:00:00Z", settings(enabled: true, from: "22:00", to: "06:00")), iso("2024-01-16T06:00:00Z"))
    }
    func test_resume_saturday_suspended_sunday_not() {
        XCTAssertEqual(resume("2024-01-13T10:00:00Z", settings(suspendSat: true)), iso("2024-01-14T00:00:00Z"))
    }
    func test_resume_both_suspended_monday_midnight() {
        XCTAssertEqual(resume("2024-01-13T10:00:00Z", settings(suspendSat: true, suspendSun: true)), iso("2024-01-15T00:00:00Z"))
    }
    func test_resume_sunday_suspended_monday_midnight() {
        XCTAssertEqual(resume("2024-01-14T12:00:00Z", settings(suspendSun: true)), iso("2024-01-15T00:00:00Z"))
    }
    func test_resume_saturday_plus_wrap_window() {
        XCTAssertEqual(resume("2024-01-13T02:00:00Z", settings(enabled: true, from: "22:00", to: "06:00", suspendSat: true)), iso("2024-01-14T06:00:00Z"))
    }
    func test_resume_both_weekend_plus_wrap_window() {
        XCTAssertEqual(resume("2024-01-13T02:00:00Z", settings(enabled: true, from: "22:00", to: "06:00", suspendSat: true, suspendSun: true)), iso("2024-01-15T06:00:00Z"))
    }
}
