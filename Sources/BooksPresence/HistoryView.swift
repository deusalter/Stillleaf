import SwiftUI
import BooksCore

@MainActor
struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var navigation: CalendarNavigation

    init(model: AppModel, initialScale: CalendarScale = .month) {
        self.model = model
        _navigation = State(initialValue: CalendarNavigation(timezoneID: model.timezoneID, scale: initialScale))
    }

    private var todayStart: Date { navigation.calendar.startOfDay(for: Date()) }

    var body: some View {
        // Calendar periods start/end at local midnight; sortable civil-day keys avoid
        // reparsing every saved date and rebuilding the period for each summary metric.
        let period = navigation.period
        let firstKey = navigation.dayKey(for: period.start)
        let endKey = navigation.dayKey(for: period.end)
        let visibleDays = model.days.filter { $0.day >= firstKey && $0.day < endKey }
        let creditedSeconds = visibleDays.reduce(0) { $0 + $1.creditedSeconds }
        let pageTurns = model.pages(from: period.start, through: period.end)
        let activeDays = visibleDays.filter { model.pages(on: $0.day) > 0 || $0.creditedSeconds > 0 }.count
        let pageGoalDays = visibleDays.filter { model.dailyGoal(on: $0.day).reached }.count
        // The heading lives inside the scroll view so it scrolls away with the content.
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader("History", subtitle: "See how your reading adds up.")
                VStack(alignment: .leading, spacing: 16) {
                    HistoryCalendarToolbar(navigation: navigation, isNextEnabled: canMoveForward, setScale: { setScale($0) }, previous: { move(-1) }, next: { move(1) }, today: { goToToday() })
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading, spacing: 18) {
                        HistoryMetric(title: "Pages read", value: pageTurns.formatted())
                        HistoryMetric(title: "Goals reached", value: "\(pageGoalDays)")
                        HistoryMetric(title: navigation.scale == .day ? "Books" : "Reading days", value: navigation.scale == .day ? "\(dayBookCount)" : "\(activeDays)")
                        HistoryMetric(title: "Reading time", value: ReadingFormat.duration(creditedSeconds))
                    }.padding(.vertical, 10)
                    Hairline()
                    Group {
                        switch navigation.scale {
                        case .month:
                            HistoryMonthCalendar(model: model, navigation: navigation, days: daysByKey, today: todayStart, select: { select($0, scale: .day) })
                        case .week:
                            HistoryWeekCalendar(model: model, navigation: navigation, days: daysByKey, today: todayStart, select: { select($0, scale: .day) })
                        case .year:
                            HistoryYearCalendar(model: model, navigation: navigation, days: daysByKey, today: todayStart, select: { select($0, scale: .month) })
                        case .day:
                            HistoryDayDetail(model: model, date: navigation.periodStart, navigation: navigation, back: { setScale(.month) })
                        }
                    }
                    .readingEntrance()
                    .id("\(navigation.scale.rawValue)-\(navigation.dayKey(for: navigation.periodStart))")
                }
                .padding(.vertical, 4)
                Text("Calendar timezone: \(model.timezoneID)")
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                if pageTurns == 0 && creditedSeconds > 0 {
                    Text("This period has recorded time but no observed-page data. Older history is not backfilled.")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                }
            }
            .readingPage()
        }
        .onChange(of: model.timezoneID) { timezoneID in navigation.timezoneID = timezoneID }
        .buttonStyle(ReadingButtonStyle())
    }

    private var daysByKey: [String: DailyTotal] { Dictionary(uniqueKeysWithValues: model.days.map { ($0.day, $0) }) }
    private var dayBookCount: Int {
        guard navigation.scale == .day else { return 0 }
        let resolver = BookMergeResolver(merges: model.merges)
        let entries = DayContribution.forDay(navigation.dayKey(for: navigation.periodStart), timezoneID: model.timezoneID, intervals: model.displayIntervals)
        return Set(entries.map { resolver.resolvedID(for: $0.interval.bookID) }).count
    }
    private var canMoveForward: Bool {
        let current = CalendarNavigation(timezoneID: model.timezoneID, anchor: Date(), scale: navigation.scale)
        return navigation.periodStart < current.periodStart
    }
    private func mutateNavigation(_ change: (inout CalendarNavigation) -> Void) {
        var updated = navigation; updated.timezoneID = model.timezoneID; change(&updated); navigation = updated
    }
    private func setScale(_ scale: CalendarScale) { mutateNavigation { $0.setScale(scale) } }
    private func select(_ date: Date, scale: CalendarScale) { guard date <= todayStart else { return }; mutateNavigation { $0.select(date, scale: scale) } }
    private func move(_ amount: Int) { guard amount < 0 || canMoveForward else { return }; mutateNavigation { $0.move(by: amount) } }
    private func goToToday() { mutateNavigation { $0.goToToday() } }
}

