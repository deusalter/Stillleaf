import SwiftUI
import BooksCore

/// Shown after the reader closes a book on its last pages: mark it finished, then rate it. Nothing is
/// recorded unless the reader says so; leaving the sheet leaves the book as it was.
struct FinishOfferView: View {
    @EnvironmentObject private var journal: Journal
    @EnvironmentObject private var router: AppRouter
    let bookID: String

    var body: some View {
        ScrollView {
            if let book = journal.book(bookID) {
                content(book, finished: journal.finished(bookID: bookID) != nil)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 16)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func content(_ book: BookRecord, finished: Bool) -> some View {
        VStack(spacing: 16) {
            BookCover(book: book, coverURL: journal.edition(forBook: bookID)?.coverURL)
                .frame(width: 84)
                .overlay(alignment: .bottomTrailing) {
                    if finished {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .offset(x: 9, y: 9)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            VStack(spacing: 4) {
                Text(finished ? "Finished" : "You reached the end")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                Text(book.author.map { "\(book.title) · \($0)" } ?? book.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if finished {
                rate(book)
            } else {
                offer
            }
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: finished)
    }

    private var offer: some View {
        VStack(spacing: 6) {
            Text("Mark it finished to add it to your Journal\(journal.history.annualBookGoal == nil ? "" : " and this year's goal").")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            Button { journal.acceptFinishOffer() } label: { Label("Mark as Finished", systemImage: "checkmark") }
                .buttonStyle(ProminentActionStyle(maxWidth: .infinity))
            Button("Not Yet") { router.sheet = nil }
                .frame(minHeight: 44)
        }
    }

    private func rate(_ book: BookRecord) -> some View {
        VStack(spacing: 14) {
            if let target = journal.history.annualBookGoal {
                Text("\(journal.history.annualBooksFinished) of \(target) books this year")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            RatingEditor(rating: journal.rating(bookID: book.id)) { journal.saveRating($0, for: book.id) }
                .padding(14)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button("Done") { router.sheet = nil }
                .buttonStyle(ProminentActionStyle(maxWidth: .infinity))
        }
    }
}
