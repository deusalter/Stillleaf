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
    private var resolver: BookMergeResolver { BookMergeResolver(merges: model.merges) }
    private var completions: [(id: String, date: Date)] {
        model.finishedBooks.compactMap { entry in
            guard let date = entry.finishedAt, date >= navigation.period.start, date < navigation.period.end, date <= Date() else { return nil }
            return (resolver.resolvedID(for: entry.id), date)
        }
    }
    private var bookIDs: [String] {
        let ids = Set(days.flatMap { $0.books.map(\.bookID) } + completions.map(\.id))
        return ids.sorted { lhs, rhs in
            let left = firstDate(lhs), right = firstDate(rhs)
            if left != right { return left < right }
            return title(lhs).localizedStandardCompare(title(rhs)) == .orderedAscending
        }
    }
    var body: some View {
        AtlasPanel(title: "Your year in books", note: "Recorded days and finishes") {
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
                        ForEach(bookIDs, id: \.self) { id in yearRow(id) }
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
    private func yearRow(_ id: String) -> some View {
        let activity = days.filter { day in day.books.contains { $0.bookID == id && $0.creditedSeconds > 0 } }
        let pending = days.filter { day in day.books.contains { $0.bookID == id && $0.uncertainSeconds > 0 } }
        let times = days.flatMap(\.books).filter { $0.bookID == id }
        let seconds = times.reduce(0) { $0 + $1.creditedSeconds }
        let pages = model.pages(forBookID: id, from: navigation.period.start, through: navigation.period.end)
        let finished = completions.filter { $0.id == id }.map(\.date)
        let target = activity.last?.date ?? pending.last?.date ?? finished.first.map { navigation.calendar.startOfDay(for: $0) } ?? navigation.periodStart
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
                    for month in navigation.yearMonths {
                        let x = position(month, width: size.width)
                        var path = Path(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(path, with: .color(AtlasStyle.rule(dark)), lineWidth: 0.6)
                    }
                    let color = AtlasStyle.book(id, dark: dark)
                    if let first = activity.first, let last = activity.last {
                        let start = position(first.date, width: size.width), end = position(last.date, width: size.width)
                        context.fill(Path(roundedRect: CGRect(x: start, y: 37, width: max(2, end - start), height: 7), cornerRadius: 3), with: .color(color.opacity(0.18)))
                    }
                    for day in activity {
                        let next = navigation.calendar.date(byAdding: .day, value: 1, to: day.date) ?? day.date
                        let start = position(day.date, width: size.width)
                        context.fill(Path(CGRect(x: start, y: 30, width: max(1, position(next, width: size.width) - start - 0.3), height: 21)), with: .color(color))
                    }
                    for day in pending where !activity.contains(where: { $0.key == day.key }) {
                        let x = position(day.date, width: size.width)
                        context.stroke(Path(CGRect(x: x, y: 32, width: 2, height: 17)), with: .color(color.opacity(0.7)), lineWidth: 0.7)
                    }
                    for date in finished {
                        let x = position(date, width: size.width)
                        var diamond = Path(); diamond.move(to: CGPoint(x: x, y: 17)); diamond.addLine(to: CGPoint(x: x + 5, y: 22))
                        diamond.addLine(to: CGPoint(x: x, y: 27)); diamond.addLine(to: CGPoint(x: x - 5, y: 22)); diamond.closeSubpath()
                        context.fill(diamond, with: .color(color))
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { event in
                    let fraction = min(0.999999, max(0, event.location.x / max(1, geometry.size.width)))
                    let date = navigation.period.start.addingTimeInterval(navigation.period.duration * fraction)
                    let day = navigation.calendar.startOfDay(for: date)
                    if day <= navigation.calendar.startOfDay(for: Date()) { select(day) }
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
    private func position(_ date: Date, width: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(navigation.period.start) / max(1, navigation.period.duration)) * width
    }
    private func firstDate(_ id: String) -> Date {
        let recorded = days.first { $0.books.contains { $0.bookID == id } }?.date
        return min(recorded ?? .distantFuture, completions.filter { $0.id == id }.map(\.date).min() ?? .distantFuture)
    }
    private func title(_ id: String) -> String { model.books.first { $0.id == id }?.title ?? "Unknown book" }
}