struct HistoryMetric: View {
    let title: String
    let value: String
    var body: some View {
        StatLine(value: value, label: title)
    }
}

private struct HistoryCalendarToolbar: View {
    let navigation: CalendarNavigation
    let isNextEnabled: Bool
    let setScale: (CalendarScale) -> Void
    let previous: () -> Void
    let next: () -> Void
    let today: () -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { titleRow; Spacer(minLength: 16); scalePicker.frame(width: 320); todayButton }
            VStack(alignment: .leading, spacing: 14) { HStack(spacing: 10) { titleRow; Spacer(); todayButton }; scalePicker.frame(maxWidth: 330) }
        }
    }
    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(navigation.title).font(ReadingType.bookTitle(25)).lineLimit(1).fixedSize().padding(.trailing, 8)
            Button(action: previous) { Image(systemName: "chevron.left") }.buttonStyle(ReadingButtonStyle(iconOnly: true)).accessibilityLabel("Previous \(navigation.scale.title.lowercased())")
            Button(action: next) { Image(systemName: "chevron.right") }.buttonStyle(ReadingButtonStyle(iconOnly: true)).disabled(!isNextEnabled).accessibilityLabel("Next \(navigation.scale.title.lowercased())")
        }
    }
    private var scalePicker: some View {
        ReadingSegmentedControl(label: "Calendar scale", options: CalendarScale.allCases,
            selection: Binding(get: { navigation.scale }, set: setScale), title: { $0.title })
    }
    private var todayButton: some View {
        Button("Today", action: today).controlSize(.small)
    }
}

private struct HistoryMonthCalendar: View {
    @ObservedObject var model: AppModel
    let navigation: CalendarNavigation
    let days: [String: DailyTotal]
    let today: Date
    let select: (Date) -> Void
    private let columns = Array(repeating: GridItem(.flexible(minimum: 42), spacing: 7), count: 7)
    var body: some View {
        VStack(spacing: 7) {
            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(weekdayNames, id: \.self) { weekday in
                    Text(weekday).font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.secondaryInk).frame(maxWidth: .infinity)
                }
                ForEach(navigation.monthCells) { cell in
                    HistoryMonthDayCell(model: model, cell: cell, dayNumber: navigation.calendar.component(.day, from: cell.date), timezoneID: navigation.timezoneID, total: days[navigation.dayKey(for: cell.date)], isToday: navigation.isSameDay(cell.date, today), isFuture: cell.date > today, select: { select(cell.date) })
                }
            }
            HistoryLegend()
        }
    }
    private var weekdayNames: [String] {
        let formatter = DateFormatter(); formatter.locale = Locale.current
        let symbols = formatter.shortWeekdaySymbols ?? []
        let first = navigation.calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }
}

