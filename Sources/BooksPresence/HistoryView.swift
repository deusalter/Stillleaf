import SwiftUI
import BooksCore

@MainActor
struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var navigation: CalendarNavigation

    init(model: AppModel, initialScale: CalendarScale = .month, anchor: Date = Date()) {
        self.model = model
        _navigation = State(initialValue: CalendarNavigation(timezoneID: model.timezoneID, anchor: anchor, scale: initialScale))
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
                PageHeader("History", subtitle: "")
                VStack(alignment: .leading, spacing: 16) {
                    HistoryCalendarToolbar(navigation: navigation, isNextEnabled: canMoveForward, setScale: { setScale($0) }, previous: { move(-1) }, next: { move(1) }, today: { goToToday() })
                    if navigation.scale != .day {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(pageTurns > 0 ? pageTurns.formatted() : ReadingFormat.duration(creditedSeconds)).font(ReadingType.bookTitle(36))
                            Text(pageTurns > 0 ? "pages" : "recorded").foregroundStyle(ReadingPalette.secondaryInk)
                            Spacer()
                            Text("\(activeDays) reading \(activeDays == 1 ? "day" : "days")  ·  \(ReadingFormat.duration(creditedSeconds))  ·  \(pageGoalDays) \(pageGoalDays == 1 ? "goal" : "goals") reached")
                                .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                        }
                        .padding(.vertical, 12)
                        .help("\(pageGoalDays) daily goals reached in this period")
                    }
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
                Text(model.timezoneID.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2).foregroundStyle(ReadingPalette.secondaryInk)
                    .help("Dates and sessions use this calendar timezone.")
            }
            .readingPage()
        }
        .onChange(of: model.timezoneID) { timezoneID in navigation.timezoneID = timezoneID }
        .buttonStyle(ReadingButtonStyle())
    }

    private var daysByKey: [String: DailyTotal] { Dictionary(uniqueKeysWithValues: model.days.map { ($0.day, $0) }) }
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
            Text(navigation.title).font(ReadingType.bookTitle(28)).lineLimit(1).fixedSize().padding(.trailing, 8)
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
        if model.dailyGoal(on: navigationDayKey).reached { return ReadingPalette.accent }
        if pages > 0 { return ReadingPalette.accent.opacity(0.7) }
        if total.creditedSeconds > 0 { return ReadingPalette.accent.opacity(0.4) }
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
                if model.dailyGoal(on: navigationDayKey).reached {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ReadingPalette.accent).accessibilityLabel("Daily goal reached")
                }
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
    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(navigation.weekDates, id: \.self) { date in
                let key = navigation.dayKey(for: date)
                let total = days[key]
                let pages = model.pages(on: key)
                let entries = DayContribution.forDay(key, timezoneID: model.timezoneID, intervals: model.displayIntervals)
                let resolver = BookMergeResolver(merges: model.merges)
                let ids = Set(entries.map { resolver.resolvedID(for: $0.interval.bookID) })
                let titles = model.books.filter { ids.contains($0.id) }.map(\.title).sorted()
                Button { select(date) } label: {
                    HStack(spacing: 22) {
                        VStack(spacing: 3) {
                            Text(HistoryCalendarFormat.weekday(date, timezoneID: navigation.timezoneID))
                                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                            Text("\(navigation.calendar.component(.day, from: date))").font(ReadingType.bookTitle(26))
                        }.frame(width: 40)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(titles.isEmpty ? (pages > 0 ? "Reading recorded" : "—") : titles.joined(separator: " · "))
                                .font(titles.isEmpty ? .callout : ReadingType.bookTitle(18)).lineLimit(2)
                            if let total, total.uncertainSeconds > 0 {
                                Text("\(ReadingFormat.duration(total.uncertainSeconds)) awaiting review")
                                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                            }
                        }
                        Spacer(minLength: 12)
                        if pages > 0 || (total?.creditedSeconds ?? 0) > 0 {
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(pages > 0 ? ReadingFormat.observedPages(pages) : "Time only").font(.callout.weight(.medium))
                                Text(ReadingFormat.duration(total?.creditedSeconds ?? 0)).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                            }
                        }
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(ReadingPalette.secondaryInk)
                    }
                    .foregroundStyle(ReadingPalette.ink).padding(.horizontal, 16).padding(.vertical, 9)
                    .background(navigation.isSameDay(date, today) ? ReadingPalette.accent.opacity(0.09) : ReadingPalette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .opacity(date > today ? 0.4 : 1)
                }
                .buttonStyle(.plain).disabled(date > today)
                .accessibilityLabel("\(HistoryCalendarFormat.longDate(date, timezoneID: navigation.timezoneID)), \(ReadingFormat.observedPages(pages)), \(titles.joined(separator: ", "))")
            }
        }
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
        if model.dailyGoal(on: dayKey).reached { return ReadingPalette.accent }
        if pages > 0 { return ReadingPalette.accent.opacity(0.7) }
        if total.creditedSeconds > 0 { return ReadingPalette.accent.opacity(0.4) }
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

