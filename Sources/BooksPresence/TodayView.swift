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
                        GoalProgressView(day: model.today)
                        if model.streak.todayPending {
                            Text("Today is still pending. Your streak through yesterday is preserved.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if model.streak.provisional {
                            Label("Your streak includes time awaiting review.", systemImage: "clock.badge.questionmark")
                                .font(.callout).foregroundStyle(ReadingPalette.ochre)
                        }
                    }
                    .readingPanel()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Goal streak").font(.headline)
                        Text("\(model.streak.current) days")
                            .font(.system(size: 36, weight: .medium, design: .serif))
                            .foregroundStyle(ReadingPalette.ink)
                        Text("Longest: \(model.streak.longest) days")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .readingPanel()
                }

                currentActivity
                HStack(spacing: 12) {
                    if model.manualActive {
                        Button("Stop manual reading") { model.stopManual() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Start manual reading") { present(.manualStart) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Add reading time") { present(.manualAdd) }
                        .buttonStyle(.bordered)
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
    }

    private var todaySubtitle: String {
        let day = ReadingFormat.day(model.today.day)
        if model.today.creditedSeconds == 0 {
            return "\(day) · no credited reading recorded yet"
        }
        return "\(day) · your recorded reading"
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
                    LabeledValue(label: "Session time", value: ReadingFormat.duration(model.snapshot.sessionSeconds))
                    LabeledValue(label: "Mode", value: model.snapshot.mode.rawValue.capitalized)
                }
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
    let day: DailyTotal
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily goal").font(.headline)
                Spacer()
                Text("\(ReadingFormat.duration(day.creditedSeconds)) / \(ReadingFormat.duration(day.goalMinutes * 60))")
                    .font(.callout).monospacedDigit().foregroundStyle(ReadingPalette.fadedInk)
            }
            ProgressView(value: day.creditedSeconds, total: max(1, day.goalMinutes * 60))
                .tint(day.qualifies ? ReadingPalette.moss : ReadingPalette.ochre)
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
                    VStack(spacing: 7) {
                        Image(systemName: "book.closed")
                            .font(.system(size: max(18, dimensions.width * 0.32)))
                        Text("Cover unavailable")
                            .font(.caption2).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(ReadingPalette.fadedInk)
                    .padding(5)
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
        case .paused: text = "Tracking paused"; symbol = "pause.circle"
        }
        return Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(snapshot.phase == .reading ? ReadingPalette.moss : ReadingPalette.fadedInk)
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
            Text(title).font(.system(size: 34, weight: .medium, design: .serif))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}

extension View {
    func readingPanel() -> some View {
        padding(20)
            .background(Color.white.opacity(0.46), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReadingPalette.ink.opacity(0.10)))
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