private struct HistoryMonthDayCell: View {
    @ObservedObject var model: AppModel
    let cell: CalendarMonthCell
    let dayNumber: Int
    let timezoneID: String
    let total: DailyTotal?
    let isToday: Bool
    let isFuture: Bool
    let select: () -> Void
    @State private var hovering = false
    private var accent: Color? {
        guard let total else { return nil }
        let pages = model.pages(on: navigationDayKey)
        if model.dailyGoal(on: navigationDayKey).reached { return ReadingPalette.chart(0) }
        if pages > 0 { return ReadingPalette.chart(1) }
        if total.creditedSeconds > 0 { return ReadingPalette.chart(2) }
        if total.uncertainSeconds > 0 { return ReadingPalette.secondaryInk }
        return nil
    }
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(dayNumber)").font(.callout.weight(isToday ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(isToday ? ReadingPalette.accent : (cell.isInMonth ? ReadingPalette.ink : ReadingPalette.secondaryInk))
                if total != nil, model.pages(on: navigationDayKey) > 0 {
                    Text("\(model.pages(on: navigationDayKey)) \(model.pages(on: navigationDayKey) == 1 ? "page" : "pages")").font(.caption.weight(.medium)).monospacedDigit().lineLimit(1)
                } else if let total, total.creditedSeconds > 0 {
                    Text("Time only").font(.caption2.weight(.medium)).lineLimit(1)
                } else if total?.uncertainSeconds ?? 0 > 0 {
                    Image(systemName: "clock.badge.questionmark").font(.caption2)
                } else { Spacer(minLength: 0) }
                Spacer(minLength: 0)
                Capsule().fill(accent ?? .clear).frame(height: 3)
            }
            .foregroundStyle(cell.isInMonth ? ReadingPalette.ink : ReadingPalette.secondaryInk)
            .frame(maxWidth: .infinity, alignment: .topLeading).frame(height: 58).padding(8)
            .background(hovering && !isFuture ? ReadingPalette.accent.opacity(0.16) : (accent?.opacity(0.09) ?? ReadingPalette.surface), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isToday ? ReadingPalette.accent : .clear, lineWidth: isToday ? 1.5 : 0))
            .contentShape(Rectangle())
            .opacity(isFuture ? 0.45 : (cell.isInMonth ? 1 : 0.6))
        }
        .buttonStyle(.plain).disabled(isFuture).accessibilityLabel(accessibilityText)
        .onHover { hovering = $0 }
    }
    private var accessibilityText: String {
        let total = total ?? DailyTotal(day: "", creditedSeconds: 0, uncertainSeconds: 0, manualSeconds: 0, goalMinutes: 0)
        let pages = model.pages(on: navigationDayKey)
        return "\(HistoryCalendarFormat.longDate(cell.date, timezoneID: timezoneID)): \(ReadingFormat.observedPages(pages)), \(ReadingFormat.duration(total.creditedSeconds)) recorded time\(total.uncertainSeconds > 0 ? ", \(ReadingFormat.duration(total.uncertainSeconds)) awaiting review" : "")"
    }

    private var navigationDayKey: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: timezoneID) ?? .current; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: cell.date)
    }
}

