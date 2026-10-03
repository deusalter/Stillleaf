import SwiftUI
import BooksCore

@MainActor
struct AtlasWeekView: View {
    let navigation: CalendarNavigation
    let presentation: HistoryAtlasPeriod
    private var days: [AtlasDay] { presentation.days }
    let select: (Date) -> Void
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var bookIDs: [String] { presentation.creditedBookIDs }
    var body: some View {
        // Every stacked segment uses the same scale. Resolve it once instead of
        // rescanning the week's days from each GeometryReader/segment closure.
        let maximumMinutes = max(30, ceil((days.map(\.creditedSeconds).max() ?? 0) / 60 / 30) * 30)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) { chart(maximumMinutes: maximumMinutes).frame(minWidth: 420); bookSummary.frame(width: 210) }
            VStack(alignment: .leading, spacing: 24) { chart(maximumMinutes: maximumMinutes); bookSummary }
        }
    }
    private func chart(maximumMinutes: Double) -> some View {
        AtlasPanel(title: "Time with your books", note: "Minutes") {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    ForEach((0...3).reversed(), id: \.self) { step in
                        Text(Int(maximumMinutes * Double(step) / 3).formatted()).font(.caption2).monospacedDigit()
                        if step > 0 { Spacer(minLength: 0) }
                    }
                }.foregroundStyle(AtlasStyle.muted(dark)).frame(width: 30, height: 224).padding(.top, 20)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(days) { day in dayColumn(day, maximumMinutes: maximumMinutes) }
                }
                .background(alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(0...3, id: \.self) { step in
                            Rectangle().fill(AtlasStyle.rule(dark)).frame(height: 0.6)
                            if step < 3 { Spacer(minLength: 0) }
                        }
                    }.frame(height: 220).padding(.top, 24).accessibilityHidden(true)
                }
            }
            if !bookIDs.isEmpty { AtlasLegend(booksByID: presentation.booksByID, bookIDs: bookIDs) }
            if days.allSatisfy({ $0.creditedSeconds == 0 }) {
                Text("No credited time this week. Select a day to see any pages or records awaiting review.")
                    .font(.caption).foregroundStyle(AtlasStyle.muted(dark))
            }
        }
    }
    private func dayColumn(_ day: AtlasDay, maximumMinutes: Double) -> some View {
        let future = day.date > navigation.calendar.startOfDay(for: Date())
        let pages = presentation.daysByKey[day.key]?.pages ?? 0
        let entries = day.books.filter { $0.creditedSeconds > 0 }.sorted { $0.bookID < $1.bookID }
        return Button { select(day.date) } label: {
            VStack(spacing: 12) {
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        VStack(spacing: 0) {
                            ForEach(entries.reversed()) { entry in
                                Rectangle().fill(AtlasStyle.book(entry.bookID, dark: dark))
                                    .frame(height: CGFloat(entry.creditedSeconds / 60 / maximumMinutes) * 220)
                            }
                        }.frame(width: min(36, geo.size.width)).clipShape(RoundedRectangle(cornerRadius: 5))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        if day.creditedSeconds > 0 {
                            Text(ReadingFormat.duration(day.creditedSeconds)).font(.system(size: 10)).lineLimit(1)
                                .position(x: geo.size.width / 2, y: 244 - CGFloat(day.creditedSeconds / 60 / maximumMinutes) * 220 - 12)
                        }
                    }
                }.frame(height: 244)
                Text(AtlasStyle.date(day.date, zone: navigation.timezoneID, pattern: "EEE")).font(.caption)
                Text("\(navigation.calendar.component(.day, from: day.date))").font(.caption2).foregroundStyle(AtlasStyle.muted(dark))
                VStack(spacing: 3) {
                    Text(future ? "—" : pages.formatted()).font(.callout.weight(.medium))
                    Text("pages").font(.caption2).foregroundStyle(AtlasStyle.muted(dark))
                }.padding(.top, 5)
                if day.uncertainSeconds > 0 { Image(systemName: "clock.badge.questionmark").font(.caption).accessibilityHidden(true) }
            }.frame(maxWidth: .infinity).contentShape(Rectangle()).opacity(future ? 0.35 : 1)
        }.buttonStyle(.plain).disabled(future)
            .accessibilityLabel("\(AtlasStyle.date(day.date, zone: navigation.timezoneID, pattern: "EEEE, MMMM d")), \(ReadingFormat.duration(day.creditedSeconds)) recorded, \(pages) pages, \(ReadingFormat.duration(day.uncertainSeconds)) awaiting review. Open day.")
            .help(entries.isEmpty ? "Open day" : detail(entries))
    }
    private func detail(_ entries: [AtlasBookTime]) -> String {
        entries.map { entry in "\(presentation.booksByID[entry.bookID]?.title ?? "Unknown book"): \(ReadingFormat.duration(entry.creditedSeconds))" }.joined(separator: "\n")
    }
    private var bookSummary: some View {
        // This list shares History's vertical scroll view. A busy week can span
        // many screens; instantiate covers and wrapped text as rows come into view.
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(bookIDs, id: \.self) { id in
                let seconds = presentation.secondsByBook[id] ?? 0
                let pages = presentation.pagesByBook[id] ?? 0
                AtlasBookLabel(booksByID: presentation.booksByID, id: id,
                    detail: (pages > 0 ? "\(pages) pages\n" : "") + "\(ReadingFormat.duration(seconds)) recorded", small: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AtlasTimeRing: View {
    let entries: [AtlasBookTime]
    var pending = false
    @Environment(\.colorScheme) private var scheme
    private var total: Double { entries.reduce(0) { $0 + $1.creditedSeconds } }
    var body: some View {
        ZStack {
            Circle().stroke(AtlasStyle.rule(scheme == .dark), lineWidth: 3)
            if total > 0 {
                ForEach(Array(entries.enumerated()), id: \.element.bookID) { index, entry in
                    let start = entries.prefix(index).reduce(0) { $0 + $1.creditedSeconds } / total
                    Circle().trim(from: start, to: start + entry.creditedSeconds / total)
                        .stroke(AtlasStyle.book(entry.bookID, dark: scheme == .dark), style: StrokeStyle(lineWidth: 3.5, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            } else if pending {
                Circle().stroke(AtlasStyle.muted(scheme == .dark), style: StrokeStyle(lineWidth: 2, dash: [2, 3]))
            }
        }.accessibilityHidden(true)
    }
}

@MainActor
struct AtlasMonthView: View {
    let navigation: CalendarNavigation
    let presentation: HistoryAtlasPeriod
    let select: (Date) -> Void
    @State private var selected: Date?
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var ids: [String] { presentation.creditedBookIDs }

    static func indexDays(_ presentation: HistoryAtlasPeriod, calendar: Calendar) -> [Date: AtlasDayPresentation] {
        Dictionary(uniqueKeysWithValues: presentation.daysByKey.values.map {
            (calendar.startOfDay(for: $0.day.date), $0)
        })
    }

    static func day(for date: Date, in index: [Date: AtlasDayPresentation], calendar: Calendar) -> AtlasDayPresentation? {
        index[calendar.startOfDay(for: date)]
    }

    var body: some View {
        let calendar = navigation.calendar
        let selectedDate = selected ?? calendar.startOfDay(for: navigation.anchor)
        // Day cells and detail rows share one calendar/selection snapshot. In
        // midnight DST transitions, repeated day arithmetic can retain 01:00
        // while grid dates return to 00:00. Match civil days, not those instants.
        let daysByDate = Self.indexDays(presentation, calendar: calendar)
        let selectedDay = Self.day(for: selectedDate, in: daysByDate, calendar: calendar)
        let formatter = DateFormatter(); formatter.locale = .current
        let weekdayNames = formatter.shortWeekdaySymbols ?? []
        let grid = monthCalendar(calendar: calendar, selectedDate: selectedDate,
                                 today: calendar.startOfDay(for: Date()), daysByDate: daysByDate,
                                 cells: navigation.monthCells, weekdayNames: weekdayNames)
        let details = detail(selectedDate: selectedDate, selectedDay: selectedDay)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) { grid.frame(minWidth: 440); details.frame(width: 220) }
            VStack(alignment: .leading, spacing: 24) { grid; details }
        }
    }
    private func monthCalendar(calendar: Calendar, selectedDate: Date, today: Date,
                               daysByDate: [Date: AtlasDayPresentation], cells: [CalendarMonthCell], weekdayNames: [String]) -> some View {
        let firstWeekday = calendar.firstWeekday
        return AtlasPanel(title: AtlasStyle.date(navigation.periodStart, zone: navigation.timezoneID, pattern: "MMMM"), note: "Time by book") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 42), spacing: 8), count: 7), spacing: 14) {
                ForEach(0..<7, id: \.self) { index in
                    Text(weekdayNames[(firstWeekday - 1 + index) % 7]).font(.caption).foregroundStyle(AtlasStyle.muted(dark)).padding(.bottom, 8)
                }
                ForEach(cells) { cell in
                    if cell.isInMonth { dayCell(cell.date, prepared: Self.day(for: cell.date, in: daysByDate, calendar: calendar), calendar: calendar, selectedDate: selectedDate, today: today) }
                    else { Color.clear.frame(height: 77).accessibilityHidden(true) }
                }
            }
            if !ids.isEmpty { AtlasLegend(booksByID: presentation.booksByID, bookIDs: ids) }
            Text("Ring segments show each book’s share of recorded time.").font(.caption2).foregroundStyle(AtlasStyle.muted(dark))
        }
    }
    private func dayCell(_ date: Date, prepared: AtlasDayPresentation?, calendar: Calendar, selectedDate: Date, today: Date) -> some View {
        let day = prepared?.day
        let entries = (day?.books ?? []).filter { $0.creditedSeconds > 0 }
        let future = date > today
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let seconds = day?.creditedSeconds ?? 0
        let pages = prepared?.pages ?? 0
        let names = entries.map { entry in "\(presentation.booksByID[entry.bookID]?.title ?? "Unknown book"): \(ReadingFormat.duration(entry.creditedSeconds))" }.joined(separator: ", ")
        return Button { selected = date } label: {
            VStack(spacing: 9) {
                ZStack {
                    AtlasTimeRing(entries: entries, pending: (day?.uncertainSeconds ?? 0) > 0).frame(width: 43, height: 43)
                    Text("\(calendar.component(.day, from: date))").font(.system(size: 12)).monospacedDigit()
                }
                Text(seconds > 0 ? ReadingFormat.duration(seconds) : (day?.uncertainSeconds ?? 0) > 0 ? "Review" : pages > 0 ? "\(pages)p" : "—")
                    .font(.system(size: 10)).foregroundStyle(AtlasStyle.muted(dark)).lineLimit(1)
            }.frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(isSelected ? AtlasStyle.accent(dark).opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? AtlasStyle.accent(dark) : .clear, lineWidth: 1))
                .contentShape(Rectangle()).opacity(future ? 0.3 : 1)
        }.buttonStyle(.plain).disabled(future)
            .accessibilityLabel("\(AtlasStyle.date(date, zone: navigation.timezoneID, pattern: "EEEE, MMMM d")), \(ReadingFormat.duration(seconds)) recorded, \(pages) pages. \(names). \(ReadingFormat.duration(day?.uncertainSeconds ?? 0)) awaiting review.")
            .accessibilityAddTraits(isSelected ? .isSelected : []).help(names.isEmpty ? "No credited time" : names)
    }
    private func detail(selectedDate: Date, selectedDay: AtlasDayPresentation?) -> some View {
        let selectedIDs = selectedDay?.bookIDs ?? []
        return VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text(AtlasStyle.date(selectedDate, zone: navigation.timezoneID, pattern: "EEEE d")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Open day") { select(selectedDate) }.buttonStyle(AtlasButtonStyle())
            }
            if selectedIDs.isEmpty { Text("No reading recorded.").font(.callout).foregroundStyle(AtlasStyle.muted(dark)) }
            ForEach(selectedIDs, id: \.self) { id in
                let pages = selectedDay?.pagesByBook[id] ?? 0
                let time = selectedDay?.day.books.first { $0.bookID == id }
                VStack(alignment: .leading, spacing: 12) {
                    AtlasBookLabel(booksByID: presentation.booksByID, id: id, detail: (pages > 0 ? "\(pages) pages\n" : "") + "\(ReadingFormat.duration(time?.creditedSeconds ?? 0)) recorded", small: true)
                    if let position = selectedDay?.positionsByBook[id] {
                        Text("Recorded position\n\(position.description)").font(.caption).foregroundStyle(AtlasStyle.muted(dark))
                    }
                    if let time, time.uncertainSeconds > 0 {
                        Text("\(ReadingFormat.duration(time.uncertainSeconds)) awaiting review").font(.caption).foregroundStyle(AtlasStyle.muted(dark))
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
