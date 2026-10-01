import SwiftUI
import BooksCore

@MainActor
struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var navigation: CalendarNavigation
    private let benchmarkReady: ((HistoryAtlasKey) -> Void)?
    @State private var reviewInterval: ReadingInterval?
    @StateObject private var atlas = HistoryAtlasController()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, initialScale: CalendarScale = .month, anchor: Date = Date(), benchmarkReady: ((HistoryAtlasKey) -> Void)? = nil) {
        self.model = model
        self.benchmarkReady = benchmarkReady
        _navigation = State(initialValue: CalendarNavigation(timezoneID: model.timezoneID, anchor: anchor, scale: initialScale))
    }
    private var dark: Bool { scheme == .dark }
    private var requestKey: HistoryAtlasKey? {
        model.historyAtlasSource.map { HistoryAtlasKey(source: $0, navigation: navigation) }
    }
    private var presentation: HistoryAtlasPeriod? {
        guard let prepared = atlas.presentation, let requested = requestKey,
              prepared.key.timezoneID == requested.timezoneID, prepared.key.scale == requested.scale,
              prepared.key.period == requested.period, prepared.key.today == requested.today,
              prepared.key.localeID == requested.localeID else { return nil }
        // Keep this period's last committed snapshot during an archive refresh so
        // month/day selection survives. A different period never displays old data.
        return prepared
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("History").font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) { periodTitle; Spacer(minLength: 16); navigationButtons }
                    VStack(alignment: .leading, spacing: 14) { periodTitle; navigationButtons }
                }
                if let prepared = presentation {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 25) { summary(pages: prepared.pages, seconds: prepared.creditedSeconds, activeDays: prepared.activeDays); Spacer(minLength: 0); goal }
                        VStack(alignment: .leading, spacing: 12) { HStack(spacing: 22) { summary(pages: prepared.pages, seconds: prepared.creditedSeconds, activeDays: prepared.activeDays) }; goal }
                    }
                    Group {
                        switch navigation.scale {
                        case .day:
                            AtlasDayView(navigation: navigation, presentation: prepared, review: { reviewInterval = $0 })
                        case .week:
                            AtlasWeekView(navigation: navigation, presentation: prepared, select: { selectDay($0) })
                        case .month:
                            AtlasMonthView(navigation: navigation, presentation: prepared, select: { selectDay($0) })
                        case .year:
                            AtlasYearView(navigation: navigation, presentation: prepared, select: { selectDay($0) }, selectMonth: { navigation.select($0, scale: .month) })
                        }
                    }.id("\(navigation.scale.rawValue)-\(navigation.periodStart)-\(model.timezoneID)")
                        .transition(reduceMotion ? .identity : .opacity)
                        .onAppear { benchmarkReady?(prepared.key) }
                } else {
                    ProgressView("Preparing history…").controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                        .padding(.top, 20)
                }
                Text(model.timezoneID.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2).foregroundStyle(AtlasStyle.muted(dark)).help("History dates and times use this timezone.")
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, 32).padding(.vertical, 30).frame(maxWidth: .infinity, alignment: .top)
        }
        .background(AtlasStyle.canvas(dark)).foregroundStyle(AtlasStyle.ink(dark)).tint(AtlasStyle.accent(dark))
        .onChange(of: model.timezoneID) { navigation.timezoneID = $0 }
        .task(id: requestKey) {
            guard let source = model.historyAtlasSource else { return }
            await atlas.load(source: source, navigation: navigation, reduceMotion: reduceMotion)
        }
        .sheet(item: $reviewInterval) { interval in IntervalReviewEditor(model: model, interval: interval) }
    }
    private var periodTitle: some View {
        Text(navigation.scale == .day ? AtlasStyle.date(navigation.periodStart, zone: model.timezoneID, pattern: "EEEE, MMMM d, yyyy") : navigation.title)
            .font(.system(size: 30, weight: .regular, design: .serif)).tracking(-0.7)
            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }
    private var navigationButtons: some View {
        HStack(spacing: 7) {
            Menu {
                Picker("Timescale", selection: Binding(get: { navigation.scale }, set: { navigation.setScale($0) })) {
                    ForEach(CalendarScale.allCases) { scale in Text(scale.title).tag(scale) }
                }.pickerStyle(.inline)
            } label: {
                Text(navigation.scale.title).font(.system(size: 12, weight: .medium))
            }.menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("History timescale").accessibilityValue(navigation.scale.title)
                .help("Choose day, week, month, or year")
            Rectangle().fill(AtlasStyle.rule(dark)).frame(width: 1, height: 16).padding(.horizontal, 4)
                .accessibilityHidden(true)
            Button { navigation.move(by: -1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous \(navigation.scale.title.lowercased())")
            Button { if canMoveForward { navigation.move(by: 1) } } label: { Image(systemName: "chevron.right") }
                .disabled(!canMoveForward).accessibilityLabel("Next \(navigation.scale.title.lowercased())")
            Button("Today") { navigation.goToToday() }
        }.buttonStyle(AtlasButtonStyle())
    }
    @ViewBuilder private func summary(pages: Int, seconds: Double, activeDays: Int) -> some View {
        if pages > 0 { metric(pages.formatted(), "pages") }
        metric(ReadingFormat.duration(seconds), "recorded")
        if navigation.scale != .day { metric("\(activeDays)", activeDays == 1 ? "active day" : "active days") }
    }
    private func metric(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.system(size: 20, weight: .medium)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(AtlasStyle.muted(dark))
        }.accessibilityElement(children: .combine)
    }
    @ViewBuilder private var goal: some View {
        if navigation.scale == .day {
            let progress = model.dailyGoal(on: navigation.dayKey(for: navigation.periodStart))
            Text(progress.reached ? "✓ Daily goal reached" : progress.summary).font(.caption)
                .foregroundStyle(AtlasStyle.accent(dark)).accessibilityLabel("Daily goal: \(progress.summary)")
        }
    }
    private var canMoveForward: Bool {
        navigation.periodStart < CalendarNavigation(timezoneID: model.timezoneID, scale: navigation.scale).periodStart
    }
    private func selectDay(_ date: Date) {
        guard date <= navigation.calendar.startOfDay(for: Date()) else { return }
        navigation.select(date, scale: .day)
    }
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
