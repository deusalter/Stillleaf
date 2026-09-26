import SwiftUI
import BooksCore

@MainActor
struct AtlasDayView: View {
    @ObservedObject var model: AppModel
    let navigation: CalendarNavigation
    let review: (ReadingInterval) -> Void
    @State private var selectedBook: String?
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var period: DateInterval { navigation.period }
    private var slices: [AtlasTimeSlice] { HistoryAtlas.slices(intervals: model.intervals, merges: model.merges, period: period) }
    private var sessions: [ReadingSessionGroup] {
        model.readingSessions.filter { $0.end > period.start && $0.start < period.end }.sorted { $0.start < $1.start }
    }
    var body: some View {
        let evidence = slices
        let bookIDs = Array(Set(evidence.filter { $0.interval.disposition != .excluded }.map(\.bookID))).sorted {
            title($0).localizedStandardCompare(title($1)) == .orderedAscending
        }
        VStack(alignment: .leading, spacing: 26) {
            if bookIDs.isEmpty {
                AtlasPanel(title: "No reading recorded") {
                    Text("Choose another day to explore your history.").font(.callout).foregroundStyle(AtlasStyle.muted(dark))
                }
            } else {
                AtlasPanel(title: "Session map", note: "Local time") {
                    AtlasDayLanes(model: model, navigation: navigation, slices: HistoryAtlas.slices(intervals: model.displayIntervals, merges: model.merges, period: period), bookIDs: bookIDs) { selectedBook = $0 }
                    if evidence.contains(where: { $0.interval.disposition == .uncertain }) {
                        Text("Outlined spans await review and are excluded from recorded-time totals.")
                            .font(.caption).foregroundStyle(AtlasStyle.muted(dark))
                    }
                }
                HStack {
                    Text(selectedBook.map { title($0) } ?? "Sessions").font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if selectedBook != nil { Button("All books") { selectedBook = nil }.buttonStyle(AtlasButtonStyle()) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 24, alignment: .top)], alignment: .leading, spacing: 24) {
                    ForEach(sessions.filter { selectedBook == nil || $0.bookID == selectedBook }) { session in
                        AtlasSessionCard(model: model, session: session, period: period, review: review)
                    }
                }
            }
            let excluded = evidence.filter { $0.interval.disposition == .excluded }
            if !excluded.isEmpty {
                DisclosureGroup("Excluded records (\(excluded.count))") {
                    ForEach(excluded) { slice in
                        HStack {
                            Text(title(slice.bookID)).font(.callout)
                            Spacer()
                            Text(ReadingFormat.duration(slice.seconds)).font(.caption)
                            Button("Review") { review(slice.interval) }.buttonStyle(AtlasButtonStyle())
                        }.padding(.vertical, 5)
                    }
                }.font(.caption).foregroundStyle(AtlasStyle.muted(dark))
            }
        }
    }
    private func title(_ id: String) -> String { model.books.first { $0.id == id }?.title ?? "Unknown book" }
}

