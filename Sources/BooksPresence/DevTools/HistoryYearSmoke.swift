import AppKit
import Foundation

private struct YearCheckError: Error, CustomStringConvertible {
    let description: String
}

/// The Year view draws every book's row in one canvas and reuses one bitmap for title-less
/// placeholder covers, so 60 rows settle quickly. These checks pin the behaviour that
/// restructuring must keep: which day a tap selects and what a shared placeholder is.
@MainActor
func checkHistoryYearRows() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    let end = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
    let period = DateInterval(start: start, end: end)
    let today = calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 9))!
    func day(_ x: CGFloat) -> Date? {
        AtlasYearView.day(atX: x, chartWidth: 500, period: period, calendar: calendar, today: today)
    }
    guard day(0) == start else { throw YearCheckError(description: "A tap at the left edge did not select January 1") }
    guard let june = day(500 * 0.45), calendar.component(.month, from: june) == 6 else {
        throw YearCheckError(description: "A tap 45% along the year did not land in June")
    }
    guard day(500 * 0.9) == nil else { throw YearCheckError(description: "A tap on a future day selected it") }
    guard day(-40) == start else { throw YearCheckError(description: "A tap left of the chart did not clamp to January 1") }
    let farRight = AtlasYearView.day(atX: 9_000, chartWidth: 500, period: period, calendar: calendar,
                                     today: calendar.date(from: DateComponents(year: 2027, month: 6, day: 1))!)
    guard farRight == calendar.date(from: DateComponents(year: 2026, month: 12, day: 31)) else {
        throw YearCheckError(description: "A tap right of the chart did not clamp to December 31")
    }
    guard AtlasYearView.rowHeight == 76 else { throw YearCheckError(description: "Year rows are no longer 76 pt tall") }

    let size = CGSize(width: 52, height: 72)
    let first = CoverPlaceholder.image(size: size)
    guard first.size == size, first === CoverPlaceholder.image(size: size) else {
        throw YearCheckError(description: "A title-less placeholder cover was redrawn instead of reused")
    }
    guard CoverPlaceholder.image(size: CGSize(width: 62, height: 88)) !== first else {
        throw YearCheckError(description: "Different cover sizes shared one placeholder bitmap")
    }
    print("ui-smoke: history year taps map to the right day, and placeholder covers are drawn once per size")
}
