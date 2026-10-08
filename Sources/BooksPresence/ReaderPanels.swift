import AppKit
import SwiftUI

// The native Contents, Bookmarks, Notes and Search panels. The renderer sends rows and takes ids back;
// this file holds what the panels show, and `NativeReaderChrome` does the talking.

@MainActor final class ReaderPanelsModel: ObservableObject {
    enum Tab: String, CaseIterable {
        case contents, bookmarks, notes
        var title: String { switch self { case .contents: return "Contents"; case .bookmarks: return "Bookmarks"; case .notes: return "Notes" } }
        /// The name the renderer's `panel` command uses.
        var wireName: String { switch self { case .contents: return "outline"; case .bookmarks: return "bookmarks"; case .notes: return "notes" } }
    }

    /// What one list shows. `revision` changes only when the rows are replaced.
    struct Page {
        var rows: [ReaderRow] = []
        var empty = ""
        var status = ""
        var loading = true
        var revision = 0
    }

    @Published var tab: Tab = .contents
    @Published private(set) var pages: [Tab: Page] = Dictionary(uniqueKeysWithValues: Tab.allCases.map { ($0, Page()) })
    @Published private(set) var results = Page(loading: false)
    @Published var query = "" { didSet { if query != oldValue { queryChanged?(query) } } }
    @Published var error: String?
    /// Bumped to move keyboard focus from the search field to the results.
    @Published private(set) var focusToken = 0

    var load: ((Tab) -> Void)?
    var queryChanged: ((String) -> Void)?
    var open: ((ReaderRow) -> Void)?
    var remove: ((ReaderRow) -> Void)?
    var edit: ((ReaderRow) -> Void)?

    func page(_ tab: Tab) -> Page { pages[tab] ?? Page() }

    func select(_ tab: Tab) {
        guard tab != self.tab else { return }
        self.tab = tab; error = nil
        load?(tab)
    }

    func markLoading(_ tab: Tab) { pages[tab]?.loading = page(tab).rows.isEmpty }
    func fail(_ tab: Tab) {
        pages[tab]?.loading = false
        pages[tab]?.empty = "This could not be loaded. Close the panel and try again."
    }
    func focusResults() { focusToken += 1 }
    func openFirstResult() { if let first = results.rows.first { open?(first) } }

    func resetSearch() {
        query = ""
        results = Page(status: "Search within this book, entirely offline.", loading: false, revision: results.revision + 1)
        error = nil
    }

    func searching() { results.status = "Searching…" }
    func searchPrompt(_ text: String) { results = Page(status: text, loading: false, revision: results.revision + 1) }

    /// Applies a `panel` payload from the renderer. A search that was overtaken is ignored.
    func apply(_ panel: [String: Any]?) {
        guard let panel, let name = panel["name"] as? String else { return }
        let rows = panel["rows"] as? [[String: Any]] ?? []
        let empty = panel["empty"] as? String ?? ""
        func page(_ parsed: [ReaderRow], _ previous: Page) -> Page {
            Page(rows: parsed, empty: empty, status: panel["status"] as? String ?? "", loading: false, revision: previous.revision + 1)
        }
        switch name {
        case "outline": pages[.contents] = page(ReaderRow.outline(rows), self.page(.contents))
        case "bookmarks": pages[.bookmarks] = page(ReaderRow.bookmarks(rows), self.page(.bookmarks))
        case "notes": pages[.notes] = page(ReaderRow.notes(rows), self.page(.notes))
        case "search":
            if panel["stale"] as? Bool == true { return }
            results = page(ReaderRow.results(rows), results)
        default: break
        }
    }
}

extension ReaderPanelsModel.Page {
    init(status: String, loading: Bool, revision: Int) { self.init(rows: [], empty: "", status: status, loading: loading, revision: revision) }
    init(loading: Bool) { self.init(rows: [], empty: "", status: "Search within this book, entirely offline.", loading: loading, revision: 0) }
}

/// Contents, Bookmarks and Notes: one panel with a segmented control, like the web panel.
struct ReaderLibraryPanelView: View {
    @ObservedObject var chrome: ReaderChromeModel
    @ObservedObject var panels: ReaderPanelsModel
    let close: () -> Void

    var body: some View {
        let palette = chrome.panelPalette
        let page = panels.page(panels.tab)
        ReaderPanelFrame(title: panels.tab == .notes ? "Highlights and notes" : "Your place in the book", close: close, scrolls: false) {
            VStack(alignment: .leading, spacing: 8) {
                ReaderSegmented(label: "Book navigation", options: ReaderPanelsModel.Tab.allCases.map { ($0.rawValue, $0.title) }, selection: panels.tab.rawValue) {
                    if let tab = ReaderPanelsModel.Tab(rawValue: $0) { panels.select(tab) }
                }
                .padding(.horizontal, 16)
                ZStack(alignment: .topLeading) {
                    if page.rows.isEmpty {
                        Text(page.loading ? "Loading…" : page.empty)
                            .font(.system(size: 13)).foregroundStyle(palette.secondary)
                            .padding(.horizontal, 22).padding(.top, 14)
                    } else {
                        ReaderRowList(rows: page.rows, revision: page.revision, palette: palette, accessibilityTitle: panels.tab.title, width: 380,
                                      open: { panels.open?($0) },
                                      remove: panels.tab == .contents ? nil : { panels.remove?($0) },
                                      edit: panels.tab == .notes ? { panels.edit?($0) } : nil)
                            .id(panels.tab)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let error = panels.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 10)
                }
            }
        }
        .environment(\.readerPalette, palette)
        .background(tabShortcuts)
        .readingMotionAccessibility()
    }

    /// ⌘1, ⌘2 and ⌘3 switch tabs.
    private var tabShortcuts: some View {
        HStack {
            ForEach(Array(ReaderPanelsModel.Tab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.title) { panels.select(tab) }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// Search this book: the system search field over a list of passages.
struct ReaderSearchPanelView: View {
    @ObservedObject var chrome: ReaderChromeModel
    @ObservedObject var panels: ReaderPanelsModel
    let close: () -> Void

    var body: some View {
        let palette = chrome.panelPalette
        ReaderPanelFrame(title: "Search this book", close: close, scrolls: false) {
            VStack(alignment: .leading, spacing: 8) {
                ReaderSearchField(text: $panels.query, placeholder: "Words or phrase", onSubmit: { panels.openFirstResult() },
                                  onMoveDown: { panels.focusResults() }, onCancel: close)
                    .frame(height: 28).padding(.horizontal, 16)
                Text(panels.results.status).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    .padding(.horizontal, 20).accessibilityLabel("Search status: \(panels.results.status)")
                if !panels.results.rows.isEmpty {
                    ReaderRowList(rows: panels.results.rows, revision: panels.results.revision, palette: palette, accessibilityTitle: "Search results", width: 380,
                                  focusOnLoad: false, focusToken: panels.focusToken, open: { panels.open?($0) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
                if let error = panels.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 10)
                }
            }
        }
        .environment(\.readerPalette, palette)
        .readingMotionAccessibility()
    }
}
