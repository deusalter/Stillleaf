import Foundation
import SwiftUI
import BooksCore

@MainActor
struct CompletionReviewSheet: View {
    @ObservedObject var model: AppModel
    let entry: FinishedBookEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("Book finished").font(.headline)
                Spacer()
                Button("Done") { model.acknowledgeCompletion(entry); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            FinishedBookPrompt(model: model, entry: entry)
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(ReadingPalette.warning) }
        }
        .padding(24).frame(width: 660)
        .background(ReadingPalette.paper).foregroundStyle(ReadingPalette.ink)
        .buttonStyle(ReadingButtonStyle())
        .onChange(of: model.pendingCompletion?.id) { id in if id != entry.id { dismiss() } }
        .onDisappear { model.acknowledgeCompletion(entry) }
    }
}

@MainActor
struct FinishedBookPrompt: View {
    @ObservedObject var model: AppModel
    let entry: FinishedBookEntry
    @State private var rating: Double?
    @State private var writingReview = false
    @State private var editingDates = false

    init(model: AppModel, entry: FinishedBookEntry) {
        self.model = model
        self.entry = entry
        _rating = State(initialValue: model.rating(for: entry.id))
    }

    private var book: BookRecord? { model.books.first { $0.id == entry.id } }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack(alignment: .topTrailing) {
                BookCoverView(book: book, size: .large)
                CompletionCelebrationBadge(eventID: model.pendingCompletionEventID ?? entry.id) {
                    model.claimCompletionCelebration(for: entry)
                }
                .offset(x: 8, y: -8)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Another story, finished.")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(ReadingPalette.accent)
                Text(entry.title).font(ReadingType.bookTitle(24))
                if let author = entry.author, !author.isEmpty {
                    Text(author).font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                }
                Text(finishDetail).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                Button("Reading dates · optional") { editingDates = true }.controlSize(.small)
                Text("Already marked as read. You can skip dates and feedback.")
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                Text("Congratulations. How did this one stay with you?")
                    .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                QuarterStarRating(rating: $rating)
                Button(model.review(for: entry.id) == nil ? "Write a review" : "Edit written review") { writingReview = true }
                    .controlSize(.small)
                HStack(spacing: 10) {
                    Button("Save rating") {
                        model.saveRating(rating, for: entry.id)
                        if model.errorMessage == nil { model.acknowledgeCompletion(entry) }
                    }
                    .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                    .disabled(rating == nil)
                    Button("Maybe later") { model.acknowledgeCompletion(entry) }
                    if model.rating(for: entry.id) != nil {
                        Button("Clear rating") {
                            rating = nil
                            model.saveRating(nil, for: entry.id)
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .readingPanel()
        .buttonStyle(ReadingButtonStyle())
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $writingReview) { BookReviewEditor(model: model, bookID: entry.id).readingMotionAccessibility() }
        .sheet(isPresented: $editingDates) {
            ReadingDatesEditor(title: entry.title,
                dates: ReadingCompletionDates(startedAt: savedEntry.startedAt, finishedAt: savedEntry.finishedAt),
                timezoneID: model.timezoneID) { dates in model.saveReadingDates(dates, for: entry.id) }
        }
    }

    private var savedEntry: FinishedBookEntry {
        model.finishedBooks.first { $0.id == entry.id } ?? entry
    }

    private var finishDetail: String {
        let entry = savedEntry
        let date = entry.finishedAt.map { ReadingFormat.date($0) } ?? "Finish date unavailable"
        return "\(date) · \(entry.imported ? "Imported history" : entry.source)"
    }
}

@MainActor
struct FinishedBookTimeline: View {
    @ObservedObject var model: AppModel
    var search = ""
    var showsHeading = true
    /// Opens book details, where rating and reading dates are edited.
    var present: (DashboardSheet) -> Void = { _ in }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        calendar.timeZone = TimeZone(identifier: model.timezoneID) ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var entries: [FinishedBookEntry] {
        model.finishedBooks
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.author ?? "").localizedCaseInsensitiveContains(search) }
            .sorted { lhs, rhs in
                switch (lhs.finishedAt, rhs.finishedAt) {
                case let (left?, right?) where left != right: return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    let order = lhs.title.localizedStandardCompare(rhs.title)
                    return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
                }
            }
    }

    private var years: [FinishedTimelineYear] {
        Dictionary(grouping: entries.compactMap { entry -> (Int, FinishedBookEntry)? in
            guard let date = entry.finishedAt else { return nil }
            return (calendar.component(.year, from: date), entry)
        }, by: \.0)
        .map { year, values in
            FinishedTimelineYear(year: year, entries: values.map(\.1))
        }
        .sorted { $0.year > $1.year }
    }

