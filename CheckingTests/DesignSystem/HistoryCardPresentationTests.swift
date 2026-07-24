import XCTest
@testable import Checking

final class HistoryCardPresentationTests: XCTestCase {
    private var singaporeCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = HistoryCardPresentation.singapore
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        singaporeCalendar.date(from: DateComponents(
            timeZone: HistoryCardPresentation.singapore,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute))!
    }

    private func history(checkIn: Date?, checkOut: Date?) -> HistoryState {
        HistoryState(
            found: true,
            chave: "HR70",
            projeto: "P80",
            currentAction: nil,
            currentLocal: nil,
            hasCurrentDayCheckin: false,
            lastCheckinAt: checkIn,
            lastCheckoutAt: checkOut,
            transportEnabled: false)
    }

    func test_latest_returnsNoneWhenHistoryHasNoActivity() {
        XCTAssertEqual(HistoryCardPresentation.latest(nil), .none)
        XCTAssertEqual(HistoryCardPresentation.latest(history(checkIn: nil, checkOut: nil)), .none)
    }

    func test_latest_selectsMostRecentAndPrefersCheckInOnTie() {
        let earlier = date(2026, 7, 22, 8, 10)
        let later = date(2026, 7, 22, 17, 5)

        XCTAssertEqual(HistoryCardPresentation.latest(history(checkIn: later, checkOut: earlier)), .checkIn)
        XCTAssertEqual(HistoryCardPresentation.latest(history(checkIn: earlier, checkOut: later)), .checkOut)
        XCTAssertEqual(HistoryCardPresentation.latest(history(checkIn: later, checkOut: later)), .checkIn)
    }

    func test_cell_formatsTodayAndYesterdayInSingaporeTime() {
        let now = date(2026, 7, 22, 12, 0)
        let today = HistoryCardPresentation.cell(
            instant: date(2026, 7, 22, 8, 7), isLatest: true, now: now, lang: "pt")
        let yesterday = HistoryCardPresentation.cell(
            instant: date(2026, 7, 21, 19, 42), isLatest: false, now: now, lang: "pt")

        XCTAssertEqual(today, HistoryCellPresentation(
            day: "Hoje", date: "22/07/26", time: "08:07", latest: true))
        XCTAssertEqual(yesterday, HistoryCellPresentation(
            day: "Ontem", date: "21/07/26", time: "19:42", latest: false))
    }

    func test_cell_usesLocalizedWeekdayOutsideTodayAndYesterday() {
        let presentation = HistoryCardPresentation.cell(
            instant: date(2026, 7, 20, 9, 5),
            isLatest: false,
            now: date(2026, 7, 22, 12, 0),
            lang: "pt")

        XCTAssertEqual(presentation.day, "Segunda-feira")
        XCTAssertEqual(presentation.date, "20/07/26")
        XCTAssertEqual(presentation.time, "09:05")
    }

    func test_cell_withNoInstantKeepsPlaceholdersEmpty() {
        XCTAssertEqual(
            HistoryCardPresentation.cell(instant: nil, isLatest: false, lang: "pt"),
            HistoryCellPresentation(day: nil, date: nil, time: nil, latest: false))
    }
}
