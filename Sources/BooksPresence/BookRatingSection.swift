import SwiftUI
import BooksCore

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
