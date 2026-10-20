import SwiftUI
import BooksCore

struct BookDetailView: View {
    @EnvironmentObject private var journal: Journal
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openBook) private var open
    let bookID: String
    @State private var confirmDelete = false
    @State private var confirmRemoveDownload = false

    var body: some View {
        if let book = journal.book(bookID) {
            content(book)
        } else {
            ContentUnavailableView("Book removed", systemImage: "book.closed")
        }
    }

    private func content(_ book: BookRecord) -> some View {
        let edition = journal.edition(forBook: book.id)
        let finished = journal.finished(bookID: book.id)
        return List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    BookCover(book: book, coverURL: edition?.coverURL).frame(width: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.title).font(.system(.title3, design: .serif).weight(.semibold))
                        if let author = book.author { Text(author).foregroundStyle(.secondary) }
                        if let rating = journal.rating(bookID: book.id) { StarRatingLabel(rating: rating) }
                    }
                }
                .padding(.vertical, 4)
                if let edition {
                    Button { open(edition) } label: { Label(journal.position(bookID: book.id) == nil ? "Read" : "Continue Reading", systemImage: "book") }
                } else if book.source == "stillleaf-epub" {
                    Text("Import this EPUB again to read it on this device. Its history is kept.").font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Reading") {
                LabeledContent("Time read", value: ReadingText.duration(journal.secondsRead(bookID: book.id)))
                LabeledContent("Pages", value: ReadingText.pages(journal.pagesRead(bookID: book.id)))
                if let position = journal.position(bookID: book.id) {
                    if let location = position.location { LabeledContent("Position", value: location) }
                    if let fraction = position.fraction { LabeledContent("Progress", value: fraction.formatted(.percent.precision(.fractionLength(0)))) }
                }
                if let finished {
                    FinishedDateRow(entry: finished)
                } else {
                    Button { journal.markFinished(book.id) } label: { Label("Mark as Finished", systemImage: "checkmark.circle") }
                }
            }

            Section("Your review") {
                RatingEditor(rating: journal.rating(bookID: book.id)) { journal.saveRating($0, for: book.id) }
                NavigationLink {
                    ReviewEditor(bookID: book.id)
                } label: {
                    if let review = journal.review(bookID: book.id) {
                        Text(review).lineLimit(4)
                    } else {
                        Text("Write a review").foregroundStyle(Color.accentColor)
                    }
                }
            }

            Section {
                Toggle("Record reading time", isOn: Binding(get: { !book.trackingExcluded },
                                                            set: { journal.setTrackingExcluded(!$0, for: book.id) }))
            } footer: {
                Text("When off, opening this book records no time or pages. Its position is still remembered.")
            }

            Section {
                if edition != nil {
                    Button("Remove EPUB from This Device") { confirmRemoveDownload = true }
                }
                Button("Delete Book and History", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove the EPUB?", isPresented: $confirmRemoveDownload, titleVisibility: .visible) {
            Button("Remove EPUB", role: .destructive) { journal.removeDownload(book.id) }
        } message: {
            Text("The book's file, notes and highlights are removed from this device. Its reading history stays in your journal.")
        }
        .confirmationDialog("Delete “\(book.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Book and History", role: .destructive) {
                if journal.deleteBook(book.id) { dismiss() }
            }
        } message: {
            Text("Its reading time, pages, review and imported EPUB are removed from this device. Exports you saved elsewhere are not affected.")
        }
    }
}

/// Shows and edits the saved finish date; editing never infers reading activity.
private struct FinishedDateRow: View {
    @EnvironmentObject private var journal: Journal
    let entry: FinishedBookEntry
    @State private var date = Date()

    var body: some View {
        DatePicker(selection: $date, in: ...Date(), displayedComponents: .date) {
            Label("Finished", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
        }
        .onAppear { date = entry.finishedAt ?? Date() }
        .onChange(of: date) { _, value in
            guard let saved = entry.finishedAt, !Calendar.current.isDate(saved, inSameDayAs: value) else { return }
            let day = ReadingCompletionDates.selecting(day: value, preserving: saved, calendar: .current, now: Date())
            journal.saveReadingDates(ReadingCompletionDates(startedAt: entry.startedAt, finishedAt: day), for: entry.id)
        }
    }
}

struct ReviewEditor: View {
    @EnvironmentObject private var journal: Journal
    @Environment(\.dismiss) private var dismiss
    let bookID: String
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .serif))
            .padding(.horizontal)
            .navigationTitle(journal.book(bookID)?.title ?? "Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if journal.saveReview(text, for: bookID) { dismiss() } }
                }
            }
            .onAppear { text = journal.review(bookID: bookID) ?? "" }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("What stayed with you?").foregroundStyle(.tertiary).padding(.horizontal, 22).padding(.top, 8).allowsHitTesting(false)
                }
            }
    }
}
