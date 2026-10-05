import SwiftUI
import BooksCore
import UniformTypeIdentifiers

/// Dashboard-owned browsing choices survive visiting another destination or
/// changing the theme, without keeping an offscreen Library view alive.
@MainActor
final class LibraryBrowseState: ObservableObject {
    @Published var shelf = LibraryShelf.all
    @Published var search = ""
    @Published var sort = LibrarySort.recent
}

@MainActor
struct LibraryView: View {
    @ObservedObject var model: AppModel
    let present: (DashboardSheet) -> Void
    @StateObject private var browsing: LibraryBrowseState

    init(model: AppModel, present: @escaping (DashboardSheet) -> Void, browsing: LibraryBrowseState? = nil) {
        self.model = model
        self.present = present
        _browsing = StateObject(wrappedValue: browsing ?? LibraryBrowseState())
    }
    @State private var removingBook: BookRecord?
    @State private var removingEPUB: BookRecord?
    @State private var loggingAudio = false

    var body: some View {
        let summary = model.librarySummary
        let books = summary.books
        let finishedIDs = summary.finishedIDs
        let recent = summary.recent
        let finishes = summary.finishes
        let positions = model.libraryProgressObservations
        let visible = books.filter { book in
            (browsing.shelf == .all || (browsing.shelf == .finished ? finishedIDs.contains(book.id) : !finishedIDs.contains(book.id)))
                && (browsing.search.isEmpty || book.title.localizedCaseInsensitiveContains(browsing.search) || (book.author ?? "").localizedCaseInsensitiveContains(browsing.search))
        }.sorted { lhs, rhs in
            switch browsing.sort {
            case .recent:
                let left = browsing.shelf == .finished ? finishes[lhs.id] : recent[lhs.id]
                let right = browsing.shelf == .finished ? finishes[rhs.id] : recent[rhs.id]
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
                    ReadingGlassGroup {
                        HStack(spacing: 8) {
                            Button { model.epubLibrary.chooseFiles() } label: { Label("Import EPUBs", systemImage: "square.and.arrow.down") }
                                .controlSize(.small)
                            Menu {
                                Button("Import local audio…") { model.chooseAudiobook() }
                                Button("Log audiobook progress…") { loggingAudio = true }
                            } label: { Label("Audiobook", systemImage: "headphones") }
                                .menuStyle(ReadingMenuStyle())
                                .disabled(model.importingAudio)
                            Button { present(.manualAdd) } label: { Label("Add reading", systemImage: "plus") }
                                .controlSize(.small)
                        }
                    }
                }
                EPUBImportStatusView(controller: model.epubLibrary)
                if model.importingAudio { ProgressView("Importing local audio…") }
                AudiobookLibraryPlayer(model: model, player: model.audiobookPlayer)
                ReadingGlassGroup {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) { shelfPicker(books: books, finishedIDs: finishedIDs); Spacer(minLength: 12); searchAndSort }
                        VStack(alignment: .leading, spacing: 14) { shelfPicker(books: books, finishedIDs: finishedIDs); searchAndSort }
                    }
                }
                if visible.isEmpty {
                    VStack(spacing: 16) {
                        ReadingEmptyState(title: browsing.search.isEmpty ? (browsing.shelf == .finished ? "Stories to look back on" : "Your next chapter awaits") : "No matching books",
                            symbol: "books.vertical",
                            message: browsing.search.isEmpty ? (browsing.shelf == .finished ? "Books you mark finished will appear here." : "Import an EPUB, open a book in Apple Books, or add a reading session to start your shelf.") : "Try another title or author.")
                        if !browsing.search.isEmpty || browsing.shelf != .all {
                            Button("Show all books") { browsing.search = ""; browsing.shelf = .all }
                        }
                    }.padding(.vertical, 35)
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
                                        Button(model.isOpeningEPUB(book) ? "Opening…" : "Read") { model.readEPUB(book) }
                                            .controlSize(.small).disabled(model.isOpeningEPUB(book))
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
        .background(ReadingPalette.paper, ignoresSafeAreaEdges: .vertical)
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
        let title: (LibraryShelf) -> String = { item in
            switch item {
            case .reading: return "Reading · \(model.librarySummary.readingCount)"
            case .finished: return "Finished · \(model.librarySummary.finishedCount)"
            case .all: return "All books · \(books.count)"
            }
        }
        return Menu {
            Picker("Bookshelf", selection: $browsing.shelf) {
                ForEach([LibraryShelf.all, .reading, .finished], id: \.self) { item in
                    Text(title(item)).tag(item)
                }
            }
        } label: {
            Text(title(browsing.shelf)).lineLimit(1)
        }
        .menuStyle(ReadingMenuStyle())
        .accessibilityLabel("Bookshelf").accessibilityValue(title(browsing.shelf))
    }

    fileprivate var searchAndSort: some View {
        HStack(spacing: 10) {
            ReadingSearchField(label: "Search library", placeholder: "Find a title or author", text: $browsing.search)
                .frame(minWidth: 180, maxWidth: 260)
            Menu {
                ForEach(LibrarySort.allCases, id: \.self) { value in
                    Button { browsing.sort = value } label: {
                        if browsing.sort == value {
                            Label(value.rawValue, systemImage: "checkmark")
                        } else {
                            Text(value.rawValue)
                        }
                    }
                    .accessibilityAddTraits(browsing.sort == value ? .isSelected : [])
                }
            } label: { Label(browsing.sort.rawValue, systemImage: "arrow.up.arrow.down") }
            .menuStyle(ReadingMenuStyle())
            .accessibilityLabel("Sort books")
            .accessibilityValue(browsing.sort.rawValue)
        }
    }
}

enum LibraryShelf: Hashable { case reading, finished, all }
enum LibrarySort: String, CaseIterable { case recent = "Recent", title = "Title", author = "Author" }

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
                        .lineLimit(2, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
                    Text(book.author?.isEmpty == false ? book.author! : "Author unavailable")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(progressLabel.primary)
                            .font(.callout.weight(.semibold)).foregroundStyle(ReadingPalette.accent)
                            .lineLimit(1)
                        if let rating {
                            Label(rating.formatted(.number.precision(.fractionLength(0...2))), systemImage: "star.fill")
                                .font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.accent)
                        }
                    }.padding(.top, 2)
                    Text(progressLabel.detail ?? " ").font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                        .lineLimit(2, reservesSpace: true)
                        .accessibilityHidden(progressLabel.detail == nil)
                    let showsDate = date != nil || progress == nil || finished
                    Text(showsDate ? (date.map { "\(finished ? "Finished" : "Last read") \($0.formatted(date: .abbreviated, time: .omitted))" } ?? (finished ? "Date unavailable" : "No reading recorded yet")) : " ")
                        .font(.caption2).foregroundStyle(ReadingPalette.secondaryInk).lineLimit(1)
                        .accessibilityHidden(!showsDate)
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
