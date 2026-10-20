import SwiftUI
import UniformTypeIdentifiers
import BooksCore

struct LibraryView: View {
    enum Shelf: String, CaseIterable, Identifiable {
        case all = "All", reading = "Reading", finished = "Finished"
        var id: String { rawValue }
    }

    @EnvironmentObject private var journal: Journal
    @Environment(\.openBook) private var open
    @State private var path: [String] = []
    @State private var query = ""
    @State private var shelf: Shelf = .all
    @State private var importing = false
    @State private var logging = false
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
        NavigationStack(path: $path) {
            ScrollView {
                Picker("Shelf", selection: $shelf) {
                    ForEach(Shelf.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 18, alignment: .top)], spacing: 22) {
                    ForEach(books) { book in
                        Button { select(book) } label: { BookCard(book: book) }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: book) }
                    }
                }
                .padding()
            }
            .overlay {
                if books.isEmpty {
                    if journal.history.librarySummary.books.isEmpty {
                        ContentUnavailableView {
                            Label("No books yet", systemImage: "books.vertical")
                        } description: {
                            Text("Import DRM-free EPUBs from Files. You can also share an EPUB to Stillleaf from Mail, Safari or AirDrop.")
                        } actions: {
                            Button("Import EPUBs") { importing = true }.buttonStyle(.borderedProminent)
                        }
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let status = journal.importStatus {
                    Label(status, systemImage: "arrow.down.doc")
                        .font(.footnote)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("Library")
            .searchable(text: $query, prompt: "Title or author")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { logging = true } label: { Label("Log Reading", systemImage: "plus") }
                    Button { importing = true } label: { Label("Import EPUBs", systemImage: "square.and.arrow.down") }
                }
            }
            .navigationDestination(for: String.self) { id in BookDetailView(bookID: id) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.epub], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await journal.importEPUBs(urls) }
                case .failure(let error): journal.notice = JournalNotice(title: "Import", message: error.localizedDescription)
                }
            }
            .sheet(isPresented: $logging) { LogReadingView() }
            .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { book in
                Button("Delete Book and History", role: .destructive) { journal.deleteBook(book.id) }
            } message: { _ in
                Text("Its reading time, pages, review and imported EPUB are removed from this device. Exports you saved elsewhere are not affected.")
            }
        }
    }

    private func select(_ book: BookRecord) {
        if let edition = journal.edition(forBook: book.id) { open(edition) } else { path.append(book.id) }
    }

    @ViewBuilder
    private func menu(for book: BookRecord) -> some View {
        if let edition = journal.edition(forBook: book.id) {
            Button { open(edition) } label: { Label("Read", systemImage: "book") }
        }
        Button { path.append(book.id) } label: { Label("Details", systemImage: "info.circle") }
        if journal.finished(bookID: book.id) == nil {
            Button { journal.markFinished(book.id) } label: { Label("Mark as Finished", systemImage: "checkmark.circle") }
        }
        Button(role: .destructive) { deleting = book } label: { Label("Delete…", systemImage: "trash") }
    }
}

struct BookCard: View {
    @EnvironmentObject private var journal: Journal
    let book: BookRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BookCover(book: book, coverURL: journal.edition(forBook: book.id)?.coverURL)
            Text(book.title).font(.system(.subheadline, design: .serif).weight(.medium)).lineLimit(2)
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(journal.edition(forBook: book.id) == nil ? "Shows details" : "Opens the book")
    }

    private var status: String {
        if journal.finished(bookID: book.id) != nil { return "Finished" }
        if let fraction = journal.position(bookID: book.id)?.fraction { return "\(Int((fraction * 100).rounded()))% read" }
        if journal.edition(forBook: book.id) == nil {
            return book.source == "stillleaf-epub" ? "EPUB not on this device" : (book.author ?? "Journal only")
        }
        return book.author ?? "Not started"
    }
}