@MainActor
private struct HistoryDayDetail: View {
    @ObservedObject var model: AppModel
    let date: Date
    let navigation: CalendarNavigation
    let back: () -> Void
    @State private var reviewInterval: ReadingInterval?
    private var dayKey: String { navigation.dayKey(for: date) }
    private var pageTurns: Int { model.pages(on: dayKey) }
    private var total: DailyTotal? { model.days.first { $0.day == dayKey } }
    private var creditedSeconds: Double { total?.creditedSeconds ?? 0 }
    private var uncertainSeconds: Double { total?.uncertainSeconds ?? 0 }
    private var summaryValue: String {
        if pageTurns > 0 { return pageTurns.formatted() }
        return ReadingFormat.duration(creditedSeconds > 0 ? creditedSeconds : uncertainSeconds)
    }
    private var summaryLabel: String {
        if pageTurns > 0 { return "pages read" }
        if creditedSeconds > 0 { return "recorded" }
        return uncertainSeconds > 0 ? "awaiting review" : "credited"
    }
    private var contributions: [DayContribution] { DayContribution.forDay(dayKey, timezoneID: model.timezoneID, intervals: model.displayIntervals) }
    private var period: DateInterval { navigation.calendar.dateInterval(of: .day, for: date)! }
    private var sessions: [ReadingSessionGroup] {
        model.visibleReadingSessions.filter { ($0.end > period.start && $0.start < period.end) || ($0.start == $0.end && $0.start >= period.start && $0.start < period.end) }.sorted { $0.start > $1.start }
    }
    private var bookContributions: [HistoryBookContribution] {
        let resolver = BookMergeResolver(merges: model.merges)
        let grouped = Dictionary(grouping: contributions, by: { resolver.resolvedID(for: $0.interval.bookID) })
        let bookIDs = Set(grouped.keys).union(model.books.filter {
            model.pages(forBookID: $0.id, from: period.start, through: period.end) > 0
        }.map(\.id))
        let summaries: [HistoryBookContribution] = bookIDs.map { bookID in
            let entries = grouped[bookID] ?? []
            let credited = entries
                .filter { $0.interval.disposition == .credited }
                .reduce(0.0) { result, contribution in result + contribution.clippedSeconds }
            let uncertain = entries
                .filter { $0.interval.disposition == .uncertain }
                .reduce(0.0) { result, contribution in result + contribution.clippedSeconds }
            let pageTurns = model.pages(forBookID: bookID, from: period.start, through: period.end)
            return HistoryBookContribution(bookID: bookID, pageTurns: pageTurns, creditedSeconds: credited, uncertainSeconds: uncertain)
        }
        return summaries.sorted {
            if $0.pageTurns != $1.pageTurns { return $0.pageTurns > $1.pageTurns }
            if $0.totalSeconds != $1.totalSeconds { return $0.totalSeconds > $1.totalSeconds }
            return $0.bookID < $1.bookID
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if bookContributions.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "book.closed").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(ReadingPalette.accent)
                    Text("Nothing recorded").font(ReadingType.bookTitle(28))
                    Text("No reading was recorded on this day.").font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                    Button("Browse this month", action: back).padding(.top, 8)
                }
                .padding(32).frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
                .background(ReadingPalette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 22))
            } else {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(summaryValue)
                                .font(ReadingType.bookTitle(44))
                            Text(summaryLabel)
                                .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                        }
                        Text(pageTurns > 0 ? "\(ReadingFormat.duration(total?.creditedSeconds ?? 0)) across \(bookContributions.count) \(bookContributions.count == 1 ? "book" : "books")" : "\(bookContributions.count) \(bookContributions.count == 1 ? "book" : "books")")
                            .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 6) {
                        if model.dailyGoal(on: dayKey).reached {
                            Label("Daily goal reached", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(ReadingPalette.accent).font(.callout.weight(.medium))
                        } else {
                            Text("Daily goal").font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                        }
                        Text(model.dailyGoal(on: dayKey).summary).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    }
                }
                .padding(.vertical, 12)
                ForEach(bookContributions) { contribution in
                    bookEntry(contribution)
                }
                Button("Back to month", action: back).controlSize(.small)
            }
        }
        .sheet(item: $reviewInterval) { interval in IntervalReviewEditor(model: model, interval: interval) }
    }

    private func bookEntry(_ contribution: HistoryBookContribution) -> some View {
        let book = model.books.first { $0.id == contribution.bookID }
        let bookSessions = sessions.filter { $0.bookID == contribution.bookID }
        let sessionIntervalIDs = Set(bookSessions.flatMap { $0.intervals.map(\.id) })
        let resolver = BookMergeResolver(merges: model.merges)
        // Keep hidden short visits and excluded spans reviewable without inflating session counts.
        let other = contributions.filter {
            resolver.resolvedID(for: $0.interval.bookID) == contribution.bookID && !sessionIntervalIDs.contains($0.interval.id)
        }
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 22) {
                BookCoverView(book: book, size: .library)
                VStack(alignment: .leading, spacing: 7) {
                    Text(book?.title ?? "Unknown book").font(ReadingType.bookTitle(25)).fixedSize(horizontal: false, vertical: true)
                    if let author = book?.author, !author.isEmpty {
                        Text(author).font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                    }
                    HStack(spacing: 14) {
                        if contribution.pageTurns > 0 {
                            Text(ReadingFormat.observedPages(contribution.pageTurns)).font(.callout.weight(.medium))
                        }
                        if contribution.creditedSeconds > 0 {
                            Text(ReadingFormat.duration(contribution.creditedSeconds)).font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                        }
                    }.padding(.top, 6)
                    if contribution.uncertainSeconds > 0 {
                        Text("\(ReadingFormat.duration(contribution.uncertainSeconds)) awaiting review")
                            .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    }
                }
                Spacer(minLength: 0)
            }
            if !bookSessions.isEmpty || !other.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(bookSessions) { session in
                            HistorySessionRow(model: model, session: session, dayKey: dayKey, period: period, review: { reviewInterval = $0 })
                        }
                        ForEach(other) { fragment in
                            HStack {
                                Text(HistoryDateFormat.time(max(fragment.interval.start, period.start), timezoneID: model.timezoneID)).font(.caption)
                                Text(fragment.interval.disposition == .excluded ? "Excluded from totals" : "Additional recorded time").font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                                Spacer()
                                Button("Review") { reviewInterval = fragment.interval }.controlSize(.small)
                            }
                        }
                    }.padding(.top, 14)
                } label: {
                    Text(bookSessions.isEmpty ? "Recorded details" : "\(bookSessions.count) \(bookSessions.count == 1 ? "session" : "sessions")")
                        .font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.secondaryInk)
                }
                .help("Short breaks stay in one session. Expand to see times and review recorded spans.")
            }
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(ReadingPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 20))
    }
}

