import SwiftUI
import BooksCore

/// The reading journal: a calendar of days and sessions, finished books by year, and private reviews.
struct JournalView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        NavigationStack {
            Group {
                switch router.journalMode {
                case .calendar: CalendarHistory()
                case .finished: FinishedTimeline()
                case .reviews: ReviewsList()
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("View", selection: $router.journalMode) {
                    ForEach(AppRouter.JournalMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .background(.bar)
            }
            .navigationTitle("Journal")
            .toolbar { AppToolbar() }
            .navigationDestination(for: String.self) { BookDetailView(bookID: $0) }
        }
    }
}

/// Streaks and totals at a glance, above the calendar.
private struct JournalSummary: View {
    @EnvironmentObject private var journal: Journal

    var body: some View {
        let streak = journal.history.dailyGoalStreak
        let week = journal.history.days.suffix(7).reduce(0) { $0 + $1.creditedSeconds }
        HStack(spacing: 0) {
            stat("\(streak.current)", "day streak", symbol: "flame.fill")
            Divider().frame(height: 34)
            stat("\(streak.longest)", "longest", symbol: "trophy.fill")
            Divider().frame(height: 34)
            stat(ReadingText.duration(week), "last 7 days", symbol: "clock.fill")
        }
        .padding(.vertical, 4)
    }

    private func stat(_ value: String, _ caption: String, symbol: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.footnote).foregroundStyle(Color.accentColor)
            Text(value).font(.system(.headline, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A month of daily goal progress, then the selected day's sessions.
private struct CalendarHistory: View {
    @EnvironmentObject private var journal: Journal
    @State private var month = Date()
    @State private var selected = Date()
    @State private var deleting: ReadingSessionGroup?

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: journal.timezoneID) ?? .current
        calendar.locale = .current
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }

    var body: some View {
        let selectedKey = ReadingStatistics.dayKey(selected, timezoneID: journal.timezoneID)
        let sessions = journal.sessions(onDay: selectedKey)
        List {
            Section { JournalSummary() }
            Section { monthGrid }
            Section {
                daySummary(selectedKey)
                ForEach(sessions) { session in
                    SessionRow(session: session)
                        .swipeActions {
                            Button("Delete", role: .destructive) { deleting = session }
                        }
                }
            } header: {
                Text(selected.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: calendar.timeZone)))
            } footer: {
                if !sessions.isEmpty { Text("Swipe a session to delete it.") }
            }
        }
        .confirmationDialog("Delete this session?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { session in
            Button("Delete Session", role: .destructive) { journal.deleteSession(session.id) }
        } message: { _ in
            Text("Its time and pages are removed from your history and goals.")
        }
    }

