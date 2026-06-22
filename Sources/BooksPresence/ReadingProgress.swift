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
                        context.fill(dot, with: .color((position < 0.58 ? ReadingPalette.moss : ReadingPalette.accentEnd)
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
    @State private var appeared = false
    private var goal: Int? { model.pageGoal(on: model.today.day) }
    private var progress: Double { goal.map { min(1, Double(model.todayPages) / Double(max(1, $0))) } ?? 0 }
    private var complete: Bool { goal.map { model.todayPages >= $0 && model.todayPages > 0 } ?? false }

    var body: some View {
        HStack(spacing: 28) {
            ZStack {
                DottedReadingArc(progress: appeared || reduceMotion ? progress : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.32), value: appeared)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: progress)
                VStack(spacing: 1) {
                    Text(model.todayPages.formatted())
                        .font(.system(size: 68, weight: .bold, design: .rounded))
                        .tracking(-3).monospacedDigit().minimumScaleFactor(0.55).lineLimit(1)
                    Text(model.todayPages == 1 ? "page today" : "pages today")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(ReadingPalette.fadedInk)
                }
                .frame(width: 176).offset(y: 2)
                Label(complete ? "Goal complete" : "Your daily pages", systemImage: complete ? "checkmark" : "book")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ReadingPalette.moss)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(ReadingPalette.moss.opacity(0.09), in: Capsule())
                    .offset(y: 99)
            }
            .frame(width: 254, height: 250)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Today's reading")
            .accessibilityValue(goal.map { "\(model.todayPages) pages; daily goal \($0) pages\(complete ? "; goal complete" : "")" } ?? "\(model.todayPages) pages; no daily goal")
            .help("Pages include tracked page turns and explicit manual corrections.")

            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(goalTitle).font(.system(size: 21, weight: .semibold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(goalDetail).font(.callout).foregroundStyle(ReadingPalette.fadedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 24) {
                    overviewStat(value: ReadingFormat.duration(model.today.creditedSeconds), title: "Reading time", symbol: "clock", color: ReadingPalette.moss)
                    overviewStat(value: "\(model.pageStreak.current) \(model.pageStreak.current == 1 ? "day" : "days")", title: "Goal streak", symbol: "flame", color: ReadingPalette.ochre)
                }
                ReadingWeekStrip(model: model)
                if model.pageStreak.provisional || model.today.uncertainSeconds > 0 {
                    Label("Some time is awaiting review", systemImage: "clock.badge.questionmark")
                        .font(.caption).foregroundStyle(ReadingPalette.ochre)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onAppear { appeared = true }
    }

    private var goalTitle: String {
        guard let goal else { return "A day in pages" }
        if complete { return "A good day for reading." }
        if model.todayPages == 0 { return "Your next chapter awaits." }
        let remaining = max(0, goal - model.todayPages)
        return "\(remaining) \(remaining == 1 ? "page" : "pages") to your goal."
    }
    private var goalDetail: String {
        guard let goal else { return "Choose a daily page goal in Settings." }
        if model.todayPages > goal { return "\(model.todayPages - goal) pages beyond your \(goal)-page goal." }
        if complete { return "You reached your \(goal)-page goal." }
        return "Your daily goal is \(goal) pages."
    }
    private func overviewStat(value: String, title: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(ReadingPalette.fadedInk)
                .labelStyle(.titleAndIcon)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
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
                Text("This week").font(.system(size: 11, weight: .medium))
                Spacer()
                Text("Best: \(model.pageStreak.longest) \(model.pageStreak.longest == 1 ? "day" : "days")")
                    .font(.system(size: 10)).foregroundStyle(ReadingPalette.fadedInk)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(dates, id: \.self) { date in
                    let key = navigation.dayKey(for: date)
                    let pages = model.pages(on: key)
                    let goal = model.pageGoal(on: key)
                    let fraction = goal.map { min(1, Double(pages) / Double(max(1, $0))) } ?? (pages > 0 ? 1 : 0)
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
                    .accessibilityLabel("\(key): \(pages) pages")
                    .help("\(ReadingFormat.day(key)): \(pages) pages")
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
    @State private var appeared = false
    private var goal: Int? { model.pageGoal(on: model.today.day) }
    private var progress: Double { goal.map { min(1, Double(model.todayPages) / Double(max(1, $0))) } ?? 0 }
    private var reached: Bool { goal.map { model.todayPages >= $0 } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    if goal != nil {
                        DottedReadingArc(progress: appeared || reduceMotion ? progress : 0)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: appeared)
                            .animation(reduceMotion ? nil : ReadingMotion.entrance, value: progress)
                    }
                    VStack(spacing: 1) {
                        Text(model.todayPages.formatted())
                            .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                            .minimumScaleFactor(0.5).lineLimit(1)
                        Text(model.todayPages == 1 ? "page today" : "pages today")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(ReadingPalette.fadedInk)
                    }.frame(width: 78).offset(y: 3)
                }.frame(width: 112, height: 110)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Today's reading")
                .accessibilityValue(goal.map { "\(model.todayPages) pages out of a \($0) page goal" } ?? "\(model.todayPages) pages; no goal")
                VStack(alignment: .leading, spacing: 6) {
                    Text(reached ? "Goal reached" : "Daily reading")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(goal.map { "\($0)-page goal\(model.todayPages > $0 ? " · +\(model.todayPages - $0)" : "")" } ?? "No goal set")
                        .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                    Label(ReadingFormat.duration(model.today.creditedSeconds), systemImage: "clock")
                        .font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.moss)
                    if model.today.manualSeconds > 0 {
                        Text("Includes \(ReadingFormat.duration(model.today.manualSeconds)) manual time")
                            .font(.caption2).foregroundStyle(ReadingPalette.fadedInk)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.today.uncertainSeconds > 0 {
                Label("\(ReadingFormat.duration(model.today.uncertainSeconds)) awaiting review", systemImage: "clock.badge.questionmark")
                    .font(.caption2).foregroundStyle(ReadingPalette.ochre)
            } else if model.pageStreak.provisional {
                Text("Streak is provisional until pending time is reviewed.")
                    .font(.caption2).foregroundStyle(ReadingPalette.ochre)
            }
        }
        .padding(14).background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .help("Pages include tracked page turns and explicit manual corrections. Time is recorded separately.")
        .onAppear { appeared = true }
    }
}
