import SwiftUI
import BooksCore

@MainActor
struct LibraryView: View {
    @ObservedObject var model: AppModel
    let present: (DashboardSheet) -> Void

    var body: some View {
        let resolver = BookMergeResolver(merges: model.merges)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading(title: "Library", subtitle: "Books remain distinct unless you explicitly merge identities.")
                if visibleBooks(resolver: resolver).isEmpty {
                    ReadingEmptyState(title: "No books recorded", symbol: "books.vertical", message: "A verified Books reader or a manual record will add a book here.")
                        .padding(.vertical, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 270), spacing: 16)], spacing: 16) {
                        ForEach(visibleBooks(resolver: resolver)) { book in
                            BookLibraryCard(book: book, intervals: intervals(for: book, resolver: resolver)) {
                                present(.book(book))
                            }
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 1120, alignment: .leading)
        }
    }

    private func visibleBooks(resolver: BookMergeResolver) -> [BookRecord] {
        model.books.filter { resolver.resolvedID(for: $0.id) == $0.id }
    }

    private func intervals(for book: BookRecord, resolver: BookMergeResolver) -> [ReadingInterval] {
        model.intervals.filter { resolver.resolvedID(for: $0.bookID) == book.id }
    }
}

struct BookLibraryCard: View {
    let book: BookRecord
    let intervals: [ReadingInterval]
    let open: () -> Void
    private var credited: Double { intervals.filter { $0.disposition == .credited }.reduce(0) { $0 + $1.duration } }
    private var firstRead: Date? { intervals.map(\.start).min() }
    private var lastRead: Date? { intervals.map(\.end).max() }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                BookCoverView(book: book, size: .library)
                VStack(alignment: .leading, spacing: 5) {
                    Text(book.title).font(.system(.headline, design: .serif)).lineLimit(2)
                    Text(book.author?.isEmpty == false ? book.author! : "Author unavailable")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 3)
                    Text(ReadingFormat.duration(credited)).font(.headline).monospacedDigit()
                    Text("First: \(ReadingFormat.date(firstRead))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("Last: \(ReadingFormat.date(lastRead))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.46), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ReadingPalette.ink.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(book.title)")
    }
}

@MainActor
struct BookDetailView: View {
    @ObservedObject var model: AppModel
    let book: BookRecord
    @Environment(\.dismiss) private var dismiss
    @State private var reviewInterval: ReadingInterval?
    @State private var deleteBookConfirmation = false
    @State private var deleteSessionID: String?
    @State private var mergePresented = false

    private var resolver: BookMergeResolver { BookMergeResolver(merges: model.merges) }
    private var currentBook: BookRecord { model.books.first(where: { $0.id == book.id }) ?? book }
    private var relatedBookIDs: Set<String> {
        Set(model.books.filter { resolver.resolvedID(for: $0.id) == book.id }.map(\.id))
    }

