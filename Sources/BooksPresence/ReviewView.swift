import SwiftUI
import BooksCore

@MainActor
struct ReviewView: View {
    @ObservedObject var model: AppModel
    let present: (DashboardSheet) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading(title: "Review", subtitle: "Review reading time alongside page totals and manual corrections.")
                if model.uncertainIntervals.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(ReadingPalette.moss)
                        Text("No intervals are awaiting review.")
                    }
                    .readingPanel()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Awaiting review").font(.system(.title2, design: .serif))
                        ForEach(model.uncertainIntervals.sorted { $0.start > $1.start }) { interval in
                            UncertainIntervalRow(model: model, interval: interval, edit: { present(.review(interval)) })
                            Divider()
                        }
                    }
                    .readingPanel()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recorded reading spans").font(.system(.title2, design: .serif))
                    Text("Adjacent checkpoint fragments are shown as one continuous span. Review records a correction with its replacement; deleting removes the selected session and related corrections.")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.displayIntervals.isEmpty {
                        Text("No stored intervals yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.displayIntervals.sorted { $0.start > $1.start }) { interval in
                            ReviewIntervalRow(model: model, interval: interval, edit: { present(.review(interval)) })
                            Divider()
                        }
                    }
                }
                .readingPanel()
            }
            .padding(32)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .buttonStyle(ReadingButtonStyle())
    }
}

@MainActor
struct UncertainIntervalRow: View {
    @ObservedObject var model: AppModel
    let interval: ReadingInterval
    let edit: () -> Void
    @State private var discardConfirmation = false
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "clock.badge.questionmark").font(.title3).foregroundStyle(ReadingPalette.ochre)
            IntervalSummary(interval: interval, book: model.books.first { $0.id == interval.bookID }, pageTurns: model.pages(forSessionID: interval.sessionID))
            Spacer()
            Button("Confirm") { model.resolveUncertain(interval, confirm: true) }
            Button("Trim", action: edit)
            Button("Discard", role: .destructive) { discardConfirmation = true }
        }
        .alert("Discard this uncertain interval?", isPresented: $discardConfirmation) {
            Button("Discard", role: .destructive) { model.resolveUncertain(interval, confirm: false) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the interval from credited totals. The review decision remains part of the record.")
        }
    }
}

@MainActor
struct ReviewIntervalRow: View {
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
                .buttonStyle(.borderless).accessibilityLabel("Delete session")
        }
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
            Text(book?.title ?? "Unknown book").font(.headline)
            Text(ReadingFormat.observedPages(pageTurns))
                .font(.callout).monospacedDigit()
            Text("\(ReadingFormat.date(interval.start)) · \(ReadingFormat.duration(interval.duration))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Text("\(interval.mode.rawValue.capitalized) · \(interval.disposition.rawValue.capitalized)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
struct IntervalReviewEditor: View {
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review interval").font(.system(.title2, design: .serif))
                Spacer()
                Button("Done") { dismiss() }
            }.padding(20)
            Divider()
            Form {
                Section("Recorded pages") {
                    Text(ReadingFormat.observedPages(model.pages(forSessionID: interval.sessionID)))
                    Text("Includes automatic observations and explicit manual page corrections. Changing time does not add pages.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Stored interval") {
                    DatePicker("Start", selection: $start)
                    DatePicker("End", selection: $end, in: start...)
                    Picker("Book", selection: $bookID) {
                        ForEach(model.books) { book in
                            Text(book.title).tag(book.id)
                        }
                    }
                    Picker("Treatment", selection: $disposition) {
                        Text("Credited").tag(IntervalDisposition.credited)
                        Text("Awaiting review").tag(IntervalDisposition.uncertain)
                        Text("Excluded").tag(IntervalDisposition.excluded)
                    }
                    Text("Credited is inferred reading activity. Excluded time remains visible for audit but does not count.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Make a correction") {
                    Button("Save interval changes") {
                        model.reviewInterval(interval, start: start, end: end, bookID: bookID, disposition: disposition)
                        dismiss()
                    }
                    .disabled(end <= start || bookID.isEmpty)
                    DatePicker("Split at", selection: $splitAt, in: start...end)
                    Button("Split interval") {
                        model.splitInterval(interval, at: splitAt)
                        dismiss()
                    }
                    .disabled(splitAt <= start || splitAt >= end)
                }
                Section("Delete") {
                    Button("Delete this session", role: .destructive) { deletionConfirmation = true }
                    Text("Deletion permanently removes the session and related correction records.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.vertical, 8)
        }
        .frame(width: 520, height: 540)
        .background(ReadingPalette.paper)
        .alert("Delete this session?", isPresented: $deletionConfirmation) {
            Button("Delete session", role: .destructive) { model.deleteSession(interval.sessionID); dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes this session and related correction records.")
        }
    }
}