@MainActor
private struct AtlasDayLanes: View {
    let model: AppModel
    let navigation: CalendarNavigation
    let slices: [AtlasTimeSlice]
    let bookIDs: [String]
    let select: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var plot: DateInterval {
        let six = navigation.calendar.date(bySettingHour: 6, minute: 0, second: 0, of: navigation.periodStart) ?? navigation.periodStart
        let first = slices.map(\.start).min() ?? six
        return DateInterval(start: first < six ? navigation.period.start : six, end: navigation.period.end)
    }
    private var ticks: [Date] {
        var output: [Date] = [], cursor = plot.start
        while cursor <= plot.end {
            output.append(cursor)
            cursor = navigation.calendar.date(byAdding: .hour, value: 3, to: cursor) ?? plot.end.addingTimeInterval(1)
        }
        if output.last != plot.end { output.append(plot.end) }
        return output
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Color.clear.frame(width: 130, height: 24)
                GeometryReader { geo in
                    ForEach(Array(ticks.enumerated()), id: \.offset) { index, date in
                        Text(AtlasStyle.date(date, zone: model.timezoneID, pattern: "ha"))
                            .font(.system(size: 10)).foregroundStyle(AtlasStyle.muted(dark))
                            .position(x: min(geo.size.width - 18, max(18, x(date, width: geo.size.width))), y: 10)
                            .opacity(geo.size.width < 420 && index % 2 == 1 ? 0 : 1)
                    }
                }.frame(height: 24).accessibilityHidden(true)
            }
            ForEach(bookIDs, id: \.self) { id in
                let row = slices.filter { $0.bookID == id && $0.interval.disposition != .excluded }
                let credited = row.filter { $0.interval.disposition == .credited }.reduce(0) { $0 + $1.seconds }
                let awaiting = row.filter { $0.interval.disposition == .uncertain }.reduce(0) { $0 + $1.seconds }
                Button { select(id) } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.books.first { $0.id == id }?.title ?? "Unknown book")
                                .font(.callout.weight(.medium)).lineLimit(3)
                            Text(ReadingFormat.duration(credited)).font(.caption).foregroundStyle(AtlasStyle.muted(dark))
                        }.frame(width: 130, alignment: .leading)
                        Canvas { context, size in
                            for tick in ticks {
                                var path = Path(); let position = x(tick, width: size.width)
                                path.move(to: CGPoint(x: position, y: 0)); path.addLine(to: CGPoint(x: position, y: size.height))
                                context.stroke(path, with: .color(AtlasStyle.rule(dark)), lineWidth: 0.6)
                            }
                            var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: 35)); baseline.addLine(to: CGPoint(x: size.width, y: 35))
                            context.stroke(baseline, with: .color(AtlasStyle.rule(dark)), lineWidth: 1)
                            for slice in row {
                                let start = x(slice.start, width: size.width)
                                let width = min(size.width - start, max(2, x(slice.end, width: size.width) - start))
                                let rect = CGRect(x: start, y: 23, width: width, height: 24)
                                let mark = Path(roundedRect: rect, cornerRadius: 5)
                                if slice.interval.disposition == .credited { context.fill(mark, with: .color(AtlasStyle.book(id, dark: dark))) }
                                else { context.stroke(mark, with: .color(AtlasStyle.book(id, dark: dark)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])) }
                            }
                        }.frame(height: 76).accessibilityHidden(true)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityLabel("\(model.books.first { $0.id == id }?.title ?? "Unknown book"), \(ReadingFormat.duration(credited)) recorded, \(ReadingFormat.duration(awaiting)) awaiting review. Show sessions.")
                .help("Show sessions for this book. Short spans have a minimum two-point hit mark; session detail shows exact time.")
            }
        }
    }
    private func x(_ date: Date, width: CGFloat) -> CGFloat { CGFloat(date.timeIntervalSince(plot.start) / max(1, plot.duration)) * width }
}

@MainActor
private struct AtlasSessionCard: View {
    @ObservedObject var model: AppModel
    let session: ReadingSessionGroup
    let period: DateInterval
    let review: (ReadingInterval) -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var evidence: [AtlasTimeSlice] { HistoryAtlas.slices(intervals: session.intervals, merges: model.merges, period: period) }
    var body: some View {
        let parts = evidence
        let credited = parts.filter { $0.interval.disposition == .credited }.reduce(0) { $0 + $1.seconds }
        let uncertain = parts.filter { $0.interval.disposition == .uncertain }.reduce(0) { $0 + $1.seconds }
        let pages = model.pages(in: session, from: period.start, through: period.end)
        let listening = session.intervals.contains { model.isListening($0) }
        VStack(alignment: .leading, spacing: 15) {
            Rectangle().fill(AtlasStyle.rule(dark)).frame(height: 1).accessibilityHidden(true)
            Text("\(time(max(session.start, period.start))) – \(time(min(session.end, period.end)))")
                .font(.caption).foregroundStyle(AtlasStyle.muted(dark))
            AtlasBookLabel(model: model, id: session.bookID)
            HStack(spacing: 12) {
                if pages > 0 { Text("\(pages) pages").font(.callout.weight(.medium)) }
                Text("\(ReadingFormat.duration(credited)) \(listening ? "listening" : "recorded")").font(.caption)
            }
            if uncertain > 0 { Text("\(ReadingFormat.duration(uncertain)) awaiting review").font(.caption).foregroundStyle(AtlasStyle.muted(dark)) }
            if let position = HistoryAtlas.audioPosition(in: session, observations: model.progress, during: period) {
                Text("Position \(position.description)").font(.caption).foregroundStyle(AtlasStyle.muted(dark))
            }
            let manual = model.manualPages(in: session, from: period.start, through: period.end)
            if manual > 0 { Text("Includes \(manual) manually added pages").font(.caption).foregroundStyle(AtlasStyle.muted(dark)) }
            DisclosureGroup("Session details") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(parts) { slice in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(time(slice.start)) – \(time(slice.end))")
                                Text("\(ReadingFormat.duration(slice.seconds)) · \(slice.interval.disposition == .credited ? "Credited" : "Awaiting review")")
                            }.font(.caption).foregroundStyle(AtlasStyle.muted(dark))
                            Spacer(minLength: 0)
                            Button("Review") { review(slice.interval) }.buttonStyle(AtlasButtonStyle())
                        }
                    }
                }.padding(.top, 12)
            }.font(.caption).tint(AtlasStyle.accent(dark))
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func time(_ date: Date) -> String { AtlasStyle.date(date, zone: model.timezoneID, pattern: "h:mm a z") }
}
