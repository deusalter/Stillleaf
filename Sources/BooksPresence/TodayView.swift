import SwiftUI
import BooksCore

@MainActor
struct TodayView: View {
    @ObservedObject var model: AppModel
    let present: (DashboardSheet) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading(title: "Today", subtitle: todaySubtitle)
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 16) {
                        GoalProgressView(model: model, day: model.today)
                        if model.pageStreak.todayPending {
                            Text("Today is still pending. Your page-goal streak through yesterday is preserved.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if model.pageStreak.provisional {
                            Label("Your page-goal streak includes activity awaiting review.", systemImage: "clock.badge.questionmark")
                                .font(.callout).foregroundStyle(ReadingPalette.ochre)
                        }
                    }
                    .readingPanel()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Page-goal streak").font(.headline)
                        Text("\(model.pageStreak.current) days")
                            .font(.system(size: 36, weight: .medium, design: .serif))
                            .foregroundStyle(ReadingPalette.ink)
                        Text("Longest: \(model.pageStreak.longest) days")
                            .foregroundStyle(.secondary)
                        Text("Time remains available in your history.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .readingPanel()
                }

                currentActivity
                if let entry = model.pendingCompletion, model.snapshot.phase != .reading, !model.manualActive {
                    FinishedBookPrompt(model: model, entry: entry)
                }
                HStack(spacing: 12) {
                    if model.manualActive {
                        Button("Stop manual reading") { model.stopManual() }
                            .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                    } else {
                        Button("Start manual reading") { present(.manualStart) }
                            .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                    }
                    Button("Add reading time") { present(.manualAdd) }
                        .buttonStyle(ReadingButtonStyle(emphasis: .secondary))
                }
                Text("Manual records are identified separately in history.")
                    .font(.callout).foregroundStyle(.secondary)

                if !model.uncertainIntervals.isEmpty {
                    UncertainNotice(count: model.uncertainIntervals.count) { present(.review(model.uncertainIntervals[0])) }
                }
            }
            .padding(32)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .buttonStyle(ReadingButtonStyle())
    }

    private var todaySubtitle: String {
        let day = ReadingFormat.day(model.today.day)
        if model.todayPages == 0 {
            if model.today.creditedSeconds > 0 {
                return "\(day) · recorded time, no pages"
            }
            return "\(day) · no pages recorded yet"
        }
        return "\(day) · \(ReadingFormat.observedPages(model.todayPages))"
    }

    private var currentActivity: some View {
        HStack(alignment: .top, spacing: 18) {
            BookCoverView(book: model.snapshot.book, size: .large)
            VStack(alignment: .leading, spacing: 7) {
                Text("Current activity").font(.headline)
                Text(model.snapshot.book?.title ?? "No active book")
                    .font(.system(.title2, design: .serif))
                if let author = model.snapshot.book?.author, !author.isEmpty {
                    Text(author).foregroundStyle(.secondary)
                }
                ActivityStateLabel(snapshot: model.snapshot)
                HStack(spacing: 20) {
                    LabeledValue(label: "Session pages", value: ReadingFormat.observedPages(model.sessionPages))
                    if let page = model.currentPageText {
                        LabeledValue(label: "Current page", value: page)
                    }
                    if let pace = ReadingFormat.pagesPerMinute(model.sessionPagesPerMinute) {
                        LabeledValue(label: "Session pace", value: pace)
                    }
                    LabeledValue(label: "Session time", value: ReadingFormat.duration(model.snapshot.sessionSeconds))
                    LabeledValue(label: "Mode", value: model.snapshot.mode.rawValue.capitalized)
                }
                Text("Pages include automatic observations and labeled manual corrections. Time is recorded separately.")
                    .font(.caption).foregroundStyle(.secondary)
                if let reason = model.snapshot.pauseReason, model.snapshot.phase == .paused {
                    Text("Paused because \(pauseDescription(reason)).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .readingPanel()
    }
}

struct GoalProgressView: View {
    @ObservedObject var model: AppModel
    let day: DailyTotal
    private var observedPages: Int { model.pages(on: day.day) }
    private var pageGoal: Int? { model.pageGoal(on: day.day) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily page goal").font(.headline)
                Spacer()
                Text(pageGoal.map { "\(ReadingFormat.observedPages(observedPages)) / \($0) page goal" } ?? ReadingFormat.observedPages(observedPages))
                    .font(.callout).monospacedDigit().foregroundStyle(ReadingPalette.fadedInk)
            }
            if let pageGoal {
                ProgressView(value: Double(observedPages), total: Double(max(1, pageGoal)))
                    .tint(observedPages >= pageGoal ? ReadingPalette.moss : ReadingPalette.ochre)
            } else {
                Text("No page goal recorded for this day.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Includes observed pages and manual corrections.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Recorded time: \(ReadingFormat.duration(day.creditedSeconds))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if day.manualSeconds > 0 || day.uncertainSeconds > 0 {
                HStack(spacing: 14) {
                    if day.manualSeconds > 0 { Text("Manual: \(ReadingFormat.duration(day.manualSeconds))") }
                    if day.uncertainSeconds > 0 { Text("Awaiting review: \(ReadingFormat.duration(day.uncertainSeconds))") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct BookCoverView: View {
    enum Size { case compact, large, library }
    let book: BookRecord?
    let size: Size

    private var dimensions: CGSize {
        switch size {
        case .compact: return CGSize(width: 52, height: 72)
        case .large: return CGSize(width: 104, height: 148)
        case .library: return CGSize(width: 72, height: 104)
        }
    }

    var body: some View {
        Group {
            if let path = book?.coverPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    ReadingPalette.parchment
                    HStack(spacing: 0) {
                        Rectangle().fill(ReadingPalette.moss.opacity(0.3)).frame(width: 6)
                        Rectangle().fill(ReadingPalette.ink.opacity(0.08)).frame(width: 1)
                        Spacer()
                    }
                    VStack(spacing: 8) {
                        Image(systemName: "book.closed")
                            .font(.system(size: max(16, dimensions.width * 0.22), weight: .light))
                        if size != .compact {
                            Text(book?.title ?? "Your next read")
                                .font(.system(size: size == .large ? 13 : 11, weight: .medium, design: .serif))
                                .multilineTextAlignment(.center).lineLimit(3)
                        }
                    }
                    .foregroundStyle(ReadingPalette.ink.opacity(0.78))
                    .padding(.leading, 7).padding(8)
                }
            }
        }
        .frame(width: dimensions.width, height: dimensions.height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(ReadingPalette.ink.opacity(0.13)))
        .accessibilityLabel(book?.coverPath == nil ? "Cover unavailable" : "Book cover")
    }
}

struct ActivityStateLabel: View {
    let snapshot: TrackerSnapshot
    var body: some View {
        let text: String
        let symbol: String
        switch snapshot.phase {
        case .reading: text = "Recording inferred reading activity"; symbol = "record.circle"
        case .uncertain: text = "Time awaiting review"; symbol = "clock.badge.questionmark"
        case .paused: text = "Paused • \(activityPauseSummary(snapshot.pauseReason))"; symbol = "pause.circle"
        }
        return Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(snapshot.phase == .reading ? ReadingPalette.moss : ReadingPalette.fadedInk)
            .accessibilityLabel(snapshot.phase == .paused ? "Tracking paused: \(activityPauseSummary(snapshot.pauseReason))" : text)
    }
}

private func activityPauseSummary(_ reason: PauseReason?) -> String {
    switch reason {
    case .disabled: return "Tracking turned off"
    case .background: return "Books in background"
    case .noReadingWindow: return "No active reading window"
    case .locked: return "Mac locked"
    case .displayAsleep: return "Display asleep"
    case .permissionLost: return "Accessibility access needed"
    case .excludedBook: return "Book excluded"
    case .stopped: return "Session stopped"
    case .captureFailure: return "Reader needs attention"
    case .recovery: return "Recovering"
    case .clockDiscontinuity: return "Clock changed"
    case nil: return "Waiting for reading"
    }
}

struct UncertainNotice: View {
    let count: Int
    let review: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark").foregroundStyle(ReadingPalette.ochre)
            Text("\(count) interval\(count == 1 ? "" : "s") need review before they count toward your totals.")
            Spacer()
            Button("Review", action: review)
        }
        .font(.callout)
        .padding(14)
        .background(ReadingPalette.ochre.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct CompactMetric: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.headline, design: .serif)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

struct LabeledValue: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 30, weight: .medium, design: .serif))
            Text(subtitle).font(.callout).foregroundStyle(ReadingPalette.fadedInk)
        }
    }
}

extension View {
    func readingPanel() -> some View {
        padding(20)
            .background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReadingPalette.border.opacity(0.7)))
    }
}

func pauseDescription(_ reason: PauseReason) -> String {
    switch reason {
    case .disabled: return "tracking is disabled"
    case .background: return "Books is in the background"
    case .noReadingWindow: return "there is no verified reading window"
    case .locked: return "your Mac is locked"
    case .displayAsleep: return "the display is asleep"
    case .permissionLost: return "Accessibility permission is unavailable"
    case .excludedBook: return "this book is excluded from tracking"
    case .stopped: return "the session was stopped"
    case .captureFailure: return "capture did not provide a verified reader"
    case .recovery: return "the app recovered after an interruption"
    case .clockDiscontinuity: return "the clock changed unexpectedly"
    }
}
