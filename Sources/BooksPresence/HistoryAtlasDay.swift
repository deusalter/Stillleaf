import SwiftUI
import BooksCore

@MainActor
struct AtlasDayView: View {
    let navigation: CalendarNavigation
    let presentation: HistoryAtlasPeriod
    let editSession: (ReadingInterval) -> Void
    @State private var selectedBook: String?
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var period: DateInterval { navigation.period }
    var body: some View {
        let evidence = presentation.slices
        let bookIDs = presentation.dayBookIDs
        VStack(alignment: .leading, spacing: 26) {
            if bookIDs.isEmpty {
                AtlasPanel(title: "No reading recorded") {
                    Text("Choose another day to explore your history.").font(.callout).foregroundStyle(AtlasStyle.muted(dark))
                }
            } else {
                AtlasPanel(title: "Session map", note: "Local time") {
                    AtlasDayLanes(booksByID: presentation.booksByID, navigation: navigation, slicesByBook: presentation.displaySlicesByBook,
                        firstSliceStart: presentation.displayStart, bookIDs: bookIDs) { selectedBook = $0 }
                }
                HStack {
                    Text(selectedBook.map { title($0) } ?? "Sessions").font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if selectedBook != nil { Button("All books") { selectedBook = nil }.buttonStyle(AtlasButtonStyle()) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 24, alignment: .top)], alignment: .leading, spacing: 24) {
                    ForEach(presentation.sessions.filter { selectedBook == nil || $0.session.bookID == selectedBook }) { session in
                        AtlasSessionCard(booksByID: presentation.booksByID, timezoneID: navigation.timezoneID, presentation: session, period: period, editSession: editSession)
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
                            Button("Edit") { editSession(slice.interval) }.buttonStyle(AtlasButtonStyle())
                        }.padding(.vertical, 5)
                    }
                }.font(.caption).foregroundStyle(AtlasStyle.muted(dark))
            }
        }
        .onChange(of: presentation.key.revision) { _ in
            if let selectedBook, !presentation.dayBookIDs.contains(selectedBook) { self.selectedBook = nil }
        }
    }
    private func title(_ id: String) -> String { presentation.booksByID[id]?.title ?? "Unknown book" }
}

