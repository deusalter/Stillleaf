import SwiftUI
import BooksCore

@MainActor
struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var navigation: CalendarNavigation
    private let benchmarkReady: ((HistoryAtlasKey) -> Void)?
    @State private var editingInterval: ReadingInterval?
    @StateObject private var atlas = HistoryAtlasController()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, initialScale: CalendarScale = .month, anchor: Date = Date(), benchmarkReady: ((HistoryAtlasKey) -> Void)? = nil) {
        self.model = model
        self.benchmarkReady = benchmarkReady
        _navigation = State(initialValue: CalendarNavigation(timezoneID: model.timezoneID, anchor: anchor, scale: initialScale))
    }
    private var dark: Bool { scheme == .dark }
    private var requestedNavigation: CalendarNavigation {
        var requested = navigation
        requested.timezoneID = model.timezoneID
        return requested
    }
    private var requestKey: HistoryAtlasKey? {
        model.historyAtlasSource.map { HistoryAtlasKey(source: $0, navigation: requestedNavigation) }
    }
    var body: some View {
        // Resolve the request once for this render. Repeated computed-property
        // reads otherwise rebuild calendars/period keys in both adaptive layouts.
        let requested = requestedNavigation
        let source = model.historyAtlasSource
        let request = source.map { HistoryAtlasKey(source: $0, navigation: requested) }
        let displayed = atlas.displayed
        let visible = displayed.flatMap { candidate in
            request.flatMap { candidate.canRetain(for: $0) ? candidate.navigation : nil }
        } ?? requested
        let visibleTitle = Self.title(for: visible)
        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("History").font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) { periodTitle(visibleTitle); Spacer(minLength: 16); navigationButtons }
                    VStack(alignment: .leading, spacing: 14) { periodTitle(visibleTitle); navigationButtons }
                }
                if let displayed {
                    historyContent(displayed, request: request, requested: requested)
                } else {
                    ProgressView("Preparing \(visibleTitle)…").controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                        .padding(.top, 20)
                }
                Text(model.timezoneID.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2).foregroundStyle(ReadingPalette.secondaryInk).help("History dates and times use this timezone.")
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .glassSurface(cornerRadius: ReadingMetrics.Radius.control)
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, 32).padding(.vertical, 30).frame(maxWidth: .infinity, alignment: .top)
        }
        .foregroundStyle(ReadingPalette.ink).tint(ReadingPalette.accent)
        .onChange(of: model.timezoneID) { navigation.timezoneID = $0 }
        .task(id: request) {
            guard let source else { return }
            await atlas.load(source: source, navigation: requested, reduceMotion: reduceMotion)
        }
        .sheet(item: $editingInterval) { interval in ReadingSessionEditor(model: model, interval: interval) }
    }
    private func historyContent(_ displayed: HistoryAtlasDisplay, request: HistoryAtlasKey?, requested: CalendarNavigation) -> some View {
        let prepared = displayed.presentation
        let canReveal = request.map { displayed.canRetain(for: $0) } ?? false
        let current = prepared.key == request
        let periodID = "\(prepared.key.scale.rawValue)-\(prepared.key.period.start)-\(prepared.key.timezoneID)"
        let dailyGoal = prepared.key.scale == .day
            ? model.dailyGoal(on: displayed.navigation.dayKey(for: prepared.key.period.start)) : nil
        return VStack(alignment: .leading, spacing: 26) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 25) {
                    summary(pages: prepared.pages, seconds: prepared.creditedSeconds, activeDays: prepared.activeDays, scale: displayed.navigation.scale)
                    Spacer(minLength: 0); goal(dailyGoal)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 22) { summary(pages: prepared.pages, seconds: prepared.creditedSeconds, activeDays: prepared.activeDays, scale: displayed.navigation.scale) }
                    goal(dailyGoal)
                }
            }
            .opacity(canReveal ? 1 : 0).accessibilityHidden(!canReveal)
            ZStack(alignment: .topLeading) {
                chart(displayed)
                    .id(periodID)
                    .transition(reduceMotion ? .identity : .opacity)
                    .onAppear { reportReady(prepared.key) }
                    .onChange(of: prepared.key) { reportReady($0) }
            }
            // Only the chart swaps with a fade. Its last footprint stays in the
            // scroll view while pending; summary/header geometry never animates.
            .animation(reduceMotion || !displayed.animatesPeriodChange ? nil : ReadingMotion.entrance, value: periodID)
            .opacity(canReveal ? (current ? 1 : 0.55) : 0)
            .disabled(!current).allowsHitTesting(current)
            .accessibilityHidden(!canReveal)
        }
        .overlay(alignment: .topLeading) {
            if !current {
                ProgressView("Updating to \(Self.title(for: requested))…")
                    .controlSize(.small).font(.callout)
                    .padding(12)
                    .background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("history-updating")
            }
        }
    }
    @ViewBuilder private func chart(_ displayed: HistoryAtlasDisplay) -> some View {
        let committed = displayed.navigation
        let prepared = displayed.presentation
        switch committed.scale {
        case .day:
            AtlasDayView(navigation: committed, presentation: prepared, editSession: { editingInterval = $0 })
        case .week:
            AtlasWeekView(navigation: committed, presentation: prepared, select: { selectDay($0) })
        case .month:
            AtlasMonthView(navigation: committed, presentation: prepared, select: { selectDay($0) })
        case .year:
            AtlasYearView(navigation: committed, presentation: prepared, select: { selectDay($0) }, selectMonth: { navigation.select($0, scale: .month) })
        }
    }
    private func reportReady(_ key: HistoryAtlasKey) {
        guard key == requestKey else { return }
        benchmarkReady?(key)
    }
    private func periodTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 30, weight: .regular, design: .serif)).tracking(-0.7)
            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }
    static func title(for navigation: CalendarNavigation) -> String {
        let period = navigation.period
        func format(_ date: Date, _ pattern: String) -> String {
            DateText.string(date, zone: navigation.timezoneID, pattern: pattern)
        }
        switch navigation.scale {
        case .day: return format(period.start, "EEEE, MMMM d, yyyy")
        case .week:
            let calendar = navigation.calendar
            let finalDay = calendar.date(byAdding: .day, value: -1, to: period.end) ?? period.end
            let sameYear = calendar.component(.year, from: period.start) == calendar.component(.year, from: finalDay)
            return "\(format(period.start, sameYear ? "MMM d" : "MMM d, yyyy")) – \(format(finalDay, "MMM d, yyyy"))"
        case .month: return format(period.start, "MMMM yyyy")
        case .year: return format(period.start, "yyyy")
        }
    }
    private var navigationButtons: some View {
        HistoryNavigationControls(navigation: $navigation, canMoveForward: canMoveForward)
    }
    @ViewBuilder private func summary(pages: Int, seconds: Double, activeDays: Int, scale: CalendarScale) -> some View {
        if pages > 0 { metric(pages.formatted(), "pages") }
        metric(ReadingFormat.duration(seconds), "recorded")
        if scale != .day { metric("\(activeDays)", activeDays == 1 ? "active day" : "active days") }
    }
    private func metric(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.system(size: 20, weight: .medium)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
        }.accessibilityElement(children: .combine)
    }
    @ViewBuilder private func goal(_ progress: DailyGoalProgress?) -> some View {
        if let progress {
            Text(progress.reached ? "✓ Daily goal reached" : progress.summary).font(.caption)
                .foregroundStyle(ReadingPalette.accent).accessibilityLabel("Daily goal: \(progress.summary)")
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
