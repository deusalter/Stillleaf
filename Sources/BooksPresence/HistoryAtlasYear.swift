import SwiftUI
import BooksCore

@MainActor
struct AtlasYearView: View {
    static let rowHeight: CGFloat = 76
    static let labelWidth: CGFloat = 170
    static let totalsWidth: CGFloat = 74
    static let columnSpacing: CGFloat = 16
    let navigation: CalendarNavigation
    let presentation: HistoryAtlasPeriod
    let select: (Date) -> Void
    let selectMonth: (Date) -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    var body: some View {
        let period = navigation.period
        let calendar = navigation.calendar
        let rows = presentation.yearRows
        return AtlasPanel(title: "Your year in books", note: "Recorded days and finishes") {
            if rows.isEmpty {
                Text("No reading or finished books recorded in this year.").font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                monthLinks
            } else {
                // A horizontal canvas preserves month labels and day hit targets in small
                // windows. The rest of the History page still follows the window width.
                GeometryReader { geometry in
                  let canvasWidth = max(730, geometry.size.width)
                  // Every row shares the same fixed label, totals and spacing.
                  // Resolve its plot width once instead of measuring each row.
                  let chartWidth = canvasWidth - Self.labelWidth - Self.totalsWidth - 2 * Self.columnSpacing
                  ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        HStack(spacing: Self.columnSpacing) {
                            Color.clear.frame(width: Self.labelWidth, height: 28)
                            monthLinks.frame(width: chartWidth)
                            Color.clear.frame(width: Self.totalsWidth, height: 28)
                        }
                        // Three columns of fixed-height rows, with every book's chart drawn by
                        // one canvas: sixty canvases and tap gestures cost far more to lay out.
                        HStack(alignment: .top, spacing: Self.columnSpacing) {
                            VStack(spacing: 0) {
                                ForEach(rows) { row in label(row).frame(width: Self.labelWidth, height: Self.rowHeight, alignment: .leading) }
                            }
                            chart(rows, period: period, calendar: calendar, chartWidth: chartWidth)
                            VStack(spacing: 0) {
                                ForEach(rows) { row in totals(row).frame(width: Self.totalsWidth, height: Self.rowHeight, alignment: .trailing) }
                            }
                        }
                    }.frame(width: canvasWidth)
                  }
                }.frame(height: CGFloat(rows.count) * Self.rowHeight + 32)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { legend }
                    VStack(alignment: .leading, spacing: 9) { legend }
                }
            }
        }
    }
    @ViewBuilder private var legend: some View {
        Label("Recorded day", systemImage: "rectangle.fill").font(.caption)
        Label("Finished", systemImage: "diamond.fill").font(.caption)
        Text("Faint spans connect a book’s first and latest session.").font(.caption2).foregroundStyle(ReadingPalette.secondaryInk)
    }
    private var monthLinks: some View {
        HStack(spacing: 0) {
            ForEach(navigation.yearMonths, id: \.self) { month in
                Button { selectMonth(month) } label: {
                    Text(DateText.string(month, zone: navigation.timezoneID, pattern: "MMM"))
                        .font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }.buttonStyle(.plain).disabled(month > Date())
                    .accessibilityLabel("Open \(DateText.string(month, zone: navigation.timezoneID, pattern: "MMMM yyyy"))")
            }
        }.foregroundStyle(ReadingPalette.secondaryInk)
    }
    private func label(_ row: AtlasYearRow) -> some View {
        let id = row.id, activity = row.activity
        let seconds = row.creditedSeconds, pages = row.pages, finished = row.finishes
        return RecordedDateMenu(dates: row.recordedDates, timezoneID: navigation.timezoneID,
                                bookTitle: title(id), select: select) {
            HStack(spacing: 10) {
                BookCoverView(book: presentation.booksByID[id], size: .compact)
                    .scaleEffect(0.62).frame(width: 33, height: 46)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title(id)).font(.system(size: 13, weight: .medium)).lineLimit(3)
                        .multilineTextAlignment(.leading)
                    RecordedDateMenuCaption(count: row.recordedDates.count)
                }
            }.frame(width: Self.labelWidth, alignment: .leading)
        }
        .accessibilityValue("\(activity.count) recorded days, \(pages) pages, \(ReadingFormat.duration(seconds)) recorded. \(finished.isEmpty ? "" : "Finished this year.")")
    }

    private func totals(_ row: AtlasYearRow) -> some View {
        let seconds = row.creditedSeconds, pages = row.pages, finished = row.finishes
        return VStack(alignment: .trailing, spacing: 5) {
            if pages > 0 {
                Text(pages.formatted()).font(.callout.weight(.medium)); Text("pages").font(.caption2)
            } else if seconds > 0 {
                Text(ReadingFormat.duration(seconds)).font(.callout.weight(.medium)); Text("recorded").font(.caption2)
            } else { Text(finished.isEmpty ? "—" : "Finished").font(.caption) }
        }.foregroundStyle(ReadingPalette.secondaryInk)
    }

    /// The day a tap at `x` selects, or nil for a day that has not happened yet.
    static func day(atX x: CGFloat, chartWidth: CGFloat, period: DateInterval, calendar: Calendar, today: Date) -> Date? {
        let fraction = min(0.999999, max(0, x / max(1, chartWidth)))
        let day = calendar.startOfDay(for: period.start.addingTimeInterval(period.duration * fraction))
        return day <= calendar.startOfDay(for: today) ? day : nil
    }

    private func chart(_ rows: [AtlasYearRow], period: DateInterval, calendar: Calendar, chartWidth: CGFloat) -> some View {
        let colors = rows.map { AtlasStyle.book($0.id, dark: dark) }
        let border = ReadingPalette.border
        let monthPositions = presentation.monthPositions
        return Canvas { context, size in
            for (index, row) in rows.enumerated() {
                var rowContext = context
                rowContext.translateBy(x: 0, y: CGFloat(index) * Self.rowHeight)
                Self.draw(row, color: colors[index], border: border, monthPositions: monthPositions, in: &rowContext, width: size.width)
            }
        }
        .frame(width: chartWidth, height: CGFloat(rows.count) * Self.rowHeight)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { event in
            if let day = Self.day(atX: event.location.x, chartWidth: chartWidth, period: period, calendar: calendar, today: Date()) { select(day) }
        })
        .accessibilityHidden(true)
    }

    private static func draw(_ row: AtlasYearRow, color: Color, border: Color, monthPositions: [Double], in context: inout GraphicsContext, width: CGFloat) {
        for fraction in monthPositions {
            let x = CGFloat(fraction) * width
            var path = Path(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: rowHeight))
            context.stroke(path, with: .color(border), lineWidth: 0.6)
        }
        let activity = row.activity
        if let first = activity.first, let last = activity.last {
            let start = CGFloat(first.start) * width, end = CGFloat(last.start) * width
            context.fill(Path(roundedRect: CGRect(x: start, y: 37, width: max(2, end - start), height: 7), cornerRadius: 3), with: .color(color.opacity(0.18)))
        }
        for mark in activity {
            let start = CGFloat(mark.start) * width
            context.fill(Path(CGRect(x: start, y: 30, width: max(1, CGFloat(mark.end - mark.start) * width - 0.3), height: 21)), with: .color(color))
        }
        for fraction in row.finishes {
            let x = CGFloat(fraction) * width
            var diamond = Path(); diamond.move(to: CGPoint(x: x, y: 17)); diamond.addLine(to: CGPoint(x: x + 5, y: 22))
            diamond.addLine(to: CGPoint(x: x, y: 27)); diamond.addLine(to: CGPoint(x: x - 5, y: 22)); diamond.closeSubpath()
            context.fill(diamond, with: .color(color))
        }
    }
    private func title(_ id: String) -> String { presentation.booksByID[id]?.title ?? "Unknown book" }
}