private struct HistoryWeekCalendar: View {
    @ObservedObject var model: AppModel
    let navigation: CalendarNavigation
    let days: [String: DailyTotal]
    let today: Date
    let select: (Date) -> Void
    private var highestPageTurns: Int { max(1, navigation.weekDates.map { model.pages(on: navigation.dayKey(for: $0)) }.max() ?? 0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(navigation.weekDates, id: \.self) { date in
                    let total = days[navigation.dayKey(for: date)]
                    Button { select(date) } label: {
                        VStack(spacing: 7) {
                            Text(HistoryCalendarFormat.weekday(date, timezoneID: navigation.timezoneID)).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                            Text("\(navigation.calendar.component(.day, from: date))").font(.callout.weight(navigation.isSameDay(date, today) ? .bold : .regular))
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(readColor(total, date: date)).frame(height: barHeight(date))
                            Text(ReadingFormat.observedPages(model.pages(on: navigation.dayKey(for: date)))).font(.caption2).monospacedDigit().lineLimit(1)
                            Text(ReadingFormat.duration(total?.creditedSeconds ?? 0)).font(.caption2).monospacedDigit().foregroundStyle(ReadingPalette.secondaryInk).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 146).padding(8)
                        .background(navigation.isSameDay(date, today) ? ReadingPalette.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ReadingPalette.border, lineWidth: 1))
                        .opacity(date > today ? 0.45 : 1)
                    }
                    .buttonStyle(.plain).disabled(date > today).accessibilityLabel("Show \(HistoryCalendarFormat.longDate(date, timezoneID: navigation.timezoneID))")
                }
            }
            HistoryLegend()
        }
    }
    private func barHeight(_ date: Date) -> CGFloat {
        CGFloat(max(5, min(72, Double(model.pages(on: navigation.dayKey(for: date))) / Double(highestPageTurns) * 72)))
    }
    private func readColor(_ total: DailyTotal?, date: Date) -> Color {
        guard let total else { return ReadingPalette.ink.opacity(0.12) }
        let dayKey = navigation.dayKey(for: date)
        let pages = model.pages(on: dayKey)
        if model.dailyGoal(on: dayKey).reached { return ReadingPalette.chart(0) }
        if pages > 0 { return ReadingPalette.chart(1) }
        if total.creditedSeconds > 0 { return ReadingPalette.chart(2) }
        if total.uncertainSeconds > 0 { return ReadingPalette.secondaryInk }
        return ReadingPalette.ink.opacity(0.12)
    }
}

private struct HistoryYearCalendar: View {
    @ObservedObject var model: AppModel
    let navigation: CalendarNavigation
    let days: [String: DailyTotal]
    let today: Date
    let select: (Date) -> Void
    private let columns = Array(repeating: GridItem(.flexible(minimum: 180), spacing: 12), count: 3)
    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(navigation.yearMonths, id: \.self) { month in HistoryMiniMonth(model: model, navigation: navigation, month: month, days: days, today: today, select: { select(month) }) }
        }
    }
}

private struct HistoryMiniMonth: View {
    @ObservedObject var model: AppModel
    let navigation: CalendarNavigation
    let month: Date
    let days: [String: DailyTotal]
    let today: Date
    let select: () -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private var monthNavigation: CalendarNavigation { CalendarNavigation(timezoneID: navigation.timezoneID, anchor: month, scale: .month) }
    private var isFuture: Bool {
        let currentMonth = navigation.calendar.dateInterval(of: .month, for: today)?.start ?? today
        return month > currentMonth
    }
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(HistoryCalendarFormat.month(month, timezoneID: navigation.timezoneID)).font(ReadingType.bookTitle(17))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ReadingFormat.observedPages(monthPageTurns)).font(.caption).monospacedDigit()
                        Text(ReadingFormat.duration(monthCreditedSeconds)).font(.caption2).monospacedDigit().foregroundStyle(ReadingPalette.secondaryInk)
                    }
                }
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(monthNavigation.monthCells) { cell in
                        ZStack {
                            // A tint of the series colour keeps ink digits at full contrast.
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color(for: cell).opacity(0.32))
                            if cell.isInMonth {
                                Text("\(navigation.calendar.component(.day, from: cell.date))")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(ReadingPalette.ink)
                            }
                        }
                        .frame(height: 16)
                        .opacity(cell.isInMonth ? 1 : 0.22)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReadingPalette.border, lineWidth: 1))
            .opacity(isFuture ? 0.45 : 1)
        }
        .buttonStyle(.plain).disabled(isFuture).accessibilityLabel("Open \(HistoryCalendarFormat.month(month, timezoneID: navigation.timezoneID))")
    }
    private func color(for cell: CalendarMonthCell) -> Color {
        guard let total = days[navigation.dayKey(for: cell.date)] else { return ReadingPalette.track }
        let dayKey = navigation.dayKey(for: cell.date)
        let pages = model.pages(on: dayKey)
        if model.dailyGoal(on: dayKey).reached { return ReadingPalette.chart(0) }
        if pages > 0 { return ReadingPalette.chart(1) }
        if total.creditedSeconds > 0 { return ReadingPalette.chart(2) }
        if total.uncertainSeconds > 0 { return ReadingPalette.secondaryInk }
        return ReadingPalette.track
    }
    private var monthCreditedSeconds: Double {
        monthNavigation.monthCells
            .filter(\.isInMonth)
            .compactMap { days[navigation.dayKey(for: $0.date)]?.creditedSeconds }
            .reduce(0, +)
    }
    private var monthPageTurns: Int {
        monthNavigation.monthCells
            .filter(\.isInMonth)
            .reduce(0) { $0 + model.pages(on: navigation.dayKey(for: $1.date)) }
    }
}