    private var monthGrid: some View {
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let count = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        let today = calendar.startOfDay(for: Date())
        return VStack(spacing: 10) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous month")
                Spacer()
                Text(start.formatted(Date.FormatStyle(timeZone: calendar.timeZone).month(.wide).year())).font(.headline)
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next month")
                    .disabled(calendar.compare(start, to: today, toGranularity: .month) != .orderedAscending)
            }
            .buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 36) }
                ForEach(0..<count, id: \.self) { offset in
                    let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                    dayCell(day, isFuture: day > today)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func dayCell(_ day: Date, isFuture: Bool) -> some View {
        let key = ReadingStatistics.dayKey(day, timezoneID: journal.timezoneID)
        let progress = journal.history.goalProgressByDay[key]
        let fraction = progress?.fraction ?? 0
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        return Button { selected = day } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.callout.monospacedDigit())
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(progress?.reached == true ? Color.white : isFuture ? Color.secondary : Color.primary)
                .background {
                    Circle()
                        .fill(Color.accentColor.opacity(progress?.reached == true ? 1 : fraction > 0 ? 0.2 + 0.35 * fraction : 0))
                        .frame(width: 34, height: 34)
                }
                .overlay {
                    if isSelected { Circle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: 38, height: 38) }
                }
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityLabel(day.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: calendar.timeZone)))
        .accessibilityValue(progress?.reached == true ? "Goal reached" : fraction > 0 ? "\(Int((fraction * 100).rounded())) percent of goal" : "No reading")
    }

    private func daySummary(_ key: String) -> some View {
        let seconds = journal.history.days.first { $0.day == key }?.creditedSeconds ?? 0
        let pages = journal.history.pageDaysByKey[key]?.pages ?? 0
        return HStack {
            Label(ReadingText.duration(seconds), systemImage: "clock")
            Spacer()
            Label(ReadingText.pages(pages), systemImage: "book.pages")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func shift(_ months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) { month = next }
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var journal: Journal
    let session: ReadingSessionGroup

    var body: some View {
        let manual = session.intervals.contains { $0.mode == .manual }
        VStack(alignment: .leading, spacing: 4) {
            Text(journal.book(session.bookID)?.title ?? "Removed book").font(.system(.body, design: .serif))
            HStack(spacing: 8) {
                Text("\(session.start.formatted(date: .omitted, time: .shortened))–\(session.end.formatted(date: .omitted, time: .shortened))")
                Text(ReadingText.duration(session.creditedSeconds))
                let pages = journal.pages(sessionID: session.id)
                if pages > 0 { Text(ReadingText.pages(pages)) }
                if manual { Text("Logged").foregroundStyle(Color.accentColor) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Finished books, newest first, by year.
private struct FinishedTimeline: View {
    @EnvironmentObject private var journal: Journal

    var body: some View {
        let entries = journal.history.finishedBooks
        let years = Dictionary(grouping: entries) { entry in entry.finishedAt.map { Calendar.current.component(.year, from: $0) } ?? 0 }
        List {
            ForEach(years.keys.sorted(by: >), id: \.self) { year in
                Section(year == 0 ? "Undated" : String(year)) {
                    ForEach(years[year] ?? []) { entry in
                        NavigationLink(value: entry.id) { TimelineRow(entry: entry) }
                    }
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No finished books yet", systemImage: "checkmark.circle",
                                       description: Text("Mark a book as finished from the Library and it appears here with its date."))
            }
        }
    }
}

private struct TimelineRow: View {
    @EnvironmentObject private var journal: Journal
    let entry: FinishedBookEntry

    var body: some View {
        HStack(spacing: 12) {
            if let book = journal.book(entry.id) {
                BookCover(book: book, coverURL: journal.edition(forBook: entry.id)?.coverURL, maxPixels: 160).frame(width: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.system(.body, design: .serif)).lineLimit(2)
                if let author = entry.author { Text(author).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    if let finished = entry.finishedAt { Text(finished.formatted(date: .abbreviated, time: .omitted)) }
                    if let rating = journal.rating(bookID: entry.id) { StarRatingLabel(rating: rating) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Private written reviews and ratings. Nothing is posted anywhere.
private struct ReviewsList: View {
    @EnvironmentObject private var journal: Journal

    private var reviewed: [BookRecord] {
        let ids = Set(journal.history.bookReviewCache.keys).union(journal.history.bookRatings.keys)
        return journal.history.librarySummary.books.filter { ids.contains($0.id) }.sorted { lhs, rhs in
            let left = journal.history.bookReviewDates[lhs.id] ?? .distantPast, right = journal.history.bookReviewDates[rhs.id] ?? .distantPast
            return left == right ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending : left > right
        }
    }

    var body: some View {
        let reviewed = self.reviewed
        List(reviewed) { book in
            NavigationLink(value: book.id) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(book.title).font(.system(.headline, design: .serif)).lineLimit(2)
                        Spacer()
                        if let rating = journal.rating(bookID: book.id) { StarRatingLabel(rating: rating) }
                    }
                    if let review = journal.review(bookID: book.id) {
                        Text(review).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .overlay {
            if reviewed.isEmpty {
                ContentUnavailableView("No Reviews Yet", systemImage: "text.quote",
                                       description: Text("Rate a book or write a few lines about it from its details. Reviews stay on this device."))
            }
        }
    }
}
