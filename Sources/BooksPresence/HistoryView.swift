import SwiftUI
import BooksCore

@MainActor
struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var selectedDay: DailyTotal?

    private var weekSeconds: Double { totals.inCurrentWeek.reduce(0) { $0 + $1.creditedSeconds } }
    private var monthSeconds: Double { totals.inCurrentMonth.reduce(0) { $0 + $1.creditedSeconds } }
    private var totals: HistoryPeriodTotals { HistoryPeriodTotals(days: model.days, timezoneID: model.timezoneID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading(title: "History", subtitle: "Totals are built from credited interval fragments in your selected calendar timezone.")
                HStack(spacing: 16) {
                    HistoryMetric(title: "This week", value: ReadingFormat.duration(weekSeconds))
                    HistoryMetric(title: "This month", value: ReadingFormat.duration(monthSeconds))
                    HistoryMetric(title: "Recorded days", value: "\(model.days.filter { $0.creditedSeconds > 0 || $0.uncertainSeconds > 0 }.count)")
                }

                HistoryCalendar(days: model.days, open: { selectedDay = $0 })
                    .readingPanel()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Daily ledger").font(.system(.title2, design: .serif))
                    Text("Each row can be traced back to the sessions in Library and Review.")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.days.isEmpty {
                        ReadingEmptyState(title: "No recorded days", symbol: "calendar.badge.clock", message: "Reading time will appear here after a credited or uncertain interval is saved.")
                            .padding(.vertical, 32)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.days.reversed()) { day in
                                DailyLedgerRow(day: day, open: { selectedDay = day })
                                Divider()
                            }
                        }
                        .readingPanel()
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .sheet(item: $selectedDay) { day in
            DayDetailView(model: model, day: day)
        }
    }
}

struct HistoryPeriodTotals {
    let inCurrentWeek: [DailyTotal]
    let inCurrentMonth: [DailyTotal]

    init(days: [DailyTotal], timezoneID: String, now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezoneID) ?? .current
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let month = calendar.dateInterval(of: .month, for: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let dated = days.compactMap { day -> (DailyTotal, Date)? in
            guard let date = formatter.date(from: day.day) else { return nil }
            return (day, date)
        }
        inCurrentWeek = dated.filter { week?.contains($0.1) == true }.map(\.0)
        inCurrentMonth = dated.filter { month?.contains($0.1) == true }.map(\.0)
    }
}

struct HistoryMetric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(.title, design: .serif)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .readingPanel()
    }
}

struct HistoryCalendar: View {
    let days: [DailyTotal]
    let open: (DailyTotal) -> Void
    private let columns = Array(repeating: GridItem(.flexible(minimum: 58), spacing: 8), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reading calendar").font(.system(.title2, design: .serif))
                Spacer()
                LegendDot(color: ReadingPalette.moss, text: "Goal met")
                LegendDot(color: ReadingPalette.ochre, text: "Reading recorded")
                LegendDot(color: ReadingPalette.fadedInk.opacity(0.45), text: "Uncertain")
            }
            if days.isEmpty {
                Text("No calendar entries yet.").foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(days) { day in
                        CalendarDayCell(day: day, open: { open(day) })
                    }
                }
            }
        }
    }
}

struct LegendDot: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CalendarDayCell: View {
    let day: DailyTotal
    let open: () -> Void
    private var color: Color {
        if day.qualifies { return ReadingPalette.moss }
        if day.creditedSeconds > 0 { return ReadingPalette.ochre }
        if day.uncertainSeconds > 0 { return ReadingPalette.fadedInk.opacity(0.48) }
        return ReadingPalette.ink.opacity(0.08)
    }
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ReadingFormat.day(day.day)).font(.caption).lineLimit(1)
                Text(ReadingFormat.duration(day.creditedSeconds)).font(.caption2).monospacedDigit().lineLimit(1)
                if day.uncertainSeconds > 0 {
                    Image(systemName: "clock.badge.questionmark").font(.caption2)
                }
            }
            .foregroundStyle(day.creditedSeconds == 0 && day.uncertainSeconds == 0 ? .secondary : Color.white)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .padding(7)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day.day): \(ReadingFormat.duration(day.creditedSeconds)) credited\(day.uncertainSeconds > 0 ? ", \(ReadingFormat.duration(day.uncertainSeconds)) awaiting review" : "")")
    }
}

