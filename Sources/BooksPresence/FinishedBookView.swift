import Foundation
import SwiftUI
import BooksCore

@MainActor
struct FinishedBookPrompt: View {
    @ObservedObject var model: AppModel
    let entry: FinishedBookEntry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rating: Double?
    @State private var hasAppeared = false

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
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(ReadingPalette.moss)
                    .background(Circle().fill(ReadingPalette.paper).padding(2))
                    .offset(x: 8, y: -8)
                    .scaleEffect(reduceMotion || hasAppeared ? 1 : 0.85)
            }
            .animation(reduceMotion ? nil : ReadingMotion.entrance, value: hasAppeared)

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
        .onAppear { hasAppeared = true }
        .accessibilityElement(children: .contain)
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
    private var entries: [FinishedBookEntry] {
        model.finishedBooks.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.author ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            Text("Finished").font(.system(.title2, design: .serif))
            Text("A shelf of stories you’ve finished. Dates sync from Apple Books; ratings are yours.")
                .font(.callout).foregroundStyle(.secondary)
            if entries.isEmpty {
                Text(search.isEmpty ? "Books marked finished in Apple Books will appear here." : "No finished books match your search.")
                    .foregroundStyle(.secondary).padding(.vertical, 28)
            }
            ForEach(entries) { entry in
                FinishedBookTimelineRow(model: model, entry: entry)
                if entry.id != entries.last?.id { Divider() }
            }
        }
        .readingPanel()
        .buttonStyle(ReadingButtonStyle())
    }
}

@MainActor
private struct FinishedBookTimelineRow: View {
    @ObservedObject var model: AppModel
    let entry: FinishedBookEntry
    @State private var rating: Double?
    @State private var isEditing = false

    init(model: AppModel, entry: FinishedBookEntry) {
        self.model = model
        self.entry = entry
        _rating = State(initialValue: model.rating(for: entry.id))
    }

    private var book: BookRecord? { model.books.first { $0.id == entry.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                BookCoverView(book: book, size: .compact)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.headline)
                    if let author = entry.author, !author.isEmpty {
                        Text(author).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(entry.finishedAt.map { ReadingFormat.date($0) } ?? "Finish date unavailable")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(entry.imported ? "Imported history" : entry.source)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    RatingStars(rating: model.rating(for: entry.id))
                    Button(model.rating(for: entry.id) == nil ? "Rate" : "Edit rating") {
                        rating = model.rating(for: entry.id)
                        isEditing.toggle()
                    }
                    .controlSize(.small)
                }
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
                .padding(.leading, 64)
            }
        }
        .padding(.vertical, 2)
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
