import SwiftUI
import BooksCore

@MainActor
struct LibraryView: View {
    @ObservedObject var model: AppModel
    let present: (DashboardSheet) -> Void
    @State private var shelf = LibraryShelf.reading
    @State private var search = ""

    var body: some View {
        let resolver = BookMergeResolver(merges: model.merges)
        let visible = visibleBooks(resolver: resolver)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading(title: "Library", subtitle: "Your books, reading pace, and finished reads.")
                HStack(spacing: 18) {
                    ReadingSegmentedControl(label: "Bookshelf", options: [LibraryShelf.reading, .finished, .all], selection: $shelf) { shelf in
                        switch shelf {
                        case .reading: return "Reading"
                        case .finished: return "Finished · \(model.finishedBooks.count)"
                        case .all: return "All books"
                        }
                    }.frame(maxWidth: 420)
                    Spacer(minLength: 0)
                    TextField("Search title or author", text: $search)
                        .textFieldStyle(ReadingTextFieldStyle()).frame(maxWidth: 240)
                }
                if shelf == .finished {
                    FinishedBookTimeline(model: model, search: search)
                } else if visible.isEmpty {
                    ReadingEmptyState(title: search.isEmpty ? "Your next chapter awaits" : "No matching books", symbol: "books.vertical", message: search.isEmpty ? "Open a book in Apple Books to start your reading journal. Your completed books live on the Finished shelf." : "Try another title or author.")
                        .padding(.vertical, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 16) {
                        ForEach(visible) { book in
                            BookLibraryCard(book: book, pageTurns: model.pages(forBookID: book.id), pagesPerMinute: model.pagesPerMinute(forBookID: book.id), intervals: intervals(for: book, resolver: resolver)) {
                                present(.book(book))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func visibleBooks(resolver: BookMergeResolver) -> [BookRecord] {
        let finishedIDs = Set(model.finishedBooks.map(\.id))
        return model.books.filter {
            resolver.resolvedID(for: $0.id) == $0.id
                && (shelf == .all || !finishedIDs.contains($0.id))
                && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.author ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    private func intervals(for book: BookRecord, resolver: BookMergeResolver) -> [ReadingInterval] {
        model.intervals.filter { resolver.resolvedID(for: $0.bookID) == book.id }
    }
}

private enum LibraryShelf: Hashable { case reading, finished, all }

struct BookLibraryCard: View {
    let book: BookRecord
    let pageTurns: Int
    let pagesPerMinute: Double?
    let intervals: [ReadingInterval]
    let open: () -> Void
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var credited: Double { intervals.filter { $0.disposition == .credited }.reduce(0) { $0 + $1.duration } }
    private var firstRead: Date? { intervals.map(\.start).min() }
    private var lastRead: Date? { intervals.map(\.end).max() }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 16) {
                BookCoverView(book: book, size: .library)
                VStack(alignment: .leading, spacing: 5) {
                    Text(book.title).font(.system(.headline, design: .serif)).lineLimit(2)
                    Text(book.author?.isEmpty == false ? book.author! : "Author unavailable")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Text(ReadingFormat.observedPages(pageTurns)).font(.headline).monospacedDigit().padding(.top, 7)
                    if let pace = ReadingFormat.pagesPerMinute(pagesPerMinute) {
                        Text(pace).font(.caption).monospacedDigit().foregroundStyle(ReadingPalette.moss)
                    }
                    Text("Time: \(ReadingFormat.duration(credited))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if let firstRead {
                        Text("Started \(firstRead.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let lastRead {
                        Text("Last read \(lastRead.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding(18)
            .background(isHovering ? ReadingPalette.elevated : ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isHovering ? ReadingPalette.moss.opacity(0.45) : ReadingPalette.border.opacity(0.45)))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : ReadingMotion.hover, value: isHovering)
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
    @State private var showAllSessions = false
    @State private var publicCoverURLDraft = ""

    private var resolver: BookMergeResolver { BookMergeResolver(merges: model.merges) }
    private var currentBook: BookRecord { model.books.first(where: { $0.id == book.id }) ?? book }
    private var relatedBookIDs: Set<String> {
        Set(model.books.filter { resolver.resolvedID(for: $0.id) == book.id }.map(\.id))
    }
    private var sessions: [ReadingInterval] {
        model.displayIntervals.filter { relatedBookIDs.contains($0.bookID) }.sorted { $0.start > $1.start }
    }
    private var sessionGroups: [ReadingSessionGroup] {
        model.readingSessions.filter { relatedBookIDs.contains($0.bookID) }.sorted { $0.start > $1.start }
    }
    private var observations: [ProgressObservation] {
        model.progress.filter { relatedBookIDs.contains($0.bookID) }.sorted { $0.observedAt > $1.observedAt }
    }
    private var credited: Double { sessions.filter { $0.disposition == .credited }.reduce(0) { $0 + $1.duration } }
    private var observedPages: Int { model.pages(forBookID: currentBook.id) }
    private var pagesPerMinute: Double? { model.pagesPerMinute(forBookID: currentBook.id) }
    private var latestReliableProgress: ProgressObservation? { observations.first(where: { $0.reliable }) }
    private var finishedEntry: FinishedBookEntry? { model.finishedBooks.first { $0.id == currentBook.id } }
    private var ratingText: String? {
        model.rating(for: currentBook.id).map { "\($0.formatted(.number.precision(.fractionLength(0...2)))) / 5" }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    readingSummary
                    sessionHistory
                    privacyControls
                    artworkControls
                    advancedSection
                    footerActions
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .frame(width: 760, height: 720)
        .background(ReadingPalette.paper)
        .tint(ReadingPalette.moss)
        .foregroundStyle(ReadingPalette.ink)
        .buttonStyle(ReadingButtonStyle())
        .sheet(item: $reviewInterval) { IntervalReviewEditor(model: model, interval: $0) }
        .sheet(isPresented: $mergePresented) { MergeBooksView(model: model, source: currentBook) }
        .onAppear { publicCoverURLDraft = model.publicCoverURL(for: currentBook) }
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

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Book details").font(.headline)
                Text("Your local reading journal").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(ReadingButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 18) {
            BookCoverView(book: currentBook, size: .large)
            VStack(alignment: .leading, spacing: 6) {
                Text(currentBook.title)
                    .font(.system(size: 29, weight: .medium, design: .serif))
                    .foregroundStyle(ReadingPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(currentBook.author?.isEmpty == false ? currentBook.author! : "Author unavailable")
                    .font(.callout)
                    .foregroundStyle(ReadingPalette.fadedInk)
                if let finishedEntry {
                    Label(finishedEntry.finishedAt.map { "Finished \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Marked finished", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(ReadingPalette.moss)
                }
                if let ratingText {
                    Label("Your rating: \(ratingText)", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(ReadingPalette.ochre)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var readingSummary: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Reading at a glance").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(ReadingPalette.ink)
            HStack(spacing: 10) {
                BookDetailStat(label: "Pages", value: "\(observedPages)", symbol: "book.pages")
                BookDetailStat(label: "Reading time", value: ReadingFormat.duration(credited), symbol: "clock")
                BookDetailStat(label: "Pace", value: ReadingFormat.pagesPerMinute(pagesPerMinute) ?? "Building pace", symbol: "gauge.with.dots.needle.50percent")
            }
            let corrected = model.manualPages(forBookID: currentBook.id)
            if corrected > 0 {
                Text("Includes \(corrected) manually added pages. Pace uses automatic observations only.")
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            }
        }
        .readingPanel()
    }

    private var sessionHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session history").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(ReadingPalette.ink)
                    Text("Review or remove a saved session.").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                }
                Spacer()
                Text("\(sessionGroups.count) \(sessionGroups.count == 1 ? "session" : "sessions")")
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            }
            if sessionGroups.isEmpty {
                Text("No sessions have been recorded for this book.").foregroundStyle(ReadingPalette.fadedInk)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(showAllSessions ? sessionGroups : Array(sessionGroups.prefix(5))) { group in
                        BookDetailSessionGroup(
                            group: group,
                            pages: model.pages(in: group),
                            review: { reviewInterval = $0 },
                            delete: { deleteSessionID = $0 }
                        )
                    }
                    if sessionGroups.count > 5 {
                        Button(showAllSessions ? "Show recent sessions" : "Show all \(sessionGroups.count) sessions") { showAllSessions.toggle() }
                            .buttonStyle(ReadingButtonStyle())
                    }
                }
            }
        }
        .readingPanel()
    }

    private var privacyControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This book").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(ReadingPalette.ink)
            BookDetailToggleRow(title: "Track reading", message: "Include new reading evidence in your journal.", isOn: trackingBinding)
            Divider()
            BookDetailToggleRow(title: "Share with Discord", message: "Allow this title on your Discord card when sharing is on.", isOn: sharingBinding)
            Text("Changing either setting keeps existing history.")
                .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
        }
        .readingPanel()
    }

    private var artworkControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Discord artwork").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(ReadingPalette.ink)
                    Text(artworkStatus).font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                }
                Spacer()
                Image(systemName: model.publicCoverURL(for: currentBook).isEmpty ? "photo.on.rectangle.angled" : "checkmark.seal.fill")
                    .foregroundStyle(model.publicCoverURL(for: currentBook).isEmpty ? ReadingPalette.fadedInk : ReadingPalette.moss)
            }
            DisclosureGroup("Use a different public cover link") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Public HTTPS image URL", text: $publicCoverURLDraft)
                        .textFieldStyle(ReadingTextFieldStyle())
                        .onSubmit { savePublicCoverURL() }
                    HStack {
                        Button("Save public link") { savePublicCoverURL() }
                            .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                        Spacer()
                        if !publicCoverURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Remove link") { publicCoverURLDraft = ""; savePublicCoverURL() }
                                .controlSize(.small)
                                .buttonStyle(ReadingButtonStyle())
                        }
                    }
                }
                .padding(.top, 7)
            }
            DisclosureGroup("Local cover override") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("This changes the cover saved on this Mac. It is never uploaded or sent to Discord.")
                        .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                    Button("Choose local cover image") { model.chooseCover(for: currentBook) }
                        .buttonStyle(ReadingButtonStyle())
                }
                .padding(.top, 7)
            }
        }
        .readingPanel()
    }

    private var advancedSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                if let latestReliableProgress {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(ReadingPalette.moss)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Latest reliable progress").font(.callout.weight(.medium))
                            ProgressDescription(observation: latestReliableProgress)
                            Text(ReadingFormat.date(latestReliableProgress.observedAt)).font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                        }
                    }
                } else {
                    Text("No reliable saved progress is available for this book.")
                        .font(.callout).foregroundStyle(ReadingPalette.fadedInk)
                }
                Divider()
                HStack {
                    Text("Book management").font(.callout.weight(.medium))
                    Spacer()
                    Button("Merge with another book") { mergePresented = true }
                        .controlSize(.small)
                        .buttonStyle(ReadingButtonStyle())
                }
                ForEach(activeMerges) { merge in
                    HStack {
                        Text("Merged with \(otherBookName(merge))").font(.caption)
                        Spacer()
                        Button("Unmerge") { model.unmerge(merge) }.controlSize(.small).buttonStyle(ReadingButtonStyle())
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Advanced and metadata", systemImage: "slider.horizontal.3")
                .foregroundStyle(ReadingPalette.ink)
        }
        .readingPanel()
    }

    private var footerActions: some View {
        HStack {
            Text("Book details stay on this Mac.").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            Spacer()
            if activeMerges.isEmpty {
                Button("Delete book", role: .destructive) { deleteBookConfirmation = true }
                    .buttonStyle(ReadingButtonStyle())
            }
        }
        .padding(.top, 2)
    }

    private var artworkStatus: String {
        if !model.publicCoverURL(for: currentBook).isEmpty { return "Using a saved public cover link for this card." }
        if model.automaticPublicCovers { return "Automatic public-cover lookup is on. A unique Apple metadata match can add a public link." }
        return "Using your app’s generic artwork when configured. Automatic public-cover lookup is off."
    }

    private var trackingBinding: Binding<Bool> {
        Binding(get: { !currentBook.trackingExcluded }, set: { enabled in
            let current = self.currentBook
            model.setBookExclusions(current, tracking: !enabled, sharing: current.sharingExcluded)
        })
    }

    private var sharingBinding: Binding<Bool> {
        Binding(get: { !currentBook.sharingExcluded }, set: { enabled in
            let current = self.currentBook
            model.setBookExclusions(current, tracking: current.trackingExcluded, sharing: !enabled)
        })
    }

    private var activeMerges: [BookMerge] {
        resolver.activeMerges.filter { $0.sourceID == book.id || $0.targetID == book.id }
    }

    private func otherBookName(_ merge: BookMerge) -> String {
        let identifier = merge.sourceID == book.id ? merge.targetID : merge.sourceID
        return model.books.first(where: { $0.id == identifier })?.title ?? "a deleted book"
    }

    private func savePublicCoverURL() {
        model.savePublicCoverURL(publicCoverURLDraft.trimmingCharacters(in: .whitespacesAndNewlines), for: currentBook)
        publicCoverURLDraft = model.publicCoverURL(for: currentBook)
    }
}

