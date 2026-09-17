import SwiftUI
import BooksCore
import UniformTypeIdentifiers

@MainActor
struct LibraryView: View {
    @ObservedObject var model: AppModel
    let present: (DashboardSheet) -> Void
    @State private var shelf = LibraryShelf.all
    @State private var search = ""
    @State private var sort = LibrarySort.recent
    @State private var removingBook: BookRecord?
    @State private var removingEPUB: BookRecord?
    @State private var loggingAudio = false

    var body: some View {
        let resolver = BookMergeResolver(merges: model.merges)
        let books = model.books.filter { resolver.resolvedID(for: $0.id) == $0.id }
        let finishedIDs = Set(model.finishedBooks.map { resolver.resolvedID(for: $0.id) })
        let recent = model.intervals.reduce(into: [String: Date]()) { result, interval in
            let id = resolver.resolvedID(for: interval.bookID)
            result[id] = max(result[id] ?? .distantPast, interval.end)
        }
        let finishes = model.finishedBooks.reduce(into: [String: Date]()) { result, entry in
            guard let date = entry.finishedAt else { return }
            let id = resolver.resolvedID(for: entry.id)
            result[id] = max(result[id] ?? .distantPast, date)
        }
        let positions = model.progress.reduce(into: [String: ProgressObservation]()) { result, observation in
            guard observation.reliable else { return }
            let id = resolver.resolvedID(for: observation.bookID)
            if result[id].map({ $0.observedAt < observation.observedAt }) ?? true { result[id] = observation }
        }
        let visible = books.filter { book in
            (shelf == .all || (shelf == .finished ? finishedIDs.contains(book.id) : !finishedIDs.contains(book.id)))
                && (search.isEmpty || book.title.localizedCaseInsensitiveContains(search) || (book.author ?? "").localizedCaseInsensitiveContains(search))
        }.sorted { lhs, rhs in
            switch sort {
            case .recent:
                let left = shelf == .finished ? finishes[lhs.id] : recent[lhs.id]
                let right = shelf == .finished ? finishes[rhs.id] : recent[rhs.id]
                if left != right { return (left ?? .distantPast) > (right ?? .distantPast) }
            case .author:
                let order = (lhs.author ?? "").localizedStandardCompare(rhs.author ?? "")
                if order != .orderedSame { return order == .orderedAscending }
            case .title: break
            }
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader("Library", subtitle: "\(books.count) \(books.count == 1 ? "book" : "books")") {
                    HStack(spacing: 8) {
                        Button { model.epubLibrary.chooseFiles() } label: { Label("Import EPUBs", systemImage: "square.and.arrow.down") }
                            .controlSize(.small)
                        Menu {
                            Button("Import local audio…") { model.chooseAudiobook() }
                            Button("Log audiobook progress…") { loggingAudio = true }
                        } label: { Label("Audiobook", systemImage: "headphones") }.disabled(model.importingAudio)
                        Button { present(.manualAdd) } label: { Label("Add reading", systemImage: "plus") }
                            .controlSize(.small)
                    }
                }
                EPUBImportStatusView(controller: model.epubLibrary)
                if model.importingAudio { ProgressView("Importing local audio…") }
                AudiobookLibraryPlayer(model: model, player: model.audiobookPlayer)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { shelfPicker(books: books, finishedIDs: finishedIDs).frame(width: 380); Spacer(minLength: 12); searchAndSort }
                    VStack(alignment: .leading, spacing: 14) { shelfPicker(books: books, finishedIDs: finishedIDs); searchAndSort }
                }
                if visible.isEmpty {
                    ReadingEmptyState(title: search.isEmpty ? (shelf == .finished ? "Stories to look back on" : "Your next chapter awaits") : "No matching books",
                        symbol: "books.vertical",
                        message: search.isEmpty ? (shelf == .finished ? "Books you mark finished will appear here." : "Import an EPUB, open a book in Apple Books, or add a reading session to start your shelf.") : "Try another title or author.")
                        .padding(.vertical, 35)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 28, alignment: .topLeading)],
                              alignment: .leading, spacing: 36) {
                        ForEach(visible) { book in
                            VStack(alignment: .leading, spacing: 2) {
                                BookLibraryCard(book: book, pages: model.pages(forBookID: book.id),
                                    finished: finishedIDs.contains(book.id), date: finishedIDs.contains(book.id) ? finishes[book.id] : recent[book.id],
                                    rating: model.rating(for: book.id), progress: positions[book.id]) { present(.book(book)) }
                                HStack {
                                    if model.hasImportedEPUB(book) && model.hasEPUB(book) {
                                        Button("Read") { model.readEPUB(book) }.controlSize(.small)
                                    } else if model.canReadAppleBooksCopy(book) {
                                        // Books added to Apple Books by the reader open here; store purchases stay in Apple Books.
                                        Button(model.preparingAppleBooksIDs.contains(book.id) ? "Opening…" : "Read here") { model.readFromAppleBooks(book) }
                                            .controlSize(.small).disabled(model.preparingAppleBooksIDs.contains(book.id))
                                            .help("Open the copy Apple Books keeps of this book. Apple Books is not changed.")
                                    } else if model.hasImportedEPUB(book) {
                                        Button("Import to read") { model.epubLibrary.chooseFiles() }.controlSize(.small)
                                    }
                                    Spacer()
                                    Menu {
                                        Button {
                                            if let entry = model.markFinished(book) { present(.completion(entry)) }
                                        } label: { Label("Mark as finished", systemImage: "checkmark.circle") }.disabled(finishedIDs.contains(book.id))
                                        Divider()
                                        if model.hasEPUB(book) {
                                            Button("Export notes and reading settings…") { model.transferReaderState(book, importing: false) }
                                            Button("Import notes and reading settings…") { model.transferReaderState(book, importing: true) }
                                            Divider()
                                            Button("Remove EPUB…") { removingEPUB = book }
                                        } else {
                                            Button("Delete journal entry…", role: .destructive) { removingBook = book }
                                        }
                                    } label: { Image(systemName: "ellipsis").frame(width: 32, height: 28).contentShape(Rectangle()) }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                    .foregroundStyle(ReadingPalette.secondaryInk)
                                    .accessibilityLabel("Actions for \(book.title)")
                                }.padding(.horizontal, 6)
                            }
                        }
                    }
                }
            }
            .readingPage()
        }
        .buttonStyle(ReadingButtonStyle())
        .sheet(isPresented: $loggingAudio) { AudiobookLogView(model: model) }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { model.epubLibrary.acceptDrop($0) }
        .alert("Remove the managed EPUB?", isPresented: Binding(get: { removingEPUB != nil }, set: { if !$0 { removingEPUB = nil } })) {
            Button("Keep EPUB elsewhere…") {
                if let book = removingEPUB { model.removeEPUB(book, keepCopy: true) }; removingEPUB = nil
            }
            Button("Move EPUB to Trash", role: .destructive) {
                if let book = removingEPUB { model.removeEPUB(book, keepCopy: false) }; removingEPUB = nil
            }
            Button("Cancel", role: .cancel) { removingEPUB = nil }
        } message: {
            Text("Your history, rating, review and saved reading state stay in Stillleaf. Keep a usable copy elsewhere, or move only Stillleaf's managed EPUB files to Trash. The original file you imported stays untouched.")
        }
        .alert("Remove from library?", isPresented: Binding(get: { removingBook != nil }, set: { if !$0 { removingBook = nil } })) {
            Button("Remove book", role: .destructive) {
                if let book = removingBook { model.deleteBook(book) }
                removingBook = nil
            }
            Button("Cancel", role: .cancel) { removingBook = nil }
        } message: {
            Text("This removes \(removingBook?.title ?? "this book") and its Stillleaf history, rating and review. The original Apple Books file stays untouched. Managed backups are cleared; exports saved elsewhere remain.")
        }
    }
}

