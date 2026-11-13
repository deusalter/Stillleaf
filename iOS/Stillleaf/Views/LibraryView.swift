import SwiftUI
import BooksCore

/// Every book in the journal as a shelf of covers. A book on this device opens on a tap.
struct LibraryView: View {
    enum Shelf: String, CaseIterable, Identifiable {
        case all = "All", reading = "Reading", finished = "Finished"
        var id: String { rawValue }
    }

    @EnvironmentObject private var journal: Journal
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var path: [String] = []
    @State private var query = ""
    @State private var shelf: Shelf = .all
    @State private var deleting: BookRecord?

    private var books: [BookRecord] {
        let summary = journal.history.librarySummary
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.books.filter { book in
            switch shelf {
            case .all: break
            case .reading: guard !summary.finishedIDs.contains(book.id) else { return false }
            case .finished: guard summary.finishedIDs.contains(book.id) else { return false }
            }
            return text.isEmpty || book.title.localizedCaseInsensitiveContains(text) || (book.author?.localizedCaseInsensitiveContains(text) ?? false)
        }.sorted { lhs, rhs in
            let left = summary.recent[lhs.id] ?? lhs.observedAt, right = summary.recent[rhs.id] ?? rhs.observedAt
            return left == right ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending : left > right
        }
    }

    var body: some View {
        let books = self.books
        let empty = journal.history.librarySummary.books.isEmpty
        NavigationStack(path: $path) {
            ScrollView {
                if !empty {
                    Picker("Shelf", selection: $shelf) {
                        ForEach(Shelf.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 140 : 100, maximum: 190), spacing: 20, alignment: .top)], spacing: 26) {
                    ForEach(books) { book in
                        Button { select(book) } label: { BookCard(book: book) }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: book) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .overlay {
                if books.isEmpty {
                    if empty {
                        ContentUnavailableView {
                            Label("No Books Yet", systemImage: "books.vertical")
                        } description: {
                            Text("Import DRM-free EPUBs from Files. You can also share an EPUB to Stillleaf from Mail, Safari or AirDrop.")
                        } actions: {
                            Button("Import EPUBs") { router.importing = true }.buttonStyle(.borderedProminent)
                        }
                    } else if query.isEmpty {
                        ContentUnavailableView(shelf == .finished ? "Nothing Finished Yet" : "Nothing in Progress", systemImage: "book.closed",
                                               description: Text(shelf == .finished ? "Mark a book as finished and it appears here." : "Every book here is finished."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $query, prompt: "Title or author")
            .toolbar { AppToolbar() }
            .navigationDestination(for: String.self) { id in BookDetailView(bookID: id) }
            .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { book in
                Button("Delete Book and History", role: .destructive) { journal.deleteBook(book.id) }
            } message: { _ in
                Text("Its reading time, pages, review and imported EPUB are removed from this device. Exports you saved elsewhere are not affected.")
            }
        }
    }

    private func select(_ book: BookRecord) {
        if let edition = journal.edition(forBook: book.id) { router.open(edition) } else { path.append(book.id) }
    }

    @ViewBuilder
    private func menu(for book: BookRecord) -> some View {
        if let edition = journal.edition(forBook: book.id) {
            Button { router.open(edition) } label: { Label("Read", systemImage: "book") }
        }
        Button { path.append(book.id) } label: { Label("Details", systemImage: "info.circle") }
        if journal.finished(bookID: book.id) == nil {
            Button { journal.markFinished(book.id) } label: { Label("Mark as Finished", systemImage: "checkmark.circle") }
        }
        Button(role: .destructive) { deleting = book } label: { Label("Delete…", systemImage: "trash") }
    }
}

/// A cover with its title and where the reader is in it.
struct BookCard: View {
    @EnvironmentObject private var journal: Journal
    @Environment(\.colorScheme) private var scheme
    let book: BookRecord

    var body: some View {
        let edition = journal.edition(forBook: book.id)
        let finished = journal.finished(bookID: book.id) != nil
        let fraction = journal.position(bookID: book.id)?.fraction
        VStack(alignment: .leading, spacing: 7) {
            BookCover(book: book, coverURL: edition?.coverURL)
                .overlay(alignment: .topTrailing) {
                    if finished {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.onAccent(scheme), Color.accentColor)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .padding(6)
                    }
                }
            // Every card keeps the bar's place, so titles in a row share a line.
            ProgressView(value: min(1, max(0, fraction ?? 0))).scaleEffect(x: 1, y: 0.7, anchor: .center)
                .opacity(fraction != nil && !finished ? 1 : 0)
                .accessibilityHidden(true)
            Text(book.title).font(.system(.subheadline, design: .serif).weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
            Text(status(finished: finished, fraction: fraction, onDevice: edition != nil))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(edition == nil ? "Shows details" : "Opens the book")
    }

    private func status(finished: Bool, fraction: Double?, onDevice: Bool) -> String {
        if finished { return "Finished" }
        if let fraction { return ReadingText.percent(fraction) + " read" }
        if !onDevice { return book.source == "stillleaf-epub" ? "Not on this device" : (book.author ?? "Journal only") }
        return book.author ?? "Not started"
    }
}
