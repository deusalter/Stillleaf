import SwiftUI
import BooksCore

/// Private written reviews and ratings. Nothing is posted anywhere.
struct ReviewsView: View {
    @EnvironmentObject private var journal: Journal

    private var reviewed: [BookRecord] {
        let ids = Set(journal.history.bookReviewCache.keys).union(journal.history.bookRatings.keys)
        return journal.history.librarySummary.books.filter { ids.contains($0.id) }.sorted { lhs, rhs in
            let left = journal.history.bookReviewDates[lhs.id] ?? .distantPast, right = journal.history.bookReviewDates[rhs.id] ?? .distantPast
            return left == right ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending : left > right
        }
    }

    var body: some View {
        NavigationStack {
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
                    ContentUnavailableView("No reviews yet", systemImage: "text.quote",
                                           description: Text("Rate a book or write a few lines about it from its details. Reviews stay on this device."))
                }
            }
            .navigationTitle("Reviews")
            .navigationDestination(for: String.self) { BookDetailView(bookID: $0) }
        }
    }
}
