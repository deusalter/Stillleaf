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
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
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
                    .font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(ReadingPalette.moss)
                Text(entry.title).font(.system(.title2, design: .serif))
                if let author = entry.author, !author.isEmpty {
                    Text(author).font(.callout).foregroundStyle(.secondary)
                }
                Text(finishDetail).font(.caption).foregroundStyle(.secondary)
                Text("Congratulations. How did this one stay with you?")
                    .font(.callout).foregroundStyle(.secondary)
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
    }

    private var finishDetail: String {
        let date = entry.finishedAt.map { ReadingFormat.date($0) } ?? "Finish date unavailable"
        return "\(date) · \(entry.imported ? "Imported history" : entry.source)"
    }
}

@MainActor
struct FinishedBookTimeline: View {
    @ObservedObject var model: AppModel
    var search = ""
    var showsHeading = true

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
        LazyVStack(alignment: .leading, spacing: 24) {
            if showsHeading {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Finished").font(.system(size: 34, weight: .medium, design: .serif))
                    Text("Your completed books, ordered by the day you finished them.")
                        .font(.callout).foregroundStyle(ReadingPalette.fadedInk)
                }
            }
            if entries.isEmpty {
                Text(search.isEmpty ? "Books marked finished in Apple Books will appear here." : "No finished books match your search.")
                    .foregroundStyle(.secondary).padding(.vertical, 28)
            }
            ForEach(years) { year in
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text(String(year.year))
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .foregroundStyle(ReadingPalette.moss)
                        .padding(.top, 8)
                    ForEach(year.entries) { entry in
                        FinishedBookTimelineRow(model: model, entry: entry, calendar: calendar)
                    }
                }
            }
            if !undatedEntries.isEmpty {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Date unavailable")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(ReadingPalette.fadedInk)
                        .padding(.top, 8)
                    Text("These completion records have no saved finish date, so they appear after the dated timeline.")
                        .font(.callout).foregroundStyle(ReadingPalette.fadedInk)
                    ForEach(undatedEntries) { entry in
                        FinishedBookTimelineRow(model: model, entry: entry, calendar: calendar)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readingPanel()
        .buttonStyle(ReadingButtonStyle())
    }
}

@MainActor
struct ReadingTimelineView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "Timeline", subtitle: "Finished books, ordered by their recorded completion date")
            TextField("Find a finished title or author", text: $search)
                .textFieldStyle(ReadingTextFieldStyle())
                .frame(maxWidth: 330)
            ScrollView {
                FinishedBookTimeline(model: model, search: search, showsHeading: false)
                    .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: 1060, maxHeight: .infinity, alignment: .topLeading)
        .padding(30)
        .frame(maxWidth: .infinity, alignment: .top)
        .buttonStyle(ReadingButtonStyle())
    }
}

private struct FinishedTimelineYear: Identifiable {
    let year: Int
    let entries: [FinishedBookEntry]
    var id: Int { year }
}

@MainActor
private struct FinishedBookTimelineRow: View {
    @ObservedObject var model: AppModel
    let entry: FinishedBookEntry
    let calendar: Calendar
    @State private var rating: Double?
    @State private var isEditing = false

    init(model: AppModel, entry: FinishedBookEntry, calendar: Calendar) {
        self.model = model
        self.entry = entry
        self.calendar = calendar
        _rating = State(initialValue: model.rating(for: entry.id))
    }

    private var book: BookRecord? { model.books.first { $0.id == entry.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                wideLayout.frame(minWidth: 650, alignment: .leading)
                compactLayout
            }
            if isEditing {
                VStack(alignment: .leading, spacing: 8) {
                    QuarterStarRating(rating: $rating)
                    HStack(spacing: 10) {
                        Button("Save rating") {
                            model.saveRating(rating, for: entry.id)
                            if model.errorMessage == nil { isEditing = false }
                        }
                        .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                        .disabled(rating == nil)
                        Button("Cancel") {
                            rating = model.rating(for: entry.id)
                            isEditing = false
                        }
                        if model.rating(for: entry.id) != nil {
                            Button("Clear rating") {
                                rating = nil
                                model.saveRating(nil, for: entry.id)
                                if model.errorMessage == nil { isEditing = false }
                            }
                        }
                    }
                    .controlSize(.small)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ReadingPalette.elevated.opacity(0.52), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 18) {
            dateColumn
                .frame(width: 96, alignment: .trailing)
            timelineMarker
            bookCard
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            dateColumn
            bookCard
        }
    }

    private var dateColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let date = entry.finishedAt {
                Text(String(calendar.component(.day, from: date)))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(ReadingPalette.moss)
                    .monospacedDigit()
                Text(calendar.shortMonthSymbols[calendar.component(.month, from: date) - 1])
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(ReadingPalette.ink)
                Text(calendar.shortWeekdaySymbols[calendar.component(.weekday, from: date) - 1])
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            } else {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.title2).foregroundStyle(ReadingPalette.fadedInk)
                Text("Date unavailable")
                    .font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.fadedInk)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.finishedAt.map { "Finished on \(formattedDate($0))" } ?? "Finish date unavailable")
    }

    private var timelineMarker: some View {
        VStack(spacing: 0) {
            Circle().fill(ReadingPalette.moss).frame(width: 12, height: 12)
            Rectangle().fill(ReadingPalette.moss.opacity(0.28)).frame(width: 2).frame(minHeight: 142)
        }
        .frame(width: 14)
        .accessibilityHidden(true)
    }

    private var bookCard: some View {
        HStack(alignment: .top, spacing: 20) {
            BookCoverView(book: book, size: .shelf)
                .shadow(color: ReadingPalette.ink.opacity(0.12), radius: 7, x: 0, y: 4)
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.title)
                    .font(.system(size: 25, weight: .medium, design: .serif))
                    .foregroundStyle(ReadingPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let author = entry.author, !author.isEmpty {
                    Text(author).font(.callout).foregroundStyle(ReadingPalette.fadedInk)
                }
                Text(entry.imported ? "Imported history" : entry.source)
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 7) {
                    RatingStars(rating: model.rating(for: entry.id))
                    Button(model.rating(for: entry.id) == nil ? "Rate this book" : "Edit rating") {
                        rating = model.rating(for: entry.id)
                        isEditing.toggle()
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 154, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(ReadingPalette.border.opacity(0.48)))
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
                    Text("Your rating").font(.system(size: 17, weight: .semibold, design: .rounded))
                    if !editing { RatingStars(rating: model.rating(for: bookID)) }
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