private struct HistoryLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            LegendDot(color: ReadingPalette.chart(0), text: "Page goal met")
            LegendDot(color: ReadingPalette.chart(1), text: "Reading pages")
            LegendDot(color: ReadingPalette.chart(2), text: "Time-only history")
            LegendDot(color: ReadingPalette.secondaryInk, text: "Awaiting review")
        }.frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct LegendDot: View {
    let color: Color
    let text: String
    var body: some View { HStack(spacing: 4) { Capsule().fill(color).frame(width: 12, height: 4); Text(text).font(.caption).foregroundStyle(ReadingPalette.secondaryInk) } }
}

@MainActor
private struct HistoryDayDetail: View {
    @ObservedObject var model: AppModel
    let date: Date
    let navigation: CalendarNavigation
    let back: () -> Void
    @State private var reviewInterval: ReadingInterval?
    private var dayKey: String { navigation.dayKey(for: date) }
    private var pageTurns: Int { model.pages(on: dayKey) }
    private var pageGoal: Int? { model.pageGoal(on: dayKey) }
    private var total: DailyTotal? { model.days.first { $0.day == dayKey } }
    private var contributions: [DayContribution] { DayContribution.forDay(dayKey, timezoneID: model.timezoneID, intervals: model.displayIntervals) }
    private var period: DateInterval { navigation.calendar.dateInterval(of: .day, for: date)! }
    private var sessions: [ReadingSessionGroup] {
        model.visibleReadingSessions.filter { $0.end > period.start && $0.start < period.end }.sorted { $0.start > $1.start }
    }
    private var bookContributions: [HistoryBookContribution] {
        let resolver = BookMergeResolver(merges: model.merges)
        let grouped = Dictionary(grouping: contributions, by: { resolver.resolvedID(for: $0.interval.bookID) })
        let summaries: [HistoryBookContribution] = grouped.map { entry in
            let credited = entry.value
                .filter { $0.interval.disposition == .credited }
                .reduce(0.0) { result, contribution in result + contribution.clippedSeconds }
            let uncertain = entry.value
                .filter { $0.interval.disposition == .uncertain }
                .reduce(0.0) { result, contribution in result + contribution.clippedSeconds }
            let pageTurns = model.pages(forBookID: entry.key, from: period.start, through: period.end)
            return HistoryBookContribution(bookID: entry.key, pageTurns: pageTurns, creditedSeconds: credited, uncertainSeconds: uncertain)
        }
        return summaries.sorted { $0.pageTurns == $1.pageTurns ? $0.totalSeconds > $1.totalSeconds : $0.pageTurns > $1.pageTurns }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your reading day").font(ReadingType.bookTitle(22))
                    Text(model.dailyGoal(on: dayKey).summary + " · Daily goal")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                }
                Spacer(); Button("Month", action: back).controlSize(.small)
            }
            if contributions.isEmpty {
                ReadingEmptyState(title: "No reading recorded", symbol: "calendar.badge.clock", message: "There are no saved reading spans for this day.")
            } else {
                if pageTurns == 0 {
                    Text("No pages were saved for this day. Older time-only history is not backfilled.")
                        .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                }
                ReadingSection("Books") {
                  VStack(alignment: .leading, spacing: 10) {
                    ForEach(bookContributions) { contribution in
                        let book = model.books.first { $0.id == contribution.bookID }
                        HStack {
                            Text(book?.title ?? "Unknown book").font(.callout.weight(.medium)).foregroundStyle(ReadingPalette.ink); Spacer()
                            Text(ReadingFormat.observedPages(contribution.pageTurns))
                            if contribution.creditedSeconds > 0 { Text("Time \(ReadingFormat.duration(contribution.creditedSeconds))") }
                            if contribution.uncertainSeconds > 0 { Text("Review \(ReadingFormat.duration(contribution.uncertainSeconds))") }
                        }.font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    }
                  }
                }
                ReadingSection("Reading sessions") {
                  VStack(alignment: .leading, spacing: 8) {
                    Text("Short breaks stay in the same session. Brief automatic visits without page activity are hidden; recorded time is kept.")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    ForEach(sessions) { session in
                        HistorySessionRow(model: model, session: session, dayKey: dayKey, period: period, review: { reviewInterval = $0 })
                        if session.id != sessions.last?.id { Hairline() }
                    }
                  }
                }
            }
        }
        .sheet(item: $reviewInterval) { interval in IntervalReviewEditor(model: model, interval: interval) }
    }
}

