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
                    .scaleEffect(hasAppeared ? 1 : 0.55)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hasAppeared)

            VStack(alignment: .leading, spacing: 10) {
                Text("Congratulations — you finished a book.")
                    .font(.headline).foregroundStyle(ReadingPalette.moss)
                Text(entry.title).font(.system(.title2, design: .serif))
                if let author = entry.author, !author.isEmpty {
                    Text(author).font(.callout).foregroundStyle(.secondary)
                }
                Text(finishDetail).font(.caption).foregroundStyle(.secondary)
                Text("Leave a rating if you’d like to remember this one.")
                    .font(.callout).foregroundStyle(.secondary)
                QuarterStarRating(rating: $rating)
                HStack(spacing: 10) {
                    Button("Save rating") {
                        model.saveRating(rating, for: entry.id)
                        model.acknowledgeCompletion(entry)
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
                            isEditing = false
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
                                isEditing = false
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

struct QuarterStarRating: View {
    @Binding var rating: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var value: Double { rating ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RatingStars(rating: rating)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: rating)
            Slider(value: Binding(get: { value }, set: { rating = roundedQuarter($0) }), in: 0...5, step: 0.25)
                .controlSize(.small)
                .accessibilityLabel("Rating")
                .accessibilityValue(RatingStars.description(for: rating))
                .accessibilityHint("Use the arrow keys to adjust in quarter-star steps.")
        }
        .frame(maxWidth: 190)
    }

    private func roundedQuarter(_ value: Double) -> Double {
        min(5, max(0, (value * 4).rounded() / 4))
    }
}

struct RatingStars: View {
    let rating: Double?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                FractionalStar(fill: min(1, max(0, (rating ?? 0) - Double(index))))
            }
            Text(Self.description(for: rating))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating: \(Self.description(for: rating))")
    }

    static func description(for rating: Double?) -> String {
        guard let rating else { return "No rating yet" }
        let hundredths = Int((rating * 100).rounded())
        if hundredths % 100 == 0 { return "\(hundredths / 100) of 5" }
        return "\(hundredths / 100).\(String(format: "%02d", hundredths % 100)) of 5"
    }
}

private struct FractionalStar: View {
    let fill: Double

    var body: some View {
        Image(systemName: "star.fill")
            .foregroundStyle(ReadingPalette.fadedInk.opacity(0.3))
            .overlay(alignment: .leading) {
                Image(systemName: "star.fill")
                    .foregroundStyle(ReadingPalette.ochre)
                    .mask(alignment: .leading) {
                        GeometryReader { proxy in
                            Rectangle().frame(width: proxy.size.width * fill)
                        }
                    }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}
