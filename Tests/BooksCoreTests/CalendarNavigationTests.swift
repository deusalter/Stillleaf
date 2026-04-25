import Foundation
import XCTest
@testable import BooksCore

final class CalendarNavigationTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, timezoneID: String = "UTC") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezoneID)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testMonthGridIsWeekdayAlignedAndNeverMoreThanSixWeeks() {
        let navigation = CalendarNavigation(timezoneID: "UTC", anchor: date(2024, 2, 15), scale: .month)

        XCTAssertEqual(navigation.monthCells.count, 35)
        XCTAssertEqual(navigation.dayKey(for: navigation.monthCells.first!.date), "2024-01-28")
        XCTAssertEqual(navigation.dayKey(for: navigation.monthCells.last!.date), "2024-03-02")
        XCTAssertEqual(navigation.monthCells.filter(\.isInMonth).count, 29)
    }

    func testSixWeekMonthGridStaysBounded() {
        let navigation = CalendarNavigation(timezoneID: "UTC", anchor: date(2020, 8, 15), scale: .month)

        XCTAssertEqual(navigation.monthCells.count, 42)
        XCTAssertEqual(navigation.dayKey(for: navigation.monthCells.first!.date), "2020-07-26")
        XCTAssertEqual(navigation.dayKey(for: navigation.monthCells.last!.date), "2020-09-05")
    }

    func testScaleChangesKeepTheSelectedAnchorDate() {
        let selected = date(2024, 2, 29)
        var navigation = CalendarNavigation(timezoneID: "UTC", anchor: selected, scale: .year)

        navigation.setScale(.month)
        XCTAssertEqual(navigation.dayKey(for: navigation.anchor), "2024-02-29")
        navigation.select(navigation.anchor, scale: .day)
        XCTAssertEqual(navigation.scale, .day)
        XCTAssertEqual(navigation.title, "Thursday, February 29, 2024")
    }

    func testMonthNavigationUsesLeapYearCalendarArithmetic() {
        var navigation = CalendarNavigation(timezoneID: "UTC", anchor: date(2024, 1, 31), scale: .month)
        navigation.move(by: 1)

        XCTAssertEqual(navigation.dayKey(for: navigation.anchor), "2024-02-29")
        XCTAssertEqual(navigation.title, "February 2024")
    }

    func testMonthNavigationRetainsPreferredCivilDayAfterClamp() {
        var navigation = CalendarNavigation(timezoneID: "UTC", anchor: date(2024, 1, 31), scale: .month)
        navigation.move(by: 1)
        XCTAssertEqual(navigation.dayKey(for: navigation.anchor), "2024-02-29")
        navigation.move(by: 1)
        XCTAssertEqual(navigation.dayKey(for: navigation.anchor), "2024-03-31")
        navigation.move(by: -2)
        XCTAssertEqual(navigation.dayKey(for: navigation.anchor), "2024-01-31")
    }

    func testSameTimezoneAssignmentDoesNotResetPreferredCivilDay() {
        var navigation = CalendarNavigation(timezoneID: "UTC", anchor: date(2024, 1, 31), scale: .month)
        navigation.move(by: 1)
        XCTAssertEqual(navigation.dayKey(for: navigation.anchor), "2024-02-29")
        navigation.timezoneID = "UTC"
        navigation.move(by: 1)
        XCTAssertEqual(navigation.dayKey(for: navigation.anchor), "2024-03-31")
    }

    func testWeekTitleIncludesBothYearsWhenWeekCrossesNewYear() {
        let navigation = CalendarNavigation(timezoneID: "UTC", anchor: date(2024, 12, 31), scale: .week)
        XCTAssertEqual(navigation.title, "Dec 29, 2024 – Jan 4, 2025")
    }

    func testYearContainsExactlyTwelveMonths() {
        let navigation = CalendarNavigation(timezoneID: "UTC", anchor: date(2024, 2, 29), scale: .year)
        XCTAssertEqual(navigation.yearMonths.count, 12)
        XCTAssertEqual(navigation.dayKey(for: navigation.yearMonths.first!), "2024-01-01")
        XCTAssertEqual(navigation.dayKey(for: navigation.yearMonths.last!), "2024-12-01")
    }

    func testWeekAndDayBoundariesUseSelectedTimezoneAcrossDST() {
        let zone = "America/Los_Angeles"
        let middayOnSpringForward = date(2024, 3, 10, 12, timezoneID: zone)
        var navigation = CalendarNavigation(timezoneID: zone, anchor: middayOnSpringForward, scale: .day)

        XCTAssertEqual(navigation.period.duration, 23 * 60 * 60, accuracy: 0.01)
        XCTAssertEqual(navigation.dayKey(for: navigation.period.start), "2024-03-10")
        navigation.setScale(.week)
        XCTAssertEqual(navigation.weekDates.map { navigation.dayKey(for: $0) }, ["2024-03-10", "2024-03-11", "2024-03-12", "2024-03-13", "2024-03-14", "2024-03-15", "2024-03-16"])
    }

    func testDayKeyUsesConfiguredTimezoneRatherThanProcessTimezone() {
        let instant = Date(timeIntervalSince1970: 1_704_070_800) // 2024-01-01 01:00 UTC
        let losAngeles = CalendarNavigation(timezoneID: "America/Los_Angeles", anchor: instant)
        let tokyo = CalendarNavigation(timezoneID: "Asia/Tokyo", anchor: instant)

        XCTAssertEqual(losAngeles.dayKey(for: instant), "2023-12-31")
        XCTAssertEqual(tokyo.dayKey(for: instant), "2024-01-01")
    }

    func testTimezoneChangeRefreshesPreferredCivilDayForMonthAndYearMoves() {
        let instant = Date(timeIntervalSince1970: 1_704_070_800) // 2024-01-01 01:00 UTC
        var month = CalendarNavigation(timezoneID: "Asia/Tokyo", anchor: instant, scale: .month)
        month.timezoneID = "America/Los_Angeles"
        month.move(by: 1)
        XCTAssertEqual(month.dayKey(for: month.anchor), "2024-01-31")

        var year = CalendarNavigation(timezoneID: "Asia/Tokyo", anchor: instant, scale: .year)
        year.timezoneID = "America/Los_Angeles"
        year.move(by: 1)
        XCTAssertEqual(year.dayKey(for: year.anchor), "2024-12-31")
    }
}