@MainActor
private struct HistorySessionRow: View {
    @ObservedObject var model: AppModel
    let session: ReadingSessionGroup
    let dayKey: String
    let period: DateInterval
    let review: (ReadingInterval) -> Void
    private var book: BookRecord? { model.books.first { $0.id == session.bookID } }
    private var fragments: [DayContribution] { DayContribution.forDay(dayKey, timezoneID: model.timezoneID, intervals: session.intervals) }
    private var credited: Double { fragments.filter { $0.interval.disposition == .credited }.reduce(0) { $0 + $1.clippedSeconds } }
    private var uncertain: Double { fragments.filter { $0.interval.disposition == .uncertain }.reduce(0) { $0 + $1.clippedSeconds } }
    var body: some View {
        DisclosureGroup {
            VStack(spacing: 10) {
                ForEach(fragments) { fragment in
                    HStack {
                        Text("\(HistoryDateFormat.time(max(fragment.interval.start, period.start), timezoneID: model.timezoneID)) – \(HistoryDateFormat.time(min(fragment.interval.end, period.end), timezoneID: model.timezoneID))")
                            .font(.caption).monospacedDigit()
                        Spacer()
                        Text(ReadingFormat.duration(fragment.clippedSeconds)).font(.caption).monospacedDigit()
                        if fragment.interval.disposition == .uncertain { Text("Awaiting review").font(.caption).foregroundStyle(ReadingPalette.secondaryInk) }
                        Button("Review") { review(fragment.interval) }.controlSize(.small)
                    }
                }
            }.padding(.leading, 12).padding(.vertical, 10)
        } label: {
            HStack(spacing: 12) {
                BookCoverView(book: book, size: .compact)
                VStack(alignment: .leading, spacing: 5) {
                    Text(book?.title ?? "Unknown book").font(ReadingType.bookTitle(17))
                    Text("\(HistoryDateFormat.time(max(session.start, period.start), timezoneID: model.timezoneID)) – \(HistoryDateFormat.time(min(session.end, period.end), timezoneID: model.timezoneID))")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    Text("\(ReadingFormat.observedPages(model.pages(in: session, from: period.start, through: period.end))) · \(ReadingFormat.duration(credited)) reading")
                        .font(.callout).monospacedDigit()
                    let corrected = model.manualPages(in: session, from: period.start, through: period.end)
                    if corrected > 0 {
                        Text("Includes \(corrected) manually added pages").font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    }
                    if uncertain > 0 { Text("\(ReadingFormat.duration(uncertain)) awaiting review").font(.caption).foregroundStyle(ReadingPalette.secondaryInk) }
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 8)
        }
    }
}

private struct HistoryBookContribution: Identifiable {
    let bookID: String
    let pageTurns: Int
    let creditedSeconds: Double
    let uncertainSeconds: Double
    var id: String { bookID }
    var totalSeconds: Double { creditedSeconds + uncertainSeconds }
}

struct DayContribution: Identifiable {
    let interval: ReadingInterval
    let clippedSeconds: TimeInterval
    var id: String { interval.id }
    static func forDay(_ key: String, timezoneID: String, intervals: [ReadingInterval]) -> [DayContribution] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timezoneID) ?? .current
        let components = key.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3, let dayStart = calendar.date(from: DateComponents(year: components[0], month: components[1], day: components[2])), let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return intervals.compactMap { interval in
            let overlapStart = max(interval.start, dayStart); let overlapEnd = min(interval.end, dayEnd)
            if overlapEnd > overlapStart {
                let wallSeconds = interval.end.timeIntervalSince(interval.start)
                let clipped = wallSeconds > 0 ? interval.duration * overlapEnd.timeIntervalSince(overlapStart) / wallSeconds : interval.duration
                return DayContribution(interval: interval, clippedSeconds: clipped)
            }
            if interval.start == interval.end && interval.start >= dayStart && interval.start < dayEnd { return DayContribution(interval: interval, clippedSeconds: interval.duration) }
            return nil
        }.sorted { $0.interval.start > $1.interval.start }
    }
}

