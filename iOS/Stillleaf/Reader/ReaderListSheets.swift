import SwiftUI

/// Contents, bookmarks and highlights. Rows come from the renderer; choosing one sends its id back.
struct ReaderContentsSheet: View {
    @ObservedObject var chrome: ReaderChrome
    @State private var tab: ReaderChrome.ListTab = .outline

    var body: some View {
        let list = chrome.lists[tab] ?? ReaderList(loading: true)
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(list.rows) { row in
                        Button { chrome.go(row) } label: { label(for: row) }
                            .disabled(!row.openable)
                            .swipeActions {
                                if row.kind != .outline {
                                    Button("Delete", role: .destructive) { chrome.remove(row) }
                                }
                            }
                            .id(row.id)
                    }
                }
                .listStyle(.plain)
                .onChange(of: list.rows.first(where: { $0.current })?.id) { _, current in
                    if let current { proxy.scrollTo(current, anchor: .center) }
                }
            }
            .overlay {
                if list.rows.isEmpty {
                    if list.loading {
                        ProgressView()
                    } else {
                        ContentUnavailableView(emptyTitle, systemImage: emptySymbol, description: Text(list.empty))
                    }
                }
            }
            .navigationTitle(tab.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("List", selection: $tab) {
                        ForEach(ReaderChrome.ListTab.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 330)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { chrome.sheet = nil } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { chrome.load(tab) }
        .onChange(of: tab) { _, value in chrome.load(value) }
    }

    private var emptyTitle: String {
        switch tab {
        case .outline: return "No Contents"
        case .bookmarks: return "No Bookmarks"
        case .notes: return "No Highlights"
        }
    }

    private var emptySymbol: String {
        switch tab {
        case .outline: return "list.bullet"
        case .bookmarks: return "bookmark"
        case .notes: return "highlighter"
        }
    }

    @ViewBuilder
    private func label(for row: ReaderRow) -> some View {
        switch row.kind {
        case .outline:
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.title)
                    .font(row.depth == 0 ? .body : .subheadline)
                    .fontWeight(row.current ? .semibold : .regular)
                    .foregroundStyle(row.current ? Color.accentColor : row.openable ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text(row.detail).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.leading, CGFloat(min(row.depth, 4)) * 18)
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(row.current ? .isSelected : [])
        case .bookmark:
            HStack(spacing: 12) {
                Image(systemName: "bookmark.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(.vertical, 2)
        case .note, .result:
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(hex: row.colour) ?? Color.accentColor)
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.quote)
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(.primary)
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                    if !row.note.isEmpty {
                        Text(row.note).font(.subheadline).foregroundStyle(.secondary).lineLimit(4).multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// Search inside the open book, entirely on the device.
struct ReaderSearchSheet: View {
    @ObservedObject var chrome: ReaderChrome
    @State private var query = ""

    var body: some View {
        let results = chrome.search
        NavigationStack {
            List {
                if !results.rows.isEmpty {
                    Section(results.status) {
                        ForEach(results.rows) { row in
                            Button { chrome.go(row) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(Text(row.before))\(Text(row.match).bold().foregroundColor(.accentColor))\(Text(row.after))")
                                        .font(.system(.callout, design: .serif))
                                        .foregroundStyle(.primary)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                    if !row.chapter.isEmpty { Text(row.chapter).font(.caption).foregroundStyle(.secondary) }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if results.rows.isEmpty {
                    if results.loading {
                        ProgressView()
                    } else if query.trimmingCharacters(in: .whitespaces).count < 2 {
                        ContentUnavailableView("Search This Book", systemImage: "magnifyingglass",
                                               description: Text("Find a word or phrase anywhere in the book. Nothing leaves this device."))
                    } else {
                        ContentUnavailableView("No Results", systemImage: "magnifyingglass",
                                               description: Text(results.status.isEmpty ? "Nothing in this book matches." : results.status))
                    }
                }
            }
            .navigationTitle("Search Book")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Words or phrase")
            .onSubmit(of: .search) { chrome.find(query) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { chrome.sheet = nil } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // Search as the reader types, once they pause.
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { chrome.find(query) }
        }
    }
}
