import XCTest
@testable import Stillleaf

/// The daily reminder's rule: a notification only for a day whose reading is still open.
final class ReadingReminderTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testTodayIsRemindedOnlyWhileItsGoalIsOpenAndItsTimeIsAhead() {
        let evening = 20 * 60
        let open = ReadingReminder.plan(now: at(10, 9), minutes: evening, goalReached: false, streak: 6, calendar: calendar)
        XCTAssertEqual(open.count, ReadingReminder.horizon)
        XCTAssertEqual(open.first, .init(date: at(10, 20), body: "Read today to keep your 6-day streak."))
        XCTAssertEqual(open[1], .init(date: at(11, 20), body: "Your book is where you left it."))
        XCTAssertEqual(open.last?.date, at(16, 20))

        let fresh = ReadingReminder.plan(now: at(10, 9), minutes: evening, goalReached: false, streak: 0, calendar: calendar)
        XCTAssertEqual(fresh.first?.body, "Today's reading goal is still open.")

        let reached = ReadingReminder.plan(now: at(10, 9), minutes: evening, goalReached: true, streak: 7, calendar: calendar)
        XCTAssertEqual(reached.first?.date, at(11, 20), "a day whose goal is reached is left alone")
        XCTAssertEqual(reached.count, ReadingReminder.horizon - 1)

        let late = ReadingReminder.plan(now: at(10, 20, 1), minutes: evening, goalReached: false, streak: 6, calendar: calendar)
        XCTAssertEqual(late.first?.date, at(11, 20), "a time already past is not rescheduled for today")
    }

    func testOutOfRangeTimesAreClamped() {
        let plan = ReadingReminder.plan(now: at(10, 9), minutes: 9_999, goalReached: false, streak: 0, calendar: calendar)
        XCTAssertEqual(plan.first?.date, at(10, 23, 59))
        XCTAssertEqual(ReadingReminder.plan(now: at(10, 9), minutes: -5, goalReached: true, streak: 0, calendar: calendar).first?.date, at(11, 0))
    }
}
