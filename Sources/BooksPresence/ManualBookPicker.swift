import SwiftUI
import BooksCore
import BooksPlatform

/// Which book an entry is for.
enum ManualBookChoice: Equatable {
    case library(BookRecord)
    case outside(OutsideBook)
    /// A title typed by hand, for a book that has no catalogue entry.
    case typed(String)
}

/// One search box for everything: the user's library first, then the web, then "just use this title".
struct ManualBookPicker: View {
    let kind: ManualEntryKind
    let library: [BookRecord]
    @Binding var query: String
    @Binding var choice: ManualBookChoice?
    @Binding var typedAuthor: String
    @ObservedObject var search: BookSearchController
    let service: BookSearchService

    private var formats: Set<BookFormat> { kind == .book ? [.text] : [.audiobook] }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var libraryRows: [BookRecord] {
        if trimmed.isEmpty {
            return Array(library.filter { formats.contains($0.resolvedFormat) }
                .sorted { $0.observedAt > $1.observedAt }.prefix(4))
        }
        return LibraryBookMatcher.matches(query: trimmed, in: library, formats: formats, limit: 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .book ? "Book" : "Audiobook").font(.headline)
            if let choice { selected(choice) } else { searching }
        }
        .readingPanel()
        .onChange(of: query) { value in if kind == .book && choice == nil { search.update(query: value) } }
        .onChange(of: kind) { _ in search.cancel() }
    }

    // MARK: Searching

    private var searching: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReadingSearchField(label: "Search for a book",
                               placeholder: kind == .book ? "Search your library or the web" : "Search your audiobooks",
                               text: $query)
            if !libraryRows.isEmpty {
                sectionLabel(trimmed.isEmpty ? "Recently in your library" : "In your library")
                ForEach(libraryRows) { book in
                    ResultRow(action: { choice = .library(book) }, cover: { BookCoverView(book: book, size: .mini) },
                              title: book.title, detail: book.author, accessory: nil)
                }
            }
            if kind == .book && trimmed.count >= 2 { outsideSection }
            if !trimmed.isEmpty {
                ResultRow(action: { choice = .typed(trimmed) }, cover: { ManualCoverPlaceholder() },
                          title: "Use “\(trimmed)” as a new \(kind == .book ? "book" : "audiobook")",
                          detail: "Add it by title and author", accessory: "plus")
            }
            if kind == .book {
                Label("Web results come from Open Library. Only the words you type are sent, nothing from your library.",
                      systemImage: "lock")
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var outsideSection: some View {
        switch search.phase {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching Open Library…").font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            }.padding(.vertical, 4)
        case let .results(found):
            let known = Set(library.map(\.id))
            let rows = found.filter { !known.contains($0.libraryID) }
            if !rows.isEmpty {
                sectionLabel("Not in your library")
                ForEach(rows) { book in
                    ResultRow(action: { choice = .outside(book) },
                              cover: { RemoteCover(book: book, service: service) },
                              title: book.title, detail: Self.detail(book), accessory: "plus.circle")
                }
            } else if libraryRows.isEmpty {
                Text("No matches online. You can still add it by title.")
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            }
        case let .failed(failure):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: failure == .offline ? "wifi.slash" : "exclamationmark.triangle")
                    .foregroundStyle(ReadingPalette.warning).accessibilityHidden(true)
                Text(Self.message(failure)).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Try again") { search.retry() }.controlSize(.small)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(ReadingType.sectionLabel).tracking(0.6)
            .foregroundStyle(ReadingPalette.secondaryInk).padding(.top, 2)
    }

    static func message(_ failure: BookSearchController.Failure) -> String {
        switch failure {
        case .offline: return "Can't reach Open Library. You seem to be offline, but you can still add the book by title."
        case .timedOut: return "Open Library took too long to answer. Try again, or add the book by title."
        case .unavailable: return "Open Library isn't responding right now. Try again, or add the book by title."
        }
    }

    static func detail(_ book: OutsideBook) -> String? {
        let parts = [book.author, book.firstPublishYear.map(String.init),
                     book.pageCount.map { "\($0.formatted()) pages" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Chosen

    @ViewBuilder private func selected(_ choice: ManualBookChoice) -> some View {
        HStack(alignment: .center, spacing: 12) {
            switch choice {
            case let .library(book): BookCoverView(book: book, size: .mini)
            case let .outside(book): RemoteCover(book: book, service: service)
            case .typed: ManualCoverPlaceholder()
            }
            VStack(alignment: .leading, spacing: 3) {
                switch choice {
                case let .library(book):
                    Text(book.title).font(ReadingType.bookTitle(17)).lineLimit(2)
                    if let author = book.author { Text(author).font(.callout).foregroundStyle(ReadingPalette.secondaryInk) }
                case let .outside(book):
                    Text(book.title).font(ReadingType.bookTitle(17)).lineLimit(2)
                    if let detail = Self.detail(book) { Text(detail).font(.callout).foregroundStyle(ReadingPalette.secondaryInk) }
                case .typed:
                    Text("New book").font(.caption.weight(.semibold)).foregroundStyle(ReadingPalette.secondaryInk)
                }
            }
            Spacer(minLength: 8)
            Button("Change") { change(choice) }.controlSize(.small)
        }
        if case let .typed(title) = choice {
            TextField("Title", text: Binding(get: { title }, set: { self.choice = .typed($0) }))
            TextField("Author (optional)", text: $typedAuthor)
        }
        if case .outside = choice {
            Label("Added to your library as a physical book you track by hand.", systemImage: "books.vertical")
                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
        }
    }

    private func change(_ choice: ManualBookChoice) {
        if case let .typed(title) = choice { query = title }
        self.choice = nil
        if kind == .book { search.update(query: query) }
    }
}

private struct ResultRow<Cover: View>: View {
    let action: () -> Void
    @ViewBuilder let cover: Cover
    let title: String
    let detail: String?
    let accessory: String?
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                cover
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(ReadingPalette.ink).lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(ReadingPalette.secondaryInk).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let accessory {
                    Image(systemName: accessory).foregroundStyle(ReadingPalette.accent).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ReadingPalette.accent.opacity(hovering ? 0.10 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

/// A result's cover, fetched through the search service and remembered for the session.
struct RemoteCover: View {
    let book: OutsideBook
    let service: BookSearchService
    @State private var image: NSImage?
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { ManualCoverPlaceholder() }
        }
        .frame(width: 38, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(ReadingPalette.ink.opacity(0.13)))
        .task(id: book.key) {
            if let cached = Self.cache.object(forKey: book.key as NSString) { image = cached; return }
            guard book.coverURL != nil, let data = try? await service.coverData(for: book),
                  let loaded = NSImage(data: data), !Task.isCancelled else { return }
            Self.cache.setObject(loaded, forKey: book.key as NSString)
            image = loaded
        }
        .accessibilityHidden(true)
    }
}

/// The library's own cached placeholder, at the picker's thumbnail size.
struct ManualCoverPlaceholder: View {
    static let size = CGSize(width: 38, height: 54)
    var body: some View {
        Image(nsImage: CoverPlaceholder.image(size: Self.size)).resizable()
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}