@MainActor
private struct AtlasDayLanes: View {
    let booksByID: [String: BookRecord]
    let navigation: CalendarNavigation
    let slicesByBook: [String: [AtlasTimeSlice]]
    let firstSliceStart: Date?
    let bookIDs: [String]
    let select: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private func plot(in calendar: Calendar, period: DateInterval) -> DateInterval {
        let six = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: period.start) ?? period.start
        let first = firstSliceStart ?? six
        return DateInterval(start: first < six ? period.start : six, end: period.end)
    }
    private func ticks(in plot: DateInterval, calendar: Calendar) -> [Date] {
        var output: [Date] = [], cursor = plot.start
        while cursor <= plot.end {
            output.append(cursor)
            cursor = calendar.date(byAdding: .hour, value: 3, to: cursor) ?? plot.end.addingTimeInterval(1)
        }
        if output.last != plot.end { output.append(plot.end) }
        return output
    }
    var body: some View {
        // Calendar boundaries and ticks are invariant across every book lane.
        // Capturing their fractions keeps calendar/ICU work out of Canvas draws.
        let calendar = navigation.calendar
        let plot = self.plot(in: calendar, period: navigation.period)
        let ticks = self.ticks(in: plot, calendar: calendar)
        let tickPositions = ticks.map { CGFloat($0.timeIntervalSince(plot.start) / max(1, plot.duration)) }
        return VStack(spacing: 0) {
            HStack(spacing: 16) {
                Color.clear.frame(width: 130, height: 24)
                GeometryReader { geo in
                    ForEach(Array(ticks.enumerated()), id: \.offset) { index, date in
                        Text(AtlasStyle.date(date, zone: navigation.timezoneID, pattern: "ha"))
                            .font(.system(size: 10)).foregroundStyle(AtlasStyle.muted(dark))
                            .position(x: min(geo.size.width - 18, max(18, tickPositions[index] * geo.size.width)), y: 10)
                            .opacity(geo.size.width < 420 && index % 2 == 1 ? 0 : 1)
                    }
                }.frame(height: 24).accessibilityHidden(true)
            }
            ForEach(bookIDs, id: \.self) { id in
                let row = slicesByBook[id] ?? []
                let credited = row.filter { $0.interval.disposition == .credited }.reduce(0) { $0 + $1.seconds }
                Button { select(id) } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(booksByID[id]?.title ?? "Unknown book")
                                .font(.callout.weight(.medium)).lineLimit(3)
                            Text(ReadingFormat.duration(credited)).font(.caption).foregroundStyle(AtlasStyle.muted(dark))
                        }.frame(width: 130, alignment: .leading)
                        Canvas { context, size in
                            for fraction in tickPositions {
                                var path = Path(); let position = fraction * size.width
                                path.move(to: CGPoint(x: position, y: 0)); path.addLine(to: CGPoint(x: position, y: size.height))
                                context.stroke(path, with: .color(AtlasStyle.rule(dark)), lineWidth: 0.6)
                            }
                            var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: 35)); baseline.addLine(to: CGPoint(x: size.width, y: 35))
                            context.stroke(baseline, with: .color(AtlasStyle.rule(dark)), lineWidth: 1)
                            for slice in row {
                                let start = x(slice.start, in: plot, width: size.width)
                                let width = min(size.width - start, max(2, x(slice.end, in: plot, width: size.width) - start))
                                let rect = CGRect(x: start, y: 23, width: width, height: 24)
                                let mark = Path(roundedRect: rect, cornerRadius: 5)
                                context.fill(mark, with: .color(AtlasStyle.book(id, dark: dark)))
                            }
                        }.frame(height: 76).accessibilityHidden(true)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityLabel("\(booksByID[id]?.title ?? "Unknown book"), \(ReadingFormat.duration(credited)) recorded. Show sessions.")
                .help("Show sessions for this book. Short spans have a minimum two-point hit mark; session detail shows exact time.")
            }
        }
    }
    private func x(_ date: Date, in plot: DateInterval, width: CGFloat) -> CGFloat { CGFloat(date.timeIntervalSince(plot.start) / max(1, plot.duration)) * width }
}

@MainActor
private struct AtlasSessionCard: View {
    let booksByID: [String: BookRecord]
    let timezoneID: String
    let presentation: AtlasSessionPresentation
    private var session: ReadingSessionGroup { presentation.session }
    let period: DateInterval
    let editSession: (ReadingInterval) -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    var body: some View {
        let parts = presentation.slices
        let credited = presentation.creditedSeconds
        let pages = presentation.pages
        let listening = presentation.listening
        VStack(alignment: .leading, spacing: 15) {
            Rectangle().fill(AtlasStyle.rule(dark)).frame(height: 1).accessibilityHidden(true)
            Text("\(time(max(session.start, period.start))) – \(time(min(session.end, period.end)))")
                .font(.caption).foregroundStyle(AtlasStyle.muted(dark))
            AtlasBookLabel(booksByID: booksByID, id: session.bookID)
            HStack(spacing: 12) {
                if pages > 0 { Text("\(pages) pages").font(.callout.weight(.medium)) }
                Text("\(ReadingFormat.duration(credited)) \(listening ? "listening" : "recorded")").font(.caption)
            }
            if let position = presentation.position {
                Text("Position \(position.description)").font(.caption).foregroundStyle(AtlasStyle.muted(dark))
            }
            let manual = presentation.manualPages
            if manual > 0 { Text("Includes \(manual) manually added pages").font(.caption).foregroundStyle(AtlasStyle.muted(dark)) }
            DisclosureGroup("Session details") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(parts) { slice in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(time(slice.start)) – \(time(slice.end))")
                                Text("\(ReadingFormat.duration(slice.seconds)) · \(slice.interval.disposition == .credited ? "Credited" : "Excluded")")
                            }.font(.caption).foregroundStyle(AtlasStyle.muted(dark))
                            Spacer(minLength: 0)
                            Button("Edit") { editSession(slice.interval) }.buttonStyle(AtlasButtonStyle())
                        }
                    }
                }.padding(.top, 12)
            }.font(.caption).tint(AtlasStyle.accent(dark))
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func time(_ date: Date) -> String { AtlasStyle.date(date, zone: timezoneID, pattern: "h:mm a z") }
}