    private var undatedEntries: [FinishedBookEntry] {
        entries.filter { $0.finishedAt == nil }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 40) {
            if showsHeading {
                PageHeader("Finished", subtitle: "Your completed books, ordered by the day you finished them.")
            }
            if entries.isEmpty {
                Text(search.isEmpty ? "Books marked finished in Apple Books will appear here." : "No finished books match your search.")
                    .foregroundStyle(ReadingPalette.secondaryInk).padding(.vertical, 28)
            }
            ForEach(years) { year in
                yearGroup(title: String(year.year), note: "\(year.entries.count) \(year.entries.count == 1 ? "book" : "books")", entries: year.entries)
            }
            if !undatedEntries.isEmpty {
                yearGroup(title: "Date unavailable",
                          note: "These completion records have no saved finish date, so they appear after the dated timeline.",
                          entries: undatedEntries)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(ReadingButtonStyle())
    }

    private func yearGroup(title: String, note: String, entries: [FinishedBookEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(ReadingType.numeral(30)).foregroundStyle(ReadingPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Text(note).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    .multilineTextAlignment(.trailing)
            }
            Hairline().padding(.bottom, 6)
            ForEach(entries) { entry in
                FinishedBookTimelineRow(model: model, entry: entry, calendar: calendar, present: present)
            }
        }
    }
}

@MainActor
struct ReadingTimelineView: View {
    @ObservedObject var model: AppModel
    var present: (DashboardSheet) -> Void = { _ in }
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                PageHeader("Timeline", subtitle: "Finished books, ordered by their recorded completion date") {
                    TextField("Find a finished title or author", text: $search)
                        .textFieldStyle(ReadingTextFieldStyle())
                        .frame(width: 260)
                }
                FinishedBookTimeline(model: model, search: search, showsHeading: false, present: present)
            }
            .readingPage(maxWidth: 860)
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
@MainActor
private struct FinishedBookTimelineRow: View {
    @ObservedObject var model: AppModel
    let entry: FinishedBookEntry
    let calendar: Calendar
    let present: (DashboardSheet) -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var book: BookRecord? { model.books.first { $0.id == entry.id } }

    var body: some View {
        Button {
            present(.book(book ?? BookRecord(id: entry.id, title: entry.title, author: entry.author)))
        } label: {
            HStack(alignment: .center, spacing: 20) {
                dateColumn.frame(width: 56, alignment: .leading)
                BookCoverView(book: book, size: .timeline)
                    .shadow(color: ReadingPalette.ink.opacity(0.14), radius: 6, x: 0, y: 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title)
                        .font(ReadingType.bookTitle(20))
                        .foregroundStyle(ReadingPalette.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let author = entry.author, !author.isEmpty {
                        Text(author).font(.callout).foregroundStyle(ReadingPalette.secondaryInk).lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        RatingStars(rating: model.rating(for: entry.id))
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
                Text(calendar.shortMonthSymbols[calendar.component(.month, from: date) - 1] + " " + String(calendar.component(.day, from: date)))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(ReadingPalette.ink)
                Text(calendar.shortWeekdaySymbols[calendar.component(.weekday, from: date) - 1])
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
        let rating = model.rating(for: entry.id).map { ", rated \($0.formatted(.number.precision(.fractionLength(0...2)))) of 5" } ?? ", not rated"
        return "\(entry.title)\(entry.author.map { " by \($0)" } ?? ""), \(finished)\(rating)"
    }

    private func formattedDate(_ date: Date) -> String {
        let month = calendar.monthSymbols[calendar.component(.month, from: date) - 1]
        let day = calendar.component(.day, from: date)
        let year = calendar.component(.year, from: date)
        return "\(month) \(day), \(year)"
    }
}

@MainActor
struct BookRatingSection: View {
    @ObservedObject var model: AppModel
    let bookID: String
    @State private var editing = false
    @State private var draft: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your rating").font(ReadingType.bookTitle(19))
                    if !editing { RatingStars(rating: model.rating(for: bookID), size: 20) }
                }
                Spacer()
                if !editing {
                    Button(model.rating(for: bookID) == nil ? "Rate this book" : "Edit rating") {
                        draft = model.rating(for: bookID); editing = true
                    }.controlSize(.small)
                }
            }
            if editing {
                QuarterStarRating(rating: $draft)
                HStack(spacing: 10) {
                    Button("Save rating") {
                        model.saveRating(draft, for: bookID)
                        if model.errorMessage == nil { editing = false }
                    }.buttonStyle(ReadingButtonStyle(emphasis: .primary)).disabled(draft == nil)
                    Button("Cancel") { draft = model.rating(for: bookID); editing = false }
                    if model.rating(for: bookID) != nil {
                        Button("Clear rating") {
                            model.saveRating(nil, for: bookID)
                            if model.errorMessage == nil { draft = nil; editing = false }
                        }
                    }
                }.controlSize(.small)
            }
        }.readingPanel().buttonStyle(ReadingButtonStyle())
    }
}
