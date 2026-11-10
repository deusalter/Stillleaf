import SwiftUI
import BooksCore

/// The first screen: the book being read, one tap from the page; then today's goal and streak,
/// and the other books in progress.
struct ReadingNowView: View {
    @EnvironmentObject private var journal: Journal
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        let shelf = journal.readingNow
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    if let book = shelf.first, let edition = journal.edition(forBook: book.id) {
                        CurrentBook(book: book, edition: edition)
                    } else {
                        EmptyShelf(hasBooks: !journal.editions.isEmpty)
                    }
                    TodayCard()
                    if shelf.count > 1 { UpNext(books: Array(shelf.dropFirst())) }
                    if let target = journal.history.annualBookGoal { YearCard(target: target, finished: journal.history.annualBooksFinished) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Reading Now")
            .toolbar { AppToolbar() }
        }
    }
}

/// The current book: its cover, where the reader is in it, and one button back to the page.
private struct CurrentBook: View {
    @EnvironmentObject private var journal: Journal
    @EnvironmentObject private var router: AppRouter
    let book: BookRecord
    let edition: Edition

    var body: some View {
        let position = journal.position(bookID: book.id)
        VStack(spacing: 18) {
            Button { router.open(edition) } label: {
                BookCover(book: book, coverURL: edition.coverURL, maxPixels: 720)
                    .frame(maxWidth: 200)
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(book.title)")
            VStack(spacing: 5) {
                Text(book.title)
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let author = book.author {
                    Text(author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let fraction = position?.fraction {
                VStack(spacing: 7) {
                    ProgressView(value: min(1, max(0, fraction)))
                        .frame(maxWidth: 220)
                    Text([ReadingText.percent(fraction), position?.location].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            Button { router.open(edition) } label: {
                Label(position == nil ? "Start Reading" : "Continue", systemImage: "book.fill")
                    .font(.headline)
                    .frame(maxWidth: 260)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }
}

/// Nothing to continue: import a book without leaving this screen.
private struct EmptyShelf: View {
    @EnvironmentObject private var router: AppRouter
    let hasBooks: Bool

    var body: some View {
        VStack(spacing: 14) {
            PageleafMark().fill(Color.accentColor).frame(width: 56, height: 56)
            Text(hasBooks ? "Pick your next book" : "Add your first book")
                .font(.system(.title2, design: .serif).weight(.semibold))
            Text(hasBooks ? "You have finished everything on this device. Import another EPUB, or open one again from your Library."
                          : "Import a DRM-free EPUB from Files, or share one to Stillleaf from Mail, Safari or AirDrop. Reading time counts while the book is open in front of you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { router.importing = true } label: {
                Label("Import EPUB", systemImage: "square.and.arrow.down").font(.headline).frame(maxWidth: 260).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if hasBooks {
                Button("Go to Library") { router.tab = .library }
            }
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }
}

/// Today's goal, the streak, and the last seven days as rings. Opens the Journal.
private struct TodayCard: View {
    @EnvironmentObject private var journal: Journal
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        let progress = journal.todayGoal
        let streak = journal.history.dailyGoalStreak
        Button { router.tab = .journal } label: {
            VStack(spacing: 16) {
                HStack(spacing: 18) {
                    ZStack {
                        GoalRing(fraction: progress.fraction, lineWidth: 10)
                        if progress.reached {
                            Image(systemName: "checkmark").font(.title3.weight(.bold)).foregroundStyle(Color.accentColor)
                        } else {
                            PageleafMark().fill(Color.accentColor.opacity(0.75)).frame(width: 26, height: 26)
                        }
                    }
                    .frame(width: 76, height: 76)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Today").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(ReadingText.goalValue(progress))
                            .font(.system(.title2, design: .serif).weight(.semibold))
                            .monospacedDigit()
                        if let target = ReadingText.goalTarget(progress) {
                            Text(progress.reached ? "Goal of \(target) reached" : "of \(target)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 2) {
                        Image(systemName: streak.current > 0 ? "flame.fill" : "flame")
                            .font(.title2)
                            .foregroundStyle(streak.current > 0 ? Color.accentColor : Color.secondary)
                        Text("\(streak.current)").font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit()
                        Text(streak.current == 1 ? "day" : "days").font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(streak.current)-day streak")
                }
                Divider()
                WeekRings()
            }
            .foregroundStyle(.primary)
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens your reading journal")
    }
}

/// The last seven days, each a small ring of that day's goal.
private struct WeekRings: View {
    @EnvironmentObject private var journal: Journal

    var body: some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: journal.timezoneID) ?? .current
        let today = calendar.startOfDay(for: Date())
        let days = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let weekday = Date.FormatStyle(timeZone: calendar.timeZone)
        return HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let key = ReadingStatistics.dayKey(day, timezoneID: journal.timezoneID)
                let progress = journal.history.goalProgressByDay[key]
                let isToday = day == today
                VStack(spacing: 6) {
                    ZStack {
                        GoalRing(fraction: progress?.fraction ?? 0, lineWidth: 4)
                        if progress?.reached == true {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(width: 28, height: 28)
                    Text(day.formatted(weekday.weekday(.narrow)))
                        .font(.caption2.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Color.primary : Color.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.formatted(weekday.weekday(.wide)))
                .accessibilityValue(progress?.reached == true ? "Goal reached" : "\(Int(((progress?.fraction ?? 0) * 100).rounded())) percent of goal")
            }
        }
    }
}

/// Other books in progress on this device.
private struct UpNext: View {
    @EnvironmentObject private var journal: Journal
    @EnvironmentObject private var router: AppRouter
    let books: [BookRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Also Reading").font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(books) { book in
                        if let edition = journal.edition(forBook: book.id) {
                            Button { router.open(edition) } label: { BookCard(book: book).frame(width: 104) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            }
            .padding(.horizontal, -20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct YearCard: View {
    let target: Int
    let finished: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("This Year").font(.headline)
                Spacer()
                Text("\(finished) of \(target) books").foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: Double(min(finished, target)), total: Double(max(1, target)))
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func card() -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
