import SwiftUI
import BooksCore

@MainActor
struct ReadingSessionsView: View {
    @ObservedObject var model: AppModel
    let present: (DashboardSheet) -> Void
    var showsHeading = true
    @State private var visibleCount = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if showsHeading { PageHeading(title: "Reading records", subtitle: "Optional edits to saved reading sessions.") }
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("Reading history").font(ReadingType.bookTitle(21))
                    Text("Adjust the book, time, or status of a saved session.")
                        .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                    if model.displayIntervals.isEmpty {
                        Text("Your saved reading will appear here.").foregroundStyle(ReadingPalette.secondaryInk)
                    } else {
                        ForEach(model.displayIntervals.prefix(visibleCount)) { interval in
                            ReadingSessionRow(model: model, interval: interval, edit: { present(.review(interval)) })
                            Divider().opacity(0.45)
                        }
                        if model.displayIntervals.count > visibleCount {
                            Button("Show more reading history") { visibleCount += 30 }.padding(.top, 8)
                        }
                    }
                }
                .readingPanel()
            }
            .frame(maxWidth: 1060, alignment: .leading).padding(30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(ReadingButtonStyle())
    }
}

@MainActor
struct ReadingSessionRow: View {
    @ObservedObject var model: AppModel
    let interval: ReadingInterval
    let edit: () -> Void
    @State private var deletionConfirmation = false
    var body: some View {
        HStack(spacing: 14) {
            IntervalSummary(interval: interval, book: model.books.first { $0.id == interval.bookID }, pageTurns: model.pages(forSessionID: interval.sessionID))
            Spacer()
            Button("Edit", action: edit)
            Button(role: .destructive, action: { deletionConfirmation = true }) { Image(systemName: "trash") }
                .buttonStyle(ReadingButtonStyle(iconOnly: true)).accessibilityLabel("Delete session")
        }
        .controlSize(.small).padding(.vertical, 10)
        .alert("Delete this session?", isPresented: $deletionConfirmation) {
            Button("Delete session", role: .destructive) { model.deleteSession(interval.sessionID) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes this session and related correction records.")
        }
    }
}

struct IntervalSummary: View {
    let interval: ReadingInterval
    let book: BookRecord?
    let pageTurns: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(book?.title ?? "Unknown book").font(.headline).lineLimit(2)
            Text("\(pageTurns) pages")
                .font(.callout).monospacedDigit()
            Text("\(ReadingFormat.date(interval.start)) · \(ReadingFormat.duration(interval.duration))")
                .font(.caption).monospacedDigit().foregroundStyle(ReadingPalette.secondaryInk)
            Text("\(interval.mode.rawValue.capitalized) · \(interval.disposition.rawValue.capitalized)")
                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
        }
    }
}

@MainActor
struct ReadingSessionEditor: View {
    @ObservedObject var model: AppModel
    let interval: ReadingInterval
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    @State private var bookID: String
    @State private var disposition: IntervalDisposition
    @State private var splitAt: Date
    @State private var deletionConfirmation = false

    init(model: AppModel, interval: ReadingInterval) {
        self.model = model
        self.interval = interval
        _start = State(initialValue: interval.start)
        _end = State(initialValue: interval.end)
        _bookID = State(initialValue: interval.bookID)
        _disposition = State(initialValue: interval.disposition)
        _splitAt = State(initialValue: interval.start.addingTimeInterval(interval.duration / 2))
    }
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReadingSheetHeader(title: "Edit reading session", subtitle: nil, close: { dismiss() }).padding(24)
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(ReadingPalette.warning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        ReadingMenuPicker(label: "Book", options: model.books.map(\.id), selection: $bookID) { id in
                            model.books.first { $0.id == id }?.title ?? "Choose a book"
                        }
                        ReadingDatePicker("Started", selection: $start, maximumDate: Date())
                        ReadingDatePicker("Finished", selection: $end, minimumDate: start, maximumDate: Date())
                        ReadingSegmentedControl(label: "Treatment", options: [IntervalDisposition.credited, .excluded], selection: $disposition) { value in
                            switch value {
                            case .credited: return "Count this time"
                            case .excluded: return "Exclude"
                            }
                        }
                        Text("\(model.pages(forSessionID: interval.sessionID)) pages saved for this session. Changing its time does not add pages.")
                            .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                        if end <= start || end > Date() {
                            Text("Choose a finish time after the start and no later than now.")
                                .font(.caption).foregroundStyle(ReadingPalette.warning)
                        }
                        Button("Save changes") {
                            finish(model.editInterval(interval, start: start, end: end, bookID: bookID, disposition: disposition))
                        }
                        .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(end <= start || end > Date() || bookID.isEmpty)
                    }.readingPanel()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Split this reading span").font(.headline)
                        ReadingDatePicker("Split at", selection: $splitAt, minimumDate: interval.start, maximumDate: interval.end)
                        Button("Split reading") { finish(model.splitInterval(interval, at: splitAt)) }
                            .disabled(splitAt <= interval.start || splitAt >= interval.end)
                    }.readingPanel()
                    HStack(spacing: 12) {
                        Text("Deleting removes the whole session and its corrections.").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                        Spacer()
                        Button("Delete session", role: .destructive) { deletionConfirmation = true }
                    }.padding(.vertical, 8)
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .frame(width: 560, height: 600)
        .background(ReadingPalette.paper).foregroundStyle(ReadingPalette.ink)
        .tint(ReadingPalette.moss).buttonStyle(ReadingButtonStyle())
        .alert("Delete this session?", isPresented: $deletionConfirmation) {
            Button("Delete session", role: .destructive) { finish(model.deleteSession(interval.sessionID)) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes this session and related correction records.")
        }
    }
    private func finish(_ saved: Bool) {
        if saved { dismiss() }
        else { saveError = model.errorMessage ?? "Could not save this change. Try again." }
    }
}
