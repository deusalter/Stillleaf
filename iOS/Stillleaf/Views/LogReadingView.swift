import SwiftUI
import BooksCore

/// Logs a past session by hand: a paper book, or reading the app could not see.
struct LogReadingView: View {
    @EnvironmentObject private var journal: Journal
    @Environment(\.dismiss) private var dismiss
    @State private var bookID: String = LogReadingView.newBook
    @State private var title = ""
    @State private var author = ""
    @State private var end = Date()
    @State private var minutes = 30
    @State private var pages: Int?

    private static let newBook = "new"

    private var books: [BookRecord] {
        journal.history.librarySummary.books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Book") {
                    Picker("Book", selection: $bookID) {
                        Text("New book…").tag(Self.newBook)
                        ForEach(books) { Text($0.title).tag($0.id) }
                    }
                    if bookID == Self.newBook {
                        TextField("Title", text: $title)
                        TextField("Author (optional)", text: $author)
                    }
                }
                Section {
                    DatePicker("Finished at", selection: $end, in: ...Date())
                    Stepper(value: $minutes, in: 0...1440, step: 5) {
                        LabeledContent("Minutes", value: minutes == 0 ? "None" : "\(minutes)")
                    }
                    LabeledContent("Pages") {
                        TextField("Optional", value: $pages, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("Logged time and pages are marked as entered by you and count towards your goals.")
                }
            }
            .navigationTitle("Log Reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .onAppear {
                if let recent = journal.continueReading ?? books.first { bookID = recent.id }
            }
        }
    }

    private var canSave: Bool {
        (minutes > 0 || (pages ?? 0) > 0) && (bookID != Self.newBook || !title.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func save() {
        let book: BookRecord
        if bookID == Self.newBook {
            let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
            book = BookRecord(id: "manual:" + UUID().uuidString, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                              author: trimmedAuthor.isEmpty ? nil : trimmedAuthor)
        } else if let existing = journal.book(bookID) {
            book = existing
        } else { return }
        if journal.logReading(book: book, end: end, minutes: minutes, pages: pages.flatMap { $0 > 0 ? $0 : nil }) { dismiss() }
    }
}
