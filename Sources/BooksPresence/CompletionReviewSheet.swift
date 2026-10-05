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