extension LibraryView {
    fileprivate func shelfPicker(books: [BookRecord], finishedIDs: Set<String>) -> some View {
        ReadingSegmentedControl(label: "Bookshelf", options: [LibraryShelf.reading, .finished, .all], selection: $shelf) { item in
            switch item {
            case .reading: return "Reading · \(books.filter { !finishedIDs.contains($0.id) }.count)"
            case .finished: return "Finished · \(finishedIDs.count)"
            case .all: return "All · \(books.count)"
            }
        }
    }

    fileprivate var searchAndSort: some View {
        HStack(spacing: 10) {
            TextField("Find a title or author", text: $search)
                .textFieldStyle(ReadingTextFieldStyle()).frame(minWidth: 180, maxWidth: 260)
            Menu {
                Picker("Sort books", selection: $sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { value in Text(value.rawValue).tag(value) }
                }
            } label: { Label(sort.rawValue, systemImage: "arrow.up.arrow.down") }
            .menuStyle(.borderlessButton).fixedSize()
            .foregroundStyle(ReadingPalette.ink)
            .accessibilityLabel("Sort books")
        }
    }
}

private enum LibraryShelf: Hashable { case reading, finished, all }
private enum LibrarySort: String, CaseIterable { case recent = "Recent", title = "Title", author = "Author" }