@MainActor
private struct HistorySessionRow: View {
    @ObservedObject var model: AppModel
    let session: ReadingSessionGroup
    let dayKey: String
    let period: DateInterval
    let review: (ReadingInterval) -> Void
    private var fragments: [DayContribution] { DayContribution.forDay(dayKey, timezoneID: model.timezoneID, intervals: session.intervals) }
    private var credited: Double { fragments.filter { $0.interval.disposition == .credited }.reduce(0) { $0 + $1.clippedSeconds } }
    private var uncertain: Double { fragments.filter { $0.interval.disposition == .uncertain }.reduce(0) { $0 + $1.clippedSeconds } }
    private var sessionSummary: String {
        let pages = model.pages(in: session, from: period.start, through: period.end)
        let time = "\(ReadingFormat.duration(credited)) recorded"
        return pages > 0 ? "\(ReadingFormat.observedPages(pages)) · \(time)" : time
    }
    var body: some View {
        DisclosureGroup {
            VStack(spacing: 10) {
                ForEach(fragments) { fragment in
                    HStack {
                        Text("\(HistoryDateFormat.time(max(fragment.interval.start, period.start), timezoneID: model.timezoneID)) – \(HistoryDateFormat.time(min(fragment.interval.end, period.end), timezoneID: model.timezoneID))")
                            .font(.caption).monospacedDigit()
                        Spacer()
                        Text(ReadingFormat.duration(fragment.clippedSeconds)).font(.caption).monospacedDigit()
                        if fragment.interval.disposition != .credited {
                            Text(fragment.interval.disposition == .uncertain ? "Awaiting review" : "Excluded from totals")
                                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                        }
                        Button("Review") { review(fragment.interval) }.controlSize(.small)
                    }
                }
            }.padding(.leading, 12).padding(.vertical, 10)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(HistoryDateFormat.time(max(session.start, period.start), timezoneID: model.timezoneID)) – \(HistoryDateFormat.time(min(session.end, period.end), timezoneID: model.timezoneID))")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    Text(sessionSummary)
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
    static func weekday(_ date: Date, timezoneID: String) -> String { format(date, timezoneID: timezoneID, pattern: "EEE") }
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
