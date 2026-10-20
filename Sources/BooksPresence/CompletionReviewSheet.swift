import Foundation
import SwiftUI
import BooksCore

@MainActor
struct CompletionReviewSheet: View {
    @ObservedObject var model: AppModel
    let entry: FinishedBookEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // The prompt carries its own heading and a Done button (Escape), so the sheet adds no header.
        VStack(alignment: .leading, spacing: 18) {
            FinishedBookPrompt(model: model, entry: entry, placement: .sheet) { dismiss() }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(ReadingPalette.warning) }
        }
        .padding(24).frame(width: 660)
        .readingSheetSurface()
        .background(ReadingPalette.canvas).foregroundStyle(ReadingPalette.ink)
        .buttonStyle(ReadingButtonStyle())
        .onChange(of: model.pendingCompletion?.id) { id in if id != entry.id { dismiss() } }
        .onDisappear { model.acknowledgeCompletion(entry) }
    }
}

@MainActor
struct FinishedBookPrompt: View {
    @ObservedObject var model: AppModel
    let entry: FinishedBookEntry
    /// Inline on Today the prompt waits with "Maybe later"; in a sheet it closes with "Done" or Escape.
    enum Placement { case today, sheet }
    let placement: Placement
    let dismissed: () -> Void
    @State private var rating: Double?
    @State private var writingReview = false
    @State private var editingDates = false

    init(model: AppModel, entry: FinishedBookEntry, placement: Placement = .today, dismissed: @escaping () -> Void = {}) {
        self.model = model
        self.entry = entry
        self.placement = placement
        self.dismissed = dismissed
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

            // One voice: what happened, the book, then a single optional question. The book is
            // already saved as finished, so every control here can be skipped.
            VStack(alignment: .leading, spacing: 10) {
                Text("Another story, finished.")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ReadingPalette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(ReadingType.bookTitle(24))
                        .fixedSize(horizontal: false, vertical: true)
                    if let author = entry.author, !author.isEmpty {
                        Text(author).font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                    }
                }
                HStack(spacing: 8) {
                    Text(finishDetail).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    Button("Edit dates") { editingDates = true }
                        .buttonStyle(.link).font(.caption).foregroundStyle(ReadingPalette.accent)
                        .accessibilityHint("Change when you started and finished this book")
                }
                Text("How did this one stay with you?")
                    .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                    .padding(.top, 6)
                QuarterStarRating(rating: $rating)
                HStack(spacing: 10) {
                    Button("Save rating") {
                        model.saveRating(rating, for: entry.id)
                        if model.errorMessage == nil { model.acknowledgeCompletion(entry) }
                    }
                    .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                    .disabled(rating == nil)
                    Button(model.review(for: entry.id) == nil ? "Write a review" : "Edit review") { writingReview = true }
                    if model.rating(for: entry.id) != nil {
                        Button("Clear rating") {
                            rating = nil
                            model.saveRating(nil, for: entry.id)
                        }
                    }
                    Button(placement == .sheet ? "Done" : "Maybe later") { model.acknowledgeCompletion(entry); dismissed() }
                        .keyboardShortcut(placement == .sheet ? .cancelAction : nil)
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
