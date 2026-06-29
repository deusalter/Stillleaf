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

struct QuarterStarRating: View {
    @Binding var rating: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovered: Double?
    @State private var dragging = false
    private var displayed: Double? { hovered ?? rating }
    private var value: Double { rating ?? 0 }
    private let starWidth: CGFloat = 42
    private let gap: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: gap) {
                ForEach(0..<5, id: \.self) { index in
                    FractionalStar(fill: min(1, max(0, (displayed ?? 0) - Double(index))), size: 32)
                        .scaleEffect(!reduceMotion && hovered != nil && (hovered ?? 0) > Double(index) && (hovered ?? 0) <= Double(index + 1) ? 1.08 : 1)
                        .frame(width: starWidth, height: 44)
                }
            }
            .contentShape(Rectangle())
            .background(ReadingPalette.ochre.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? ReadingPalette.moss : .clear, lineWidth: 1.5))
            .onContinuousHover { phase in
                guard !dragging else { return }
                switch phase {
                case .active(let location): hovered = RatingSelection.value(at: location.x)
                case .ended: hovered = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    dragging = true; hovered = nil
                    rating = RatingSelection.value(at: gesture.location.x)
                }
                .onEnded { gesture in
                    rating = RatingSelection.value(at: gesture.location.x)
                    dragging = false; hovered = nil
                })
            .focusable().focused($focused)
            .onMoveCommand { direction in
                hovered = nil
                if direction == .left || direction == .down { rating = max(0, value - 0.25) }
                if direction == .right || direction == .up { rating = min(5, value + 0.25) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Book rating")
            .accessibilityValue(RatingStars.description(for: rating))
            .accessibilityHint("Adjust in quarter-star steps. Zero is a rating; no rating is left blank.")
            .accessibilityAdjustableAction { direction in
                hovered = nil
                switch direction {
                case .increment: rating = min(5, value + 0.25)
                case .decrement: rating = max(0, value - 0.25)
                @unknown default: break
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: displayed)
            HStack(spacing: 8) {
                Text(displayed.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "Not rated")
                    .font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(displayed == nil ? ReadingPalette.fadedInk : ReadingPalette.ochre)
                if displayed != nil { Text("/ 5").font(.caption).foregroundStyle(ReadingPalette.fadedInk) }
                Spacer(minLength: 0)
                Button("0") { hovered = nil; rating = 0 }
                    .accessibilityLabel("Rate zero stars")
                Button { hovered = nil; rating = max(0, value - 0.25) } label: { Image(systemName: "minus") }
                    .disabled(rating == nil || value <= 0).accessibilityLabel("Decrease rating by a quarter star")
                Button { hovered = nil; rating = min(5, value + 0.25) } label: { Image(systemName: "plus") }
                    .disabled(value >= 5).accessibilityLabel("Increase rating by a quarter star")
            }.controlSize(.small).buttonStyle(ReadingButtonStyle())
            Text("Click or drag the stars. Fine-tune by a quarter.")
                .font(.system(size: 10)).foregroundStyle(ReadingPalette.fadedInk)
        }
        .frame(width: 234)
    }
}

/// Star gaps belong to the star immediately before them; dragging outside the
/// rail clamps to the endpoints. A dedicated zero button keeps nil distinct.
enum RatingSelection {
    static func value(at x: CGFloat) -> Double {
        guard x.isFinite else { return 0 }
        if x <= 0 { return 0 }
        if x >= 234 { return 5 }
        let index = min(4, Int(x / 48))
        let within = min(42, max(0, x - CGFloat(index) * 48))
        return min(5, Double(index) + ceil(Double(within / 42) * 4) / 4)
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

private struct FractionalStar: View, Animatable {
    var fill: Double
    var size: CGFloat = 18
    var animatableData: Double { get { fill } set { fill = newValue } }

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
            .font(.system(size: size, weight: .regular))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