struct BookLibraryCard: View {
    let book: BookRecord
    let pages: Int
    let finished: Bool
    let date: Date?
    let rating: Double?
    var progress: ProgressObservation? = nil
    let open: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var progressLabel: LibraryProgressLabel {
        LibraryProgressLabel.saved(progress, pagesLogged: pages, finished: finished)
    }
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                BookCoverView(book: book, size: .shelfLarge)
                    // Apply emphasis before the flexible grid frame: its geometry is the
                    // clipped 150 × 225 cover, not the column or variable-height caption.
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(ReadingPalette.accent.opacity(hovering ? 0.55 : 0), lineWidth: 1))
                    .shadow(color: Color.black.opacity(hovering ? 0.14 : 0), radius: 3, x: 0, y: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title).font(ReadingType.bookTitle(16))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(book.author?.isEmpty == false ? book.author! : "Author unavailable")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(progressLabel.primary)
                            .font(.callout.weight(.semibold)).foregroundStyle(ReadingPalette.accent)
                        if let rating {
                            Label(rating.formatted(.number.precision(.fractionLength(0...2))), systemImage: "star.fill")
                                .font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.warning)
                        }
                    }.padding(.top, 2)
                    if let detail = progressLabel.detail {
                        Text(detail).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    }
                    if date != nil || progress == nil || finished {
                        Text(date.map { "\(finished ? "Finished" : "Last read") \($0.formatted(date: .abbreviated, time: .omitted))" } ?? (finished ? "Date unavailable" : "No reading recorded yet"))
                            .font(.caption2).foregroundStyle(ReadingPalette.secondaryInk).lineLimit(1)
                    }
                }
                .padding(.horizontal, 2)
            }
            .foregroundStyle(ReadingPalette.ink).padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain).focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(focused ? ReadingPalette.accent : .clear, lineWidth: 2))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : ReadingMotion.hover, value: hovering)
        .accessibilityLabel("\(book.title), \(book.author ?? "author unavailable"), \(progressLabel.accessibilityText)")
        .accessibilityHint("Open book details and rating")
    }
}

@MainActor
struct BookDetailView: View {
    @ObservedObject var model: AppModel
    let book: BookRecord
    @Environment(\.dismiss) private var dismiss
    @State private var reviewInterval: ReadingInterval?
    @State private var deleteBookConfirmation = false
    @State private var completionEntry: FinishedBookEntry?
    @State private var deleteSessionID: String?
    @State private var mergePresented = false
    @State private var showAllSessions = false
    @State private var publicCoverURLDraft = ""
    @State private var editingDates = false