    private var sessions: [ReadingInterval] {
        model.displayIntervals.filter { relatedBookIDs.contains($0.bookID) }.sorted { $0.start > $1.start }
    }
    private var observations: [ProgressObservation] {
        model.progress.filter { relatedBookIDs.contains($0.bookID) }.sorted { $0.observedAt > $1.observedAt }
    }
    private var credited: Double { sessions.filter { $0.disposition == .credited }.reduce(0) { $0 + $1.duration } }
    private var latestProgress: ProgressObservation? { observations.first(where: { $0.reliable }) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Book details").font(.system(.title2, design: .serif))
                Spacer()
                Button("Done") { dismiss() }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 18) {
                        BookCoverView(book: currentBook, size: .large)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(currentBook.title).font(.system(size: 28, weight: .medium, design: .serif))
                            Text(currentBook.author?.isEmpty == false ? currentBook.author! : "Author unavailable").foregroundStyle(.secondary)
                            Text("\(ReadingFormat.duration(credited)) credited time")
                                .font(.headline).monospacedDigit()
                            if let latestProgress {
                                ProgressDescription(observation: latestProgress)
                            } else {
                                Text("No reliable progress observed.").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    GroupBox("Privacy and tracking") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Exclude this book from tracking", isOn: exclusionBinding(tracking: true))
                            Toggle("Exclude this book from Discord sharing", isOn: exclusionBinding(tracking: false))
                            Text("These controls do not erase recorded history.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 4)
                    }

                    HStack(spacing: 12) {
                        Button("Choose cover image") { model.chooseCover(for: currentBook) }
                        Button("Merge with another book") { mergePresented = true }
                        if activeMerges.isEmpty {
                            Button("Delete book", role: .destructive) { deleteBookConfirmation = true }
                        }
                    }

                    if !activeMerges.isEmpty {
                        MergeStatusList(model: model, book: book)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Observed progress").font(.system(.title2, design: .serif))
                        if observations.isEmpty {
                            Text("No progress observations have been saved for this book.").foregroundStyle(.secondary)
                        } else {
                            ForEach(observations) { observation in
                                HStack {
                                    ProgressDescription(observation: observation)
                                    Spacer()
                                    Text(ReadingFormat.date(observation.observedAt)).font(.caption).foregroundStyle(.secondary)
                                }
                                Divider()
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Session timeline").font(.system(.title2, design: .serif))
                        Text("Adjacent checkpoint fragments appear as one span. Review adjusts a correction record rather than hiding its source.")
                            .font(.callout).foregroundStyle(.secondary)
                        if sessions.isEmpty {
                            Text("No sessions have been recorded for this book.").foregroundStyle(.secondary)
                        } else {
                            ForEach(sessions) { interval in
                                SessionRow(interval: interval, review: { reviewInterval = interval }, delete: { deleteSessionID = interval.sessionID })
                                Divider()
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 720, height: 720)
        .background(ReadingPalette.paper)
        .tint(ReadingPalette.moss)
        .sheet(item: $reviewInterval) { IntervalReviewEditor(model: model, interval: $0) }
        .sheet(isPresented: $mergePresented) { MergeBooksView(model: model, source: currentBook) }
        .alert("Delete \(currentBook.title)?", isPresented: $deleteBookConfirmation) {
            Button("Delete book", role: .destructive) { model.deleteBook(currentBook); dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes this book and its stored data.")
        }
        .alert("Delete this session?", isPresented: Binding(get: { deleteSessionID != nil }, set: { if !$0 { deleteSessionID = nil } })) {
            Button("Delete session", role: .destructive) {
                if let deleteSessionID { model.deleteSession(deleteSessionID) }
                deleteSessionID = nil
            }
            Button("Cancel", role: .cancel) { deleteSessionID = nil }
        } message: {
            Text("This permanently removes this session and its related correction records.")
        }
    }

    private func exclusionBinding(tracking: Bool) -> Binding<Bool> {
        Binding(get: {
            let current = model.books.first(where: { $0.id == book.id }) ?? book
            return tracking ? current.trackingExcluded : current.sharingExcluded
        }, set: { excluded in
            let current = model.books.first(where: { $0.id == book.id }) ?? book
            model.setBookExclusions(current, tracking: tracking ? excluded : current.trackingExcluded, sharing: tracking ? current.sharingExcluded : excluded)
        })
    }

    private var activeMerges: [BookMerge] {
        resolver.activeMerges.filter { $0.sourceID == book.id || $0.targetID == book.id }
    }
}

struct BookMergeResolver {
    private let targets: [String: String]
    let activeMerges: [BookMerge]

    init(merges: [BookMerge]) {
        var latestIndex: [String: Int] = [:]
        for (index, merge) in merges.enumerated() {
            latestIndex[merge.sourceID] = index
        }
        activeMerges = merges.enumerated().compactMap { index, merge in
            latestIndex[merge.sourceID] == index && merge.active ? merge : nil
        }
        targets = activeMerges.reduce(into: [String: String]()) { result, item in
            result[item.sourceID] = item.targetID
        }
    }

    func resolvedID(for id: String) -> String {
        var current = id
        var visited = Set<String>()
        while let next = targets[current], visited.insert(current).inserted {
            current = next
        }
        return current
    }
}

struct ProgressDescription: View {
    let observation: ProgressObservation
    var body: some View {
        Group {
            if observation.reliable, let fraction = observation.fraction {
                Text("Progress \(Int((fraction * 100).rounded()))%")
            } else if observation.reliable, let page = observation.page, let total = observation.totalPages {
                Text("Page \(page) of \(total)")
            } else if let location = observation.location, !location.isEmpty {
                Text("Observed location: \(location)")
            } else {
                Text("Progress observation is not reliable")
            }
        }
        .font(.callout)
        .foregroundStyle(observation.reliable ? ReadingPalette.moss : .secondary)
    }
}

struct SessionRow: View {
    let interval: ReadingInterval
    let review: () -> Void
    let delete: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ReadingFormat.date(interval.start)).font(.headline)
                Text("\(interval.mode.rawValue.capitalized) · \(interval.disposition.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ReadingFormat.duration(interval.duration)).monospacedDigit()
            Button("Review", action: review).controlSize(.small)
            Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless).accessibilityLabel("Delete session")
        }
        .padding(.vertical, 5)
    }
}

@MainActor
struct MergeStatusList: View {
    @ObservedObject var model: AppModel
    let book: BookRecord
    var body: some View {
        let resolver = BookMergeResolver(merges: model.merges)
        GroupBox("Merge decisions") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(resolver.activeMerges.filter { $0.sourceID == book.id || $0.targetID == book.id }) { merge in
                    HStack {
                        Text("Merged with \(otherBookName(merge))").font(.callout)
                        Spacer()
                        Button("Unmerge") { model.unmerge(merge) }.controlSize(.small)
                    }
                }
            }.padding(.top, 4)
        }
    }
    private func otherBookName(_ merge: BookMerge) -> String {
        let identifier = merge.sourceID == book.id ? merge.targetID : merge.sourceID
        return model.books.first(where: { $0.id == identifier })?.title ?? "a deleted book"
    }
}