private struct BookDetailStat: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(ReadingPalette.moss)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(10)
        .background(ReadingPalette.paper.opacity(0.62), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct BookDetailToggleRow: View {
    let title: String
    let message: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(ReadingPalette.ink)
                Text(message).font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BookDetailSessionGroup: View {
    let group: ReadingSessionGroup
    let pages: Int
    let review: (ReadingInterval) -> Void
    let delete: (String) -> Void

    var body: some View {
        DisclosureGroup {
            LazyVStack(spacing: 0) {
                ForEach(group.intervals) { interval in
                    BookDetailSessionFragment(
                        interval: interval,
                        review: { review(interval) },
                        delete: { delete(interval.sessionID) }
                    )
                    if interval.id != (group.intervals.last?.id ?? "") { Divider() }
                }
            }
            .padding(.top, 7)
            .buttonStyle(ReadingButtonStyle())
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ReadingFormat.date(group.start)).font(.callout.weight(.semibold)).foregroundStyle(ReadingPalette.ink)
                    Text("Credited \(ReadingFormat.duration(group.creditedSeconds))")
                        .font(.caption).monospacedDigit().foregroundStyle(ReadingPalette.fadedInk)
                }
                Spacer()
                Text(ReadingFormat.observedPages(pages))
                    .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(ReadingPalette.moss)
            }
            .padding(.vertical, 7)
        }
        .padding(.horizontal, 10)
        .background(ReadingPalette.paper.opacity(0.62), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct BookDetailSessionFragment: View {
    let interval: ReadingInterval
    let review: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ReadingFormat.date(interval.start)).font(.callout.weight(.medium))
                Text("\(interval.mode.rawValue.capitalized) · \(interval.disposition.rawValue)")
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            }
            Spacer()
            Text(ReadingFormat.duration(interval.duration))
                .font(.caption).monospacedDigit().foregroundStyle(ReadingPalette.fadedInk)
            Button("Review", action: review).controlSize(.small)
            Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                .accessibilityLabel("Delete session")
        }
        .padding(.vertical, 6)
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
    let pageTurns: Int
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
            VStack(alignment: .trailing, spacing: 2) {
                Text(ReadingFormat.observedPages(pageTurns)).monospacedDigit()
                Text(ReadingFormat.duration(interval.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Button("Review", action: review).controlSize(.small)
            Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                .buttonStyle(ReadingButtonStyle(iconOnly: true)).accessibilityLabel("Delete session")
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
