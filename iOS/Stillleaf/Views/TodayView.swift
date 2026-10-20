import SwiftUI
import BooksCore

struct TodayView: View {
    @EnvironmentObject private var journal: Journal
    @Environment(\.openBook) private var open
    let showLibrary: () -> Void
    @State private var logging = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    goalCard
                    if let book = journal.continueReading, let edition = journal.edition(forBook: book.id) {
                        continueCard(book, edition)
                    } else if journal.editions.isEmpty {
                        emptyCard
                    }
                    weekCard
                    if let target = journal.history.annualBookGoal { yearCard(target) }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { logging = true } label: { Label("Log Reading", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $logging) { LogReadingView() }
        }
    }

    private var goalCard: some View {
        let progress = journal.todayGoal
        let streak = journal.history.dailyGoalStreak
        return HStack(spacing: 20) {
            ZStack {
                GoalRing(fraction: progress.fraction)
                if progress.reached {
                    Image(systemName: "checkmark").font(.title.weight(.semibold)).foregroundStyle(Color.accentColor)
                } else {
                    PageleafMark().fill(Color.accentColor.opacity(0.75)).frame(width: 34, height: 34)
                }
            }
            .frame(width: 104, height: 104)
            VStack(alignment: .leading, spacing: 6) {
                Text(ReadingText.goalValue(progress))
                    .font(.system(.title, design: .serif).weight(.semibold))
                    .monospacedDigit()
                if let target = ReadingText.goalTarget(progress) {
                    Text(progress.reached ? "Goal of \(target) reached" : "of \(target) today")
                        .foregroundStyle(.secondary)
                }
                Label(streak.current == 1 ? "1-day streak" : "\(streak.current)-day streak", systemImage: "flame")
                    .font(.subheadline)
                    .foregroundStyle(streak.current > 0 ? Color.accentColor : .secondary)
                if streak.longest > streak.current {
                    Text("Longest: \(streak.longest) days").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private func continueCard(_ book: BookRecord, _ edition: Edition) -> some View {
        Button { open(edition) } label: {
            HStack(spacing: 14) {
                BookCover(book: book, coverURL: edition.coverURL, maxPixels: 200).frame(width: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continue reading").font(.caption).foregroundStyle(.secondary)
                    Text(book.title).font(.system(.headline, design: .serif)).foregroundStyle(.primary).lineLimit(2)
                    if let location = journal.position(bookID: book.id)?.location {
                        Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "book").font(.title2).foregroundStyle(Color.accentColor)
            }
        }
        .buttonStyle(.plain)
        .card()
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Read your first book here").font(.system(.headline, design: .serif))
            Text("Import a DRM-free EPUB from Files, Mail or AirDrop. Time counts only while the book is open in front of you.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Go to Library", action: showLibrary).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// The last seven days against each day's goal.
    private var weekCard: some View {
        let calendar = journalCalendar
        let today = calendar.startOfDay(for: Date())
        let days = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        return VStack(alignment: .leading, spacing: 12) {
            Text("This week").font(.headline)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(days, id: \.self) { day in
                    let key = ReadingStatistics.dayKey(day, timezoneID: journal.timezoneID)
                    let fraction = journal.history.goalProgressByDay[key]?.fraction ?? 0
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.accentColor.opacity(fraction >= 1 ? 1 : 0.25 + 0.5 * fraction))
                            .frame(height: max(6, 64 * fraction))
                            .frame(height: 64, alignment: .bottom)
                        Text(day.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.narrow))).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement()
                    .accessibilityLabel(day.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.wide)))
                    .accessibilityValue("\(Int((fraction * 100).rounded())) percent of goal")
                }
            }
        }
        .card()
    }

    private func yearCard(_ target: Int) -> some View {
        let finished = journal.history.annualBooksFinished
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("This year").font(.headline)
                Spacer()
                Text("\(finished) of \(target) books").foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: Double(min(finished, target)), total: Double(max(1, target)))
        }
        .card()
    }

    private var journalCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: journal.timezoneID) ?? .current
        calendar.locale = .current
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }
}

extension View {
    func card() -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