    private var resolver: BookMergeResolver { BookMergeResolver(merges: model.merges) }
    private var currentBook: BookRecord { model.books.first(where: { $0.id == book.id }) ?? book }
    private var relatedBookIDs: Set<String> {
        Set(model.books.filter { resolver.resolvedID(for: $0.id) == book.id }.map(\.id))
    }
    private var sessions: [ReadingInterval] {
        model.displayIntervals.filter { relatedBookIDs.contains($0.bookID) }.sorted { $0.start > $1.start }
    }
    private var sessionGroups: [ReadingSessionGroup] {
        model.visibleReadingSessions.filter { relatedBookIDs.contains($0.bookID) }.sorted { $0.start > $1.start }
    }
    private var observations: [ProgressObservation] {
        model.progress.filter { relatedBookIDs.contains($0.bookID) }.sorted { $0.observedAt > $1.observedAt }
    }
    private var credited: Double { sessions.filter { $0.disposition == .credited }.reduce(0) { $0 + $1.duration } }
    private var listeningCredited: Double {
        sessions.filter { $0.disposition == .credited && model.isListening($0) }.reduce(0) { $0 + $1.duration }
    }
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
                    AudiobookSection(model: model, book: currentBook, player: model.audiobookPlayer)
                    readingSummary
                    BookRatingSection(model: model, bookID: currentBook.id)
                    BookReviewSection(model: model, bookID: currentBook.id)
                    sessionHistory
                    privacyControls
                    DisclosureGroup("Cover art & sharing details") { artworkControls.padding(.top, 8) }
                        .font(.callout).padding(.horizontal, 4)
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
        .sheet(item: $completionEntry) { CompletionReviewSheet(model: model, entry: $0).readingMotionAccessibility() }
        .sheet(item: $reviewInterval) { IntervalReviewEditor(model: model, interval: $0) }
        .sheet(isPresented: $mergePresented) { MergeBooksView(model: model, source: currentBook) }
        .sheet(isPresented: $editingDates) {
            if let entry = finishedEntry {
                ReadingDatesEditor(title: entry.title,
                    dates: ReadingCompletionDates(startedAt: entry.startedAt, finishedAt: entry.finishedAt),
                    timezoneID: model.timezoneID) { dates in model.saveReadingDates(dates, for: entry.id) }
            }
        }
        .onAppear { publicCoverURLDraft = model.publicCoverURL(for: currentBook) }
        .alert("Delete \(currentBook.title)?", isPresented: $deleteBookConfirmation) {
            Button("Delete book", role: .destructive) { model.deleteBook(currentBook); dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes its Stillleaf history, rating and review, and clears managed backups. The original Apple Books file and exports saved elsewhere remain.")
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
                Text("Book details").font(ReadingType.bookTitle(19))
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
        HStack(alignment: .top, spacing: 24) {
            BookCoverView(book: currentBook, size: .hero)
            VStack(alignment: .leading, spacing: 7) {
                Text(currentBook.title)
                    .font(ReadingType.bookTitle(30))
                    .foregroundStyle(ReadingPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(currentBook.author?.isEmpty == false ? currentBook.author! : "Author unavailable")
                    .font(.callout)
                    .foregroundStyle(ReadingPalette.fadedInk)
                if let finishedEntry {
                    HStack(spacing: 10) {
                        Label(finishedEntry.finishedAt.map { "Finished \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Marked finished", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(ReadingPalette.accent)
                        Button("Edit reading dates") { editingDates = true }
                            .controlSize(.small)
                            .accessibilityHint("Change when you started and finished this book")
                    }.padding(.top, 4)
                }
                if finishedEntry == nil {
                    Button { completionEntry = model.markFinished(currentBook) } label: { Label("Mark as finished", systemImage: "checkmark.circle") }
                        .controlSize(.small).buttonStyle(ReadingButtonStyle(emphasis: .primary))
                }
                if let ratingText {
                    Label("Your rating: \(ratingText)", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(ReadingPalette.ochre)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var readingSummary: some View {
        ReadingSection("Reading at a glance") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 0) {
                    if currentBook.resolvedFormat != .audiobook {
                        StatLine(value: "\(observedPages)", label: "Pages")
                        Hairline(axis: .vertical).frame(height: 44).padding(.horizontal, 18)
                    }
                    StatLine(value: ReadingFormat.duration(currentBook.resolvedFormat == .audiobook ? listeningCredited : credited), label: currentBook.resolvedFormat == .audiobook ? "Listening time" : "Reading time")
                    if currentBook.resolvedFormat == .audiobook && credited > listeningCredited {
                        Hairline(axis: .vertical).frame(height: 44).padding(.horizontal, 18)
                        StatLine(value: ReadingFormat.duration(credited - listeningCredited), label: "Other reading time")
                    }
                    if currentBook.resolvedFormat != .audiobook {
                        Hairline(axis: .vertical).frame(height: 44).padding(.horizontal, 18)
                        StatLine(value: ReadingFormat.pagesPerMinute(pagesPerMinute) ?? "Building pace", label: "Pace")
                    }
                }
                let corrected = model.manualPages(forBookID: currentBook.id)
                if corrected > 0 {
                    Text("Includes \(corrected) manually added pages. Pace uses automatic observations only.")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var sessionHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session history").font(ReadingType.bookTitle(19)).foregroundStyle(ReadingPalette.ink)
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
                            audio: model.audiobookProgress(in: group),
                            isAudiobook: group.intervals.contains { model.isListening($0) },
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
            Text("This book").font(ReadingType.bookTitle(19)).foregroundStyle(ReadingPalette.ink)
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
                    Text("Discord artwork").font(ReadingType.bookTitle(19)).foregroundStyle(ReadingPalette.ink)
                    Text(artworkStatus).font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                }
                Spacer()
                Image(systemName: model.publicCoverURL(for: currentBook).isEmpty ? "photo.on.rectangle.angled" : "checkmark.seal.fill")
                    .foregroundStyle(model.publicCoverURL(for: currentBook).isEmpty ? ReadingPalette.fadedInk : ReadingPalette.moss)
            }
            if currentBook.source != "stillleaf-epub" {
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
            } else {
                Text("Reading here uses local cover art only. Discord uses the app's generic artwork; your EPUB cover is never uploaded.")
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
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
    let audio: AudiobookProgress?
    let isAudiobook: Bool
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
                Text(audio.map { "\($0.fraction.formatted(.percent.precision(.fractionLength(0...1)))) · \($0.description)" } ?? (isAudiobook ? "Listening" : ReadingFormat.observedPages(pages)))
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
            if let audio = observation.audio {
                Text("\(audio.fraction.formatted(.percent.precision(.fractionLength(0...1)))) · \(audio.description)")
            } else if observation.reliable, let fraction = observation.fraction {
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
        .foregroundStyle(observation.reliable ? ReadingPalette.accent : ReadingPalette.secondaryInk)
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
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ReadingFormat.observedPages(pageTurns)).monospacedDigit()
                Text(ReadingFormat.duration(interval.duration)).font(.caption).monospacedDigit().foregroundStyle(ReadingPalette.secondaryInk)
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
