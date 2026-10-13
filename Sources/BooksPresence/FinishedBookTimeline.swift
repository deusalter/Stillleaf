import SwiftUI
import BooksCore

@MainActor
struct FinishedBookTimeline: View {
    /// Not observed directly: the timeline depends only on the journal and the timezone, so it
    /// follows a slice of the model instead of re-rendering on every tracking tick.
    let model: AppModel
    @StateObject private var slice: ModelSlice<JournalSliceKey>
    var search = ""
    var showsHeading = true
    /// Opens book details, where rating and reading dates are edited.
    var present: (DashboardSheet) -> Void = { _ in }

    init(model: AppModel, search: String = "", showsHeading: Bool = true, present: @escaping (DashboardSheet) -> Void = { _ in }) {
        self.model = model
        self.search = search
        self.showsHeading = showsHeading
        self.present = present
        _slice = StateObject(wrappedValue: ModelSlice(model: model) { JournalSliceKey($0) })
    }

    /// What the timeline shows for one history, search and timezone. Computing it sorts and groups
    /// every finished book, so a redraw that changes none of those reuses it.
    private struct Arrangement {
        var calendar: Calendar
        var entries: [FinishedBookEntry]
        var years: [FinishedTimelineYear]
        var undated: [FinishedBookEntry]
        var booksByID: [String: BookRecord]
    }
    private struct ArrangementKey: Equatable {
        var revision: Int
        var search: String
        var timezoneID: String
    }
    @State private var memo = ViewMemo<ArrangementKey, Arrangement>()

    private func arrangement() -> Arrangement {
        memo.value(for: ArrangementKey(revision: model.historyRevision, search: search, timezoneID: model.timezoneID)) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = .current
            calendar.timeZone = TimeZone(identifier: model.timezoneID) ?? TimeZone(secondsFromGMT: 0)!
            // Already ordered newest first, undated last; filtering keeps that order.
            let entries = model.finishedBooksByRecency
                .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.author ?? "").localizedCaseInsensitiveContains(search) }
            let years = Dictionary(grouping: entries.compactMap { entry -> (Int, FinishedBookEntry)? in
                guard let date = entry.finishedAt else { return nil }
                return (calendar.component(.year, from: date), entry)
            }, by: \.0)
            .map { year, values in
                FinishedTimelineYear(year: year, entries: values.map(\.1))
            }
            .sorted { $0.year > $1.year }
            return Arrangement(calendar: calendar, entries: entries, years: years, undated: entries.filter { $0.finishedAt == nil },
                               booksByID: Dictionary(model.books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
        }
    }

    var body: some View {
        let layout = arrangement()
        return LazyVStack(alignment: .leading, spacing: 40) {
            if showsHeading {
                PageHeader("Finished", subtitle: nil)
            }
            if layout.entries.isEmpty {
                ReadingEmptyState(title: search.isEmpty ? "No finished books yet" : "No matching books", symbol: "checkmark.circle",
                                  message: search.isEmpty ? "Books you mark finished, here or in Apple Books, appear here with their dates." : "Try another title or author.")
            }
            ForEach(layout.years) { year in
                yearGroup(title: String(year.year), note: "\(year.entries.count) \(year.entries.count == 1 ? "book" : "books")", entries: year.entries, layout: layout)
            }
            if !layout.undated.isEmpty {
                yearGroup(title: "Date unavailable",
                          note: "These completion records have no saved finish date, so they appear after the dated timeline.",
                          entries: layout.undated, layout: layout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Every year sits on this one surface; years are told apart by their numerals.
        .readingPanel()
        .buttonStyle(ReadingButtonStyle())
    }

    /// Book details for a finished entry, even when its journal record is missing.
    static func sheet(for entry: FinishedBookEntry, books: [BookRecord]) -> DashboardSheet {
        .book(books.first { $0.id == entry.id } ?? BookRecord(id: entry.id, title: entry.title, author: entry.author))
    }

    private func yearGroup(title: String, note: String, entries: [FinishedBookEntry], layout: Arrangement) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(ReadingType.numeral(30)).foregroundStyle(ReadingPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Text(note).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.bottom, 6)
            ForEach(entries) { entry in
                // Plain values, not the model: a tracking tick that changes nothing here skips the row.
                FinishedBookTimelineRow(entry: entry, book: layout.booksByID[entry.id], rating: model.rating(for: entry.id), zone: layout.calendar.timeZone.identifier, present: present)
                    .equatable()
            }
        }
    }
}

