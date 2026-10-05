import SwiftUI
import BooksCore

struct PersonalReviewsView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var selectedBook: BookRecord?
    private var entries: [(book: BookRecord, text: String, date: Date)] {
        model.books.compactMap { book in
            guard let text = model.review(for: book.id), !text.isEmpty,
                  search.isEmpty || book.title.localizedCaseInsensitiveContains(search)
                    || (book.author ?? "").localizedCaseInsensitiveContains(search)
                    || text.localizedCaseInsensitiveContains(search) else { return nil }
            let date = model.reviewUpdatedAt(for: book.id) ?? .distantPast
            return (book, text, date)
        }.sorted { $0.date == $1.date ? $0.book.id < $1.book.id : $0.date > $1.date }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader("Reviews", subtitle: nil) {
                    Button("Choose a book") { model.showDashboard(section: .library) }.controlSize(.small)
                }
                TextField("Find a book or a thought", text: $search).textFieldStyle(ReadingTextFieldStyle()).frame(maxWidth: 360)
                if entries.isEmpty {
                    ReadingEmptyState(title: search.isEmpty ? "Some stories stay with you" : "No matching reviews",
                        symbol: "square.and.pencil", message: search.isEmpty ? "Open any book in your Library to write a private review. A rating and a review are both optional." : "Try another book title, author, or phrase.")
                        .padding(.vertical, 36)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries, id: \.book.id) { entry in
                            HStack(alignment: .top, spacing: 22) {
                                BookCoverView(book: entry.book, size: .timeline)
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(entry.book.title).font(ReadingType.bookTitle(21))
                                            if let author = entry.book.author { Text(author).font(.callout).foregroundStyle(ReadingPalette.secondaryInk) }
                                        }
                                        Spacer()
                                        Button("Read & edit") { selectedBook = entry.book }.controlSize(.small)
                                    }
                                    if let rating = model.rating(for: entry.book.id) { RatingStars(rating: rating) }
                                    Text(entry.text).font(.system(size: 14, design: .serif)).lineSpacing(5).lineLimit(7).textSelection(.enabled)
                                    Text("Written review · updated \(entry.date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 22)
                            if entry.book.id != entries.last?.book.id { Hairline() }
                        }
                    }
                }
            }
            .readingPage(maxWidth: ReadingMetrics.listWidth)
        }
        .buttonStyle(ReadingButtonStyle())
        .sheet(item: $selectedBook) { book in BookReviewEditor(model: model, bookID: book.id).readingMotionAccessibility() }
    }
}

struct ReadingRecordsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ReadingInterval?
    var body: some View {
        VStack(spacing: 0) {
            ReadingSheetHeader(title: "Reading records", subtitle: "Optional edits to saved reading sessions.", close: { dismiss() })
                .padding(.horizontal, 30).padding(.top, 24)
            ReadingSessionsView(model: model, present: { destination in
                if case .review(let interval) = destination { editing = interval }
            }, showsHeading: false)
        }.frame(width: 880, height: 680)
        .background(ReadingPalette.canvas).foregroundStyle(ReadingPalette.ink)
        .sheet(item: $editing) { interval in ReadingSessionEditor(model: model, interval: interval).readingMotionAccessibility() }
    }
}
