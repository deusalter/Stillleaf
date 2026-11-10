import SwiftUI

/// The full-screen reader: the page, the controls a tap in the middle of it shows, and their sheets.
struct ReaderScreen: View {
    let edition: Edition
    let journal: Journal
    let onClose: () -> Void
    @StateObject private var chrome = ReaderChrome()

    var body: some View {
        ReaderPage(edition: edition, journal: journal, chrome: chrome, onClose: onClose)
            .ignoresSafeArea()
            .overlay { ReaderControls(chrome: chrome, title: edition.publication.title) }
            .sheet(item: $chrome.sheet) { sheet in
                Group {
                    switch sheet {
                    case .contents: ReaderContentsSheet(chrome: chrome)
                    case .search: ReaderSearchSheet(chrome: chrome)
                    case .appearance: ReaderAppearanceSheet(chrome: chrome)
                    }
                }
                // Sheets over a dark page are dark, whatever the system setting.
                .preferredColorScheme(chrome.pageIsDark ? .dark : .light)
            }
            .alert("Reader", isPresented: Binding(get: { chrome.error != nil }, set: { if !$0 { chrome.error = nil } }),
                   presenting: chrome.error) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }
}