@MainActor
struct ReadingTimelineView: View, Equatable {
    /// Not observed directly; see `FinishedBookTimeline`. Built with `.equatable()`, so the dashboard's
    /// once-a-second redraw skips the whole screen.
    let model: AppModel
    var present: (DashboardSheet) -> Void = { _ in }
    @State private var search = ""

    init(model: AppModel, present: @escaping (DashboardSheet) -> Void = { _ in }) {
        self.model = model
        self.present = present
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                PageHeader("Timeline", subtitle: nil)
                // The search sits on the same surface as the finished books it filters.
                VStack(alignment: .leading, spacing: 28) {
                    TextField("Find a finished title or author", text: $search)
                        .textFieldStyle(ReadingTextFieldStyle())
                        .frame(maxWidth: 320)
                    FinishedBookTimeline(model: model, search: search, showsHeading: false, present: present)
                }
                .readingPanel()
            }
            .readingPage(maxWidth: ReadingMetrics.listWidth)
        }
        .buttonStyle(ReadingButtonStyle())
    }
}

private struct FinishedTimelineYear: Identifiable {
    let year: Int
    let entries: [FinishedBookEntry]
    var id: Int { year }
}

/// One finished book. The whole row opens book details, where rating and dates are edited.
/// It holds plain values and compares them, so redraws of the timeline that change nothing about
/// this book leave it alone; `present` is a fixed action and is not part of the comparison.
@MainActor
private struct FinishedBookTimelineRow: View, Equatable {
    let entry: FinishedBookEntry
    let book: BookRecord?
    let rating: Double?
    let zone: String
    let present: (DashboardSheet) -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.book == rhs.book && lhs.rating == rhs.rating && lhs.zone == rhs.zone
    }

    var body: some View {
        Button {
            present(.book(book ?? BookRecord(id: entry.id, title: entry.title, author: entry.author)))
        } label: {
            HStack(alignment: .center, spacing: 20) {
                dateColumn.frame(width: 56, alignment: .leading)
                BookCoverView(book: book, size: .timeline)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title)
                        .font(ReadingType.bookTitle(20))
                        .foregroundStyle(ReadingPalette.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let author = entry.author, !author.isEmpty {
                        Text(author).font(.callout).foregroundStyle(ReadingPalette.secondaryInk).lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        RatingStars(rating: rating)
                        Text(entry.imported ? "Imported history" : entry.source)
                            .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    }
                    .padding(.top, 3)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ReadingPalette.secondaryInk)
                    .opacity(hovering || focused ? 1 : 0.5)
            }
            .padding(.vertical, 12).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? ReadingPalette.surface : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(focused ? ReadingPalette.accent : .clear, lineWidth: 2))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : ReadingMotion.hover, value: hovering)
        .padding(.horizontal, -12)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Open book details to rate or edit reading dates")
    }

    private var dateColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let date = entry.finishedAt {
                Text(DateText.string(date, zone: zone, pattern: "MMM d"))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(ReadingPalette.ink)
                Text(DateText.string(date, zone: zone, pattern: "EEE"))
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            } else {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
            }
        }
        .accessibilityHidden(true)
    }

    private var accessibilityText: String {
        let finished = entry.finishedAt.map { "finished \(formattedDate($0))" } ?? "finish date unavailable"
        let ratedText = rating.map { ", rated \($0.formatted(.number.precision(.fractionLength(0...2)))) of 5" } ?? ", not rated"
        let author = entry.author.flatMap { $0.isEmpty ? nil : " by \($0)" } ?? ""
        return "\(entry.title)\(author), \(finished)\(ratedText)"
    }

    private func formattedDate(_ date: Date) -> String {
        DateText.string(date, zone: zone, pattern: "MMMM d, yyyy")
    }
}
