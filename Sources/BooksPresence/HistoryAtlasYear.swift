import SwiftUI
import BooksCore

@MainActor
struct AtlasYearView: View {
    @ObservedObject var model: AppModel
    let navigation: CalendarNavigation
    let days: [AtlasDay]
    let select: (Date) -> Void
    let selectMonth: (Date) -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private func completions(in period: DateInterval) -> [(id: String, date: Date)] {
        let resolver = BookMergeResolver(merges: model.merges)
        let now = Date()
        return model.finishedBooks.compactMap { entry in
            guard let date = entry.finishedAt, date >= period.start, date < period.end, date <= now else { return nil }
            return (resolver.resolvedID(for: entry.id), date)
        }
    }
    private func bookIDs(completions: [(id: String, date: Date)]) -> [String] {
        var firstDates: [String: Date] = [:]
        for day in days {
            for book in day.books { firstDates[book.bookID] = min(firstDates[book.bookID] ?? .distantFuture, day.date) }
        }
        for entry in completions { firstDates[entry.id] = min(firstDates[entry.id] ?? .distantFuture, entry.date) }
        return firstDates.keys.sorted { lhs, rhs in
            let left = firstDates[lhs]!, right = firstDates[rhs]!
            if left != right { return left < right }
            return title(lhs).localizedStandardCompare(title(rhs)) == .orderedAscending
        }
    }
    var body: some View {
        let period = navigation.period
        let calendar = navigation.calendar
        let months = navigation.yearMonths
        let finished = completions(in: period)
        let bookIDs = bookIDs(completions: finished)
        return AtlasPanel(title: "Your year in books", note: "Recorded days and finishes") {
            if bookIDs.isEmpty {
                Text("No reading or finished books recorded in this year.").font(.callout).foregroundStyle(AtlasStyle.muted(dark))
                monthLinks
            } else {
                // A horizontal canvas preserves month labels and day hit targets in small
                // windows. The rest of the History page still follows the window width.
                GeometryReader { geometry in
                  ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        HStack(spacing: 16) {
                            Color.clear.frame(width: 170, height: 28)
                            monthLinks.frame(minWidth: 440)
                            Color.clear.frame(width: 74, height: 28)
                        }
                        ForEach(bookIDs, id: \.self) { id in yearRow(id, period: period, calendar: calendar, months: months, completions: finished) }
                    }.frame(width: max(730, geometry.size.width))
                  }
                }.frame(height: CGFloat(bookIDs.count) * 76 + 32)
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
        if days.contains(where: { $0.uncertainSeconds > 0 }) { Label("Awaiting review", systemImage: "rectangle.dashed").font(.caption) }
        Text("Faint spans connect a book’s first and latest session.").font(.caption2).foregroundStyle(AtlasStyle.muted(dark))
    }
    private var monthLinks: some View {
        HStack(spacing: 0) {
            ForEach(navigation.yearMonths, id: \.self) { month in
                Button { selectMonth(month) } label: {
                    Text(AtlasStyle.date(month, zone: model.timezoneID, pattern: "MMM"))
                        .font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }.buttonStyle(.plain).disabled(month > Date())
                    .accessibilityLabel("Open \(AtlasStyle.date(month, zone: model.timezoneID, pattern: "MMMM yyyy"))")
            }
        }.foregroundStyle(AtlasStyle.muted(dark))
    }
    private func yearRow(_ id: String, period: DateInterval, calendar: Calendar, months: [Date], completions: [(id: String, date: Date)]) -> some View {
        let activity = days.filter { day in day.books.contains { $0.bookID == id && $0.creditedSeconds > 0 } }
        let pending = days.filter { day in day.books.contains { $0.bookID == id && $0.uncertainSeconds > 0 } }
        let times = days.flatMap(\.books).filter { $0.bookID == id }
        let seconds = times.reduce(0) { $0 + $1.creditedSeconds }
        let pages = model.pages(forBookID: id, from: period.start, through: period.end)
        let finished = completions.filter { $0.id == id }.map(\.date)
        let target = activity.last?.date ?? pending.last?.date ?? finished.first.map { calendar.startOfDay(for: $0) } ?? navigation.periodStart
        return HStack(spacing: 16) {
            Button { select(target) } label: {
                HStack(spacing: 10) {
                    BookCoverView(book: model.books.first { $0.id == id }, size: .compact)
                        .scaleEffect(0.62).frame(width: 33, height: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title(id)).font(.system(size: 13, weight: .medium)).lineLimit(3)
                        Text("\(activity.count) \(activity.count == 1 ? "day" : "days")").font(.caption2).foregroundStyle(AtlasStyle.muted(dark))
                    }
                }.frame(width: 170, alignment: .leading)
            }.buttonStyle(.plain)
                .accessibilityLabel("\(title(id)), \(activity.count) recorded days, \(pages) pages, \(ReadingFormat.duration(seconds)) recorded. \(finished.isEmpty ? "" : "Finished this year.") Open latest day.")
            GeometryReader { geometry in
                Canvas { context, size in
                    for month in months {
                        let x = position(month, width: size.width, period: period)
                        var path = Path(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(path, with: .color(AtlasStyle.rule(dark)), lineWidth: 0.6)
                    }
                    let color = AtlasStyle.book(id, dark: dark)
                    if let first = activity.first, let last = activity.last {
                        let start = position(first.date, width: size.width, period: period), end = position(last.date, width: size.width, period: period)
                        context.fill(Path(roundedRect: CGRect(x: start, y: 37, width: max(2, end - start), height: 7), cornerRadius: 3), with: .color(color.opacity(0.18)))
                    }
                    for day in activity {
                        let next = calendar.date(byAdding: .day, value: 1, to: day.date) ?? day.date
                        let start = position(day.date, width: size.width, period: period)
                        context.fill(Path(CGRect(x: start, y: 30, width: max(1, position(next, width: size.width, period: period) - start - 0.3), height: 21)), with: .color(color))
                    }
                    for day in pending where !activity.contains(where: { $0.key == day.key }) {
                        let x = position(day.date, width: size.width, period: period)
                        context.stroke(Path(CGRect(x: x, y: 32, width: 2, height: 17)), with: .color(color.opacity(0.7)), lineWidth: 0.7)
                    }
                    for date in finished {
                        let x = position(date, width: size.width, period: period)
                        var diamond = Path(); diamond.move(to: CGPoint(x: x, y: 17)); diamond.addLine(to: CGPoint(x: x + 5, y: 22))
                        diamond.addLine(to: CGPoint(x: x, y: 27)); diamond.addLine(to: CGPoint(x: x - 5, y: 22)); diamond.closeSubpath()
                        context.fill(diamond, with: .color(color))
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { event in
                    let fraction = min(0.999999, max(0, event.location.x / max(1, geometry.size.width)))
                    let date = period.start.addingTimeInterval(period.duration * fraction)
                    let day = calendar.startOfDay(for: date)
                    if day <= calendar.startOfDay(for: Date()) { select(day) }
                })
                .accessibilityHidden(true)
            }.frame(minWidth: 440, minHeight: 76)
            VStack(alignment: .trailing, spacing: 5) {
                if pages > 0 {
                    Text(pages.formatted()).font(.callout.weight(.medium)); Text("pages").font(.caption2)
                } else if seconds > 0 {
                    Text(ReadingFormat.duration(seconds)).font(.callout.weight(.medium)); Text("recorded").font(.caption2)
                } else { Text(finished.isEmpty ? "Review" : "Finished").font(.caption) }
            }.foregroundStyle(AtlasStyle.muted(dark)).frame(width: 74, alignment: .trailing)
        }.frame(height: 76)
    }
    private func position(_ date: Date, width: CGFloat, period: DateInterval) -> CGFloat {
        CGFloat(date.timeIntervalSince(period.start) / max(1, period.duration)) * width
    }
    private func title(_ id: String) -> String { model.books.first { $0.id == id }?.title ?? "Unknown book" }
}
