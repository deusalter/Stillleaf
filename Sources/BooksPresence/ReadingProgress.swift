import SwiftUI
import BooksCore

/// One animation drives the entire arc. No per-dot state, repeating timer or
/// full-dashboard transition is involved in updating a reading goal.
struct DottedReadingArc: View, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let geometry = RingGeometry(size: size)
            let fraction = min(1, max(0, progress))
            for (row, spec) in RingGeometry.rows.enumerated() {
                for index in 0..<spec.count {
                    let placed = geometry.dot(row: row, index: index)
                    let dot = Path(ellipseIn: CGRect(x: placed.center.x - placed.diameter / 2, y: placed.center.y - placed.diameter / 2,
                                                    width: placed.diameter, height: placed.diameter))
                    context.fill(dot, with: .color(ReadingPalette.track.opacity(spec.trackOpacity)))
                    // A smooth leading edge follows the interpolated fraction.
                    let coverage = min(1, max(0, fraction * Double(spec.count) - Double(index)))
                    if coverage > 0 {
                        context.fill(dot, with: .color(ReadingPalette.accent.opacity(coverage * spec.fillOpacity)))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct SegmentedReadingBar: View, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    var body: some View {
        GeometryReader { geometry in
            let segments = 24
            let gap = 3.0
            let width = max(1, (geometry.size.width - Double(segments - 1) * gap) / Double(segments))
            HStack(spacing: gap) {
                ForEach(0..<segments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ReadingPalette.track)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2).fill(ReadingPalette.accent)
                                .opacity(min(1, max(0, progress * Double(segments) - Double(index))))
                        }
                        .frame(width: width)
                }
            }
        }
    }
}

@MainActor
struct DailyReadingOverview: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var daily: DailyGoalProgress { model.todayGoal }
    private var goal: Double? { daily.target }
    private var progress: Double { daily.fraction }
    private var complete: Bool { daily.reached }

    var body: some View {
        HStack(spacing: 28) {
            ZStack {
                // The ring fills once when Today first appears, then only real progress changes
                // animate: returning to Today must not replay earned progress from an empty ring.
                GoalArc(progress: progress, key: "today.arc.\(ringIdentity)", reading: model.snapshot.phase == .reading,
                        change: .easeOut(duration: 0.24))
                    .id(ringIdentity)
                VStack(spacing: 1) {
                    CountingText(daily.displayValue, key: "today.value.\(daily.unit.rawValue)")
                        .font(ReadingType.numeral(72))
                        .tracking(-1.5).monospacedDigit().minimumScaleFactor(0.55).lineLimit(1)
                    Text(daily.todayLabel)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(ReadingPalette.secondaryInk)
                }
                .frame(width: 176).offset(y: 2)
            }
            .frame(width: 254, height: 250)
            .gardenRipple()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Today's reading")
            .accessibilityValue(daily.summary)
            .help("Goals use tracked pages or credited reading time, including manual records.")

            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(goalDetail).font(ReadingType.bookTitle(24))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 24) {
                    overviewStat(value: daily.unit == .pages ? ReadingFormat.duration(model.today.creditedSeconds) : model.todayPages.formatted(), title: daily.unit == .pages ? "Reading time" : "Pages read", symbol: daily.unit == .pages ? "clock" : "book", color: ReadingPalette.accent)
                    overviewStat(value: "\(model.dailyGoalStreak.current) \(model.dailyGoalStreak.current == 1 ? "day" : "days")", title: "Goal streak", symbol: "flame", color: ReadingPalette.accent)
                }
                ReadingWeekStrip(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .readingPanel()
    }

    private var ringIdentity: String { "\(model.today.day)-\(daily.unit.rawValue)-\(goal ?? -1)" }
    private var goalTitle: String { daily.goalTitle }
    private var goalDetail: String { daily.goalDetail }
    private func overviewStat(value: String, title: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(ReadingPalette.secondaryInk)
                .labelStyle(.titleAndIcon)
            CountingText(value, key: "today.stat.\(title)").font(ReadingType.numeral(28)).monospacedDigit()
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private struct ReadingWeekStrip: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let navigation = CalendarNavigation(timezoneID: model.timezoneID, scale: .week)
        let dates = navigation.weekDates
        let calendar = navigation.calendar
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("This week").font(.system(size: 11, weight: .medium)).foregroundStyle(ReadingPalette.secondaryInk)
                Spacer()
                Text("Best: \(model.dailyGoalStreak.longest) \(model.dailyGoalStreak.longest == 1 ? "day" : "days")")
                    .font(.system(size: 10)).foregroundStyle(ReadingPalette.secondaryInk)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(dates, id: \.self) { date in
                    let key = navigation.dayKey(for: date)
                    let daily = model.dailyGoal(on: key)
                    let fraction = daily.fraction
                    let today = key == model.today.day
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(ReadingPalette.track.opacity(0.65))
                            .frame(height: 24)
                            .overlay(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(ReadingPalette.accent.opacity(today ? 1 : 0.60))
                                    .frame(height: 24 * fraction)
                            }
                        Text(calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: date) - 1])
                            .font(.system(size: 10, weight: today ? .bold : .regular))
                            .foregroundStyle(today ? ReadingPalette.accent : ReadingPalette.secondaryInk)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(key): \(daily.summary)")
                    .help("\(ReadingFormat.day(key)): \(daily.summary)")
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: model.todayPages)
        }
    }
}

@MainActor
struct MenuReadingGoal: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var daily: DailyGoalProgress { model.todayGoal }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                ZStack {
                    GoalArc(progress: daily.fraction, key: "menu.arc.\(daily.unit.rawValue)", reading: model.snapshot.phase == .reading,
                            change: ReadingMotion.selection)
                    VStack(spacing: 2) {
                        CountingText(daily.displayValue, key: "menu.value.\(daily.unit.rawValue)")
                            .font(ReadingType.numeral(42))
                            .minimumScaleFactor(0.5).lineLimit(1)
                        Text(daily.todayLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ReadingPalette.secondaryInk)
                    }
                    .frame(width: 90).offset(y: 3)
                }
                .frame(width: 132, height: 116)
                .gardenRipple()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Today's reading")
                .accessibilityValue(daily.summary)

                VStack(alignment: .leading, spacing: 7) {
                    Text(daily.reached ? "Goal reached" : "Daily reading")
                        .font(ReadingType.bookTitle(19))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(daily.target == nil ? daily.targetText : "\(daily.targetText) daily goal")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(daily.unit == .pages ? ReadingFormat.duration(model.today.creditedSeconds) : "\(model.todayPages) pages",
                          systemImage: daily.unit == .pages ? "clock" : "book")
                        .font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.secondaryInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.today.manualSeconds > 0 {
                Text("Includes \(ReadingFormat.duration(model.today.manualSeconds)) manual time")
                    .font(.caption2).foregroundStyle(ReadingPalette.secondaryInk)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Pages include tracked page turns and explicit manual corrections. Time is recorded separately.")
    }
}