@MainActor
struct DayContributionRow: View {
    @ObservedObject var model: AppModel
    let contribution: DayContribution
    let timezoneID: String
    let review: () -> Void
    private var book: BookRecord? {
        let resolvedID = BookMergeResolver(merges: model.merges).resolvedID(for: contribution.interval.bookID)
        return model.books.first { $0.id == resolvedID }
    }
    private var treatment: String {
        switch contribution.interval.disposition {
        case .credited: return contribution.interval.mode == .manual ? "Manual credited" : "Credited"
        case .uncertain: return "Awaiting review"
        case .excluded: return "Excluded from totals"
        }
    }
    private var pageTurns: Int { model.pages(forSessionID: contribution.interval.sessionID) }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BookCoverView(book: book, size: .compact)
            VStack(alignment: .leading, spacing: 3) {
                Text(book?.title ?? "Unknown book").font(.headline)
                Text("\(HistoryDateFormat.time(contribution.interval.start, timezoneID: timezoneID)) – \(HistoryDateFormat.time(contribution.interval.end, timezoneID: timezoneID))").font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                Text("\(treatment): \(ReadingFormat.observedPages(pageTurns))").font(.callout).monospacedDigit()
                Text("Time on this day: \(ReadingFormat.duration(contribution.clippedSeconds))").font(.caption).monospacedDigit().foregroundStyle(ReadingPalette.secondaryInk)
            }
            Spacer(minLength: 0); Button("Review", action: review).controlSize(.small)
        }.padding(.vertical, 4)
    }
}

private enum HistoryDateFormat {
    static func time(_ date: Date, timezoneID: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale.current; formatter.timeZone = TimeZone(identifier: timezoneID) ?? .current; formatter.dateStyle = .none; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private enum HistoryCalendarFormat {
    static func weekday(_ date: Date, timezoneID: String) -> String { format(date, timezoneID: timezoneID, pattern: "EEEEE") }
    static func month(_ date: Date, timezoneID: String) -> String { format(date, timezoneID: timezoneID, pattern: "MMMM") }
    static func longDate(_ date: Date, timezoneID: String) -> String { format(date, timezoneID: timezoneID, pattern: "EEEE, MMMM d, yyyy") }

    private static func format(_ date: Date, timezoneID: String, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone(identifier: timezoneID) ?? .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
