import SwiftUI
import BooksCore

@MainActor
struct AtlasYearView: View {
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
                  let chartWidth = canvasWidth - 170 - 74 - 2 * 16
                  ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        HStack(spacing: 16) {
                            Color.clear.frame(width: 170, height: 28)
                            monthLinks.frame(width: chartWidth)
                            Color.clear.frame(width: 74, height: 28)
                        }
                        ForEach(rows) { row in yearRow(row, period: period, calendar: calendar, chartWidth: chartWidth) }
                    }.frame(width: canvasWidth)
                  }
                }.frame(height: CGFloat(rows.count) * 76 + 32)
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
    private func yearRow(_ row: AtlasYearRow, period: DateInterval, calendar: Calendar, chartWidth: CGFloat) -> some View {
        let id = row.id, activity = row.activity
        let seconds = row.creditedSeconds, pages = row.pages, finished = row.finishes
        return HStack(spacing: 16) {
            RecordedDateMenu(dates: row.recordedDates, timezoneID: navigation.timezoneID,
                             bookTitle: title(id), select: select) {
                HStack(spacing: 10) {
                    BookCoverView(book: presentation.booksByID[id], size: .compact)
                        .scaleEffect(0.62).frame(width: 33, height: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title(id)).font(.system(size: 13, weight: .medium)).lineLimit(3)
                            .multilineTextAlignment(.leading)
                        RecordedDateMenuCaption(count: row.recordedDates.count)
                    }
                }.frame(width: 170, alignment: .leading)
            }
            .accessibilityValue("\(activity.count) recorded days, \(pages) pages, \(ReadingFormat.duration(seconds)) recorded. \(finished.isEmpty ? "" : "Finished this year.")")
            Canvas { context, size in
                for fraction in presentation.monthPositions {
                    let x = CGFloat(fraction) * size.width
                    var path = Path(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(ReadingPalette.border), lineWidth: 0.6)
                }
                let color = AtlasStyle.book(id, dark: dark)
                if let first = activity.first, let last = activity.last {
                    let start = CGFloat(first.start) * size.width, end = CGFloat(last.start) * size.width
                    context.fill(Path(roundedRect: CGRect(x: start, y: 37, width: max(2, end - start), height: 7), cornerRadius: 3), with: .color(color.opacity(0.18)))
                }
                for mark in activity {
                    let start = CGFloat(mark.start) * size.width
                    context.fill(Path(CGRect(x: start, y: 30, width: max(1, CGFloat(mark.end - mark.start) * size.width - 0.3), height: 21)), with: .color(color))
                }
                for fraction in finished {
                    let x = CGFloat(fraction) * size.width
                    var diamond = Path(); diamond.move(to: CGPoint(x: x, y: 17)); diamond.addLine(to: CGPoint(x: x + 5, y: 22))
                    diamond.addLine(to: CGPoint(x: x, y: 27)); diamond.addLine(to: CGPoint(x: x - 5, y: 22)); diamond.closeSubpath()
                    context.fill(diamond, with: .color(color))
                }
            }
            .frame(width: chartWidth, height: 76)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { event in
                let fraction = min(0.999999, max(0, event.location.x / max(1, chartWidth)))
                let date = period.start.addingTimeInterval(period.duration * fraction)
                let day = calendar.startOfDay(for: date)
                if day <= calendar.startOfDay(for: Date()) { select(day) }
            })
            .accessibilityHidden(true)
            VStack(alignment: .trailing, spacing: 5) {
                if pages > 0 {
                    Text(pages.formatted()).font(.callout.weight(.medium)); Text("pages").font(.caption2)
                } else if seconds > 0 {
                    Text(ReadingFormat.duration(seconds)).font(.callout.weight(.medium)); Text("recorded").font(.caption2)
                } else { Text(finished.isEmpty ? "—" : "Finished").font(.caption) }
            }.foregroundStyle(ReadingPalette.secondaryInk).frame(width: 74, alignment: .trailing)
        }.frame(height: 76)
    }
    private func title(_ id: String) -> String { presentation.booksByID[id]?.title ?? "Unknown book" }
}