struct DailyLedgerRow: View {
    let day: DailyTotal
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ReadingFormat.day(day.day)).font(.headline)
                    Text(day.qualifies ? "Goal met" : "Goal \(ReadingFormat.duration(day.goalMinutes * 60))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                LabeledValue(label: "Credited", value: ReadingFormat.duration(day.creditedSeconds))
                if day.manualSeconds > 0 { LabeledValue(label: "Manual", value: ReadingFormat.duration(day.manualSeconds)) }
                if day.uncertainSeconds > 0 { LabeledValue(label: "Awaiting review", value: ReadingFormat.duration(day.uncertainSeconds)) }
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show contributing records for \(day.day)")
    }
}

@MainActor
struct DayDetailView: View {
    @ObservedObject var model: AppModel
    let day: DailyTotal
    @Environment(\.dismiss) private var dismiss
    @State private var reviewInterval: ReadingInterval?

    private var contributions: [DayContribution] {
        DayContribution.forDay(day.day, timezoneID: model.timezoneID, intervals: model.displayIntervals)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ReadingFormat.day(day.day)).font(.system(.title2, design: .serif))
                    Text("Records contributing to this calendar day").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        HistoryMetric(title: "Credited", value: ReadingFormat.duration(day.creditedSeconds))
                        HistoryMetric(title: "Manual", value: ReadingFormat.duration(day.manualSeconds))
                        HistoryMetric(title: "Awaiting review", value: ReadingFormat.duration(day.uncertainSeconds))
                    }
                    Text("A span crossing midnight is clipped to this day. Its displayed contribution uses the same duration proportion as the daily total.")
                        .font(.callout).foregroundStyle(.secondary)

                    if contributions.isEmpty {
                        ReadingEmptyState(title: "No contributing records", symbol: "clock", message: "No saved reading span overlaps this calendar day.")
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(contributions) { contribution in
                                DayContributionRow(model: model, contribution: contribution, review: { reviewInterval = contribution.interval })
                                Divider()
                            }
                        }
                        .readingPanel()
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 680, height: 620)
        .background(ReadingPalette.paper)
        .tint(ReadingPalette.moss)
        .sheet(item: $reviewInterval) { interval in
            IntervalReviewEditor(model: model, interval: interval)
        }
    }
}

struct DayContribution: Identifiable {
    let interval: ReadingInterval
    let clippedSeconds: TimeInterval
    var id: String { interval.id }

    static func forDay(_ key: String, timezoneID: String, intervals: [ReadingInterval]) -> [DayContribution] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezoneID) ?? .current
        let components = key.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3,
              let dayStart = calendar.date(from: DateComponents(year: components[0], month: components[1], day: components[2])),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return intervals.compactMap { interval in
            let overlapStart = max(interval.start, dayStart)
            let overlapEnd = min(interval.end, dayEnd)
            if overlapEnd > overlapStart {
                let wallSeconds = interval.end.timeIntervalSince(interval.start)
                let clipped = wallSeconds > 0 ? interval.duration * overlapEnd.timeIntervalSince(overlapStart) / wallSeconds : interval.duration
                return DayContribution(interval: interval, clippedSeconds: clipped)
            }
            if interval.start == interval.end && interval.start >= dayStart && interval.start < dayEnd {
                return DayContribution(interval: interval, clippedSeconds: interval.duration)
            }
            return nil
        }
        .sorted { $0.interval.start > $1.interval.start }
    }
}

@MainActor
struct DayContributionRow: View {
    @ObservedObject var model: AppModel
    let contribution: DayContribution
    let review: () -> Void

    private var book: BookRecord? { model.books.first { $0.id == contribution.interval.bookID } }
    private var treatment: String {
        switch contribution.interval.disposition {
        case .credited: return contribution.interval.mode == .manual ? "Manual credited" : "Credited"
        case .uncertain: return "Awaiting review"
        case .excluded: return "Excluded from totals"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BookCoverView(book: book, size: .compact)
            VStack(alignment: .leading, spacing: 4) {
                Text(book?.title ?? "Unknown book").font(.headline)
                Text("Full span: \(ReadingFormat.date(contribution.interval.start)) – \(ReadingFormat.date(contribution.interval.end))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(treatment) on this day: \(ReadingFormat.duration(contribution.clippedSeconds))")
                    .font(.callout).monospacedDigit()
            }
            Spacer(minLength: 0)
            Button("Review", action: review).controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
