import Foundation
import BooksCore

struct CalendarCheckFailure: Error { let description: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CalendarCheckFailure(description: message) }
}
func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

do {
    var month = CalendarNavigation(timezoneID: "America/Los_Angeles", anchor: date("2024-02-15T20:00:00Z"))
    try require(month.monthCells.filter(\.isInMonth).count == 29, "Leap February must have 29 days")
    try require(month.monthCells.count <= 42 && month.monthCells.count % 7 == 0, "Month must display aligned complete weeks")
    try require(month.calendar.component(.weekday, from: month.monthCells[0].date) == month.calendar.firstWeekday, "Month weekday alignment")
    let selected = month.anchor
    for scale in CalendarScale.allCases {
        month.setScale(scale)
        try require(month.anchor == selected, "Changing scale must retain selection")
    }
    try require(month.yearMonths.count == 12, "Year must have 12 months")
    month.select(date("2024-03-10T20:00:00Z"), scale: .day)
    try require(month.period.duration == 23 * 3600, "Spring DST day must have 23 hours")
    month.select(date("2024-11-03T20:00:00Z"), scale: .day)
    try require(month.period.duration == 25 * 3600, "Fall DST day must have 25 hours")
    month.select(date("2024-12-31T20:00:00Z"), scale: .month)
    month.move(by: 1)
    try require(month.dayKey(for: month.anchor) == "2025-01-31", "Month navigation must cross year correctly")
    month.setScale(.week)
    try require(month.weekDates.count == 7 && month.weekDates.allSatisfy { $0 >= month.period.start && $0 < month.period.end }, "Week must contain exactly seven local dates")
    let instant = date("2024-02-01T01:00:00Z")
    let west = CalendarNavigation(timezoneID: "America/Los_Angeles", anchor: instant)
    let east = CalendarNavigation(timezoneID: "Asia/Tokyo", anchor: instant)
    try require(west.dayKey(for: instant) == "2024-01-31" && east.dayKey(for: instant) == "2024-02-01", "Calendar must use selected timezone")
    var clamped = CalendarNavigation(timezoneID: "UTC", anchor: date("2024-01-31T12:00:00Z"))
    clamped.move(by: 1)
    clamped.timezoneID = "UTC"
    clamped.move(by: 1)
    try require(clamped.dayKey(for: clamped.anchor) == "2024-03-31", "Routine timezone assignment must not lose preferred month day")
    var relocated = CalendarNavigation(timezoneID: "Asia/Tokyo", anchor: date("2024-01-01T01:00:00Z"))
    relocated.timezoneID = "America/Los_Angeles"
    relocated.move(by: 1)
    try require(relocated.dayKey(for: relocated.anchor) == "2024-01-31", "Timezone change must update displayed civil day for navigation")
    print("calendar-smoke: month boundaries, leap year, zoom anchor, DST, week/year and timezone checks passed")
} catch {
    fputs("calendar-smoke failed: \(error)\n", stderr)
    exit(1)
}
