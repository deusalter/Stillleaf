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
            let center = CGPoint(x: size.width / 2, y: size.height * 0.53)
            let radius = min(size.width * 0.45, size.height * 0.48)
            let fraction = min(1, max(0, progress))
            let scale = Double(min(1, size.width / 254))
            for row in 0..<2 {
                let count = row == 0 ? 37 : 31
                let distance = radius - Double(row) * 16 * scale
                for index in 0..<count {
                    let position = Double(index) / Double(count - 1)
                    let angle = (140 + position * 260) * .pi / 180
                    let diameter: Double = (row == 0 ? 8 : 6) * scale
                    let x = center.x + cos(angle) * distance
                    let y = center.y + sin(angle) * distance
                    let dot = Path(ellipseIn: CGRect(x: x - diameter / 2, y: y - diameter / 2,
                                                    width: diameter, height: diameter))
                    context.fill(dot, with: .color(ReadingPalette.progressTrack.opacity(row == 0 ? 1 : 0.65)))
                    // A smooth leading edge follows the interpolated fraction.
                    let coverage = min(1, max(0, fraction * Double(count) - Double(index)))
                    if coverage > 0 {
                        context.fill(dot, with: .color((position < 0.58 ? ReadingPalette.moss : ReadingPalette.accent)
                            .opacity(coverage * (row == 0 ? 1 : 0.7))))
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
                        .fill(ReadingPalette.progressTrack)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2).fill(ReadingPalette.moss)
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
                DottedReadingArc(progress: progress)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: progress)
                    // Only real progress changes animate. Returning to Today
                    // must not replay earned progress from an empty ring.
                    .id("\(model.today.day)-\(daily.unit.rawValue)-\(goal ?? -1)")
                VStack(spacing: 1) {
                    Text(daily.displayValue)
                        .font(ReadingType.numeral(72))
                        .tracking(-1.5).monospacedDigit().minimumScaleFactor(0.55).lineLimit(1)
                    Text(daily.todayLabel)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(ReadingPalette.fadedInk)
                }
                .frame(width: 176).offset(y: 2)
            }
            .frame(width: 254, height: 250)
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
                    overviewStat(value: daily.unit == .pages ? ReadingFormat.duration(model.today.creditedSeconds) : model.todayPages.formatted(), title: daily.unit == .pages ? "Reading time" : "Pages read", symbol: daily.unit == .pages ? "clock" : "book", color: ReadingPalette.moss)
                    overviewStat(value: "\(model.dailyGoalStreak.current) \(model.dailyGoalStreak.current == 1 ? "day" : "days")", title: "Goal streak", symbol: "flame", color: ReadingPalette.accent)
                }
                ReadingWeekStrip(model: model)
                if model.dailyGoalStreak.provisional || model.today.uncertainSeconds > 0 {
                    Label("Some time is awaiting review", systemImage: "clock.badge.questionmark")
                        .font(.caption).foregroundStyle(ReadingPalette.ochre)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(28)
        .background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var goalTitle: String { daily.goalTitle }
    private var goalDetail: String { daily.goalDetail }
    private func overviewStat(value: String, title: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(ReadingPalette.fadedInk)
                .labelStyle(.titleAndIcon)
            Text(value).font(ReadingType.numeral(28)).monospacedDigit()
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
                    .font(.system(size: 10)).foregroundStyle(ReadingPalette.fadedInk)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(dates, id: \.self) { date in
                    let key = navigation.dayKey(for: date)
                    let daily = model.dailyGoal(on: key)
                    let fraction = daily.fraction
                    let today = key == model.today.day
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(ReadingPalette.progressTrack.opacity(0.65))
                            .frame(height: 24)
                            .overlay(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(ReadingPalette.moss.opacity(today ? 1 : 0.60))
                                    .frame(height: 24 * fraction)
                            }
                        Text(calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: date) - 1])
                            .font(.system(size: 10, weight: today ? .bold : .regular))
                            .foregroundStyle(today ? ReadingPalette.moss : ReadingPalette.fadedInk)
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
                    DottedReadingArc(progress: daily.fraction)
                        .animation(reduceMotion ? nil : ReadingMotion.selection, value: daily.fraction)
                    VStack(spacing: 2) {
                        Text(daily.displayValue)
                            .font(ReadingType.numeral(42))
                            .minimumScaleFactor(0.5).lineLimit(1)
                        Text(daily.todayLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ReadingPalette.secondaryInk)
                    }
                    .frame(width: 96).offset(y: 3)
                }
                .frame(width: 140, height: 138)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Today's reading")
                .accessibilityValue(daily.summary)

                VStack(alignment: .leading, spacing: 7) {
                    Text(daily.reached ? "Goal reached" : "Daily reading")
                        .font(ReadingType.bookTitle(20))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(daily.target == nil ? daily.targetText : "\(daily.targetText) daily goal")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(daily.unit == .pages ? ReadingFormat.duration(model.today.creditedSeconds) : "\(model.todayPages) pages",
                          systemImage: daily.unit == .pages ? "clock" : "book")
                        .font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.today.manualSeconds > 0 {
                Text("Includes \(ReadingFormat.duration(model.today.manualSeconds)) manual time")
                    .font(.caption2).foregroundStyle(ReadingPalette.secondaryInk)
            }
            if model.today.uncertainSeconds > 0 {
                Label("\(ReadingFormat.duration(model.today.uncertainSeconds)) awaiting review", systemImage: "clock.badge.questionmark")
                    .font(.caption2).foregroundStyle(ReadingPalette.ochre)
            } else if model.dailyGoalStreak.provisional {
                Text("Streak is provisional until pending time is reviewed.")
                    .font(.caption2).foregroundStyle(ReadingPalette.ochre)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityHint("Pages include tracked page turns and explicit manual corrections. Time is recorded separately.")
    }
}
