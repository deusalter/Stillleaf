import SwiftUI

/// Where the app is: the selected tab, the open book and the one sheet or picker in front.
/// Views ask the router instead of each presenting their own copies of the same sheets.
@MainActor
final class AppRouter: ObservableObject {
    enum Tab: Hashable { case reading, library, journal }

    enum Sheet: Identifiable, Equatable {
        case settings, logReading
        /// The offer to mark a book finished, made after the reader closes on its last pages.
        case finish(String)

        var id: String {
            switch self {
            case .settings: return "settings"
            case .logReading: return "logReading"
            case .finish(let book): return "finish:" + book
            }
        }
    }

    enum JournalMode: String, CaseIterable, Identifiable {
        case calendar = "Calendar", finished = "Finished", reviews = "Reviews"
        var id: String { rawValue }
    }

    @Published var tab: Tab
    /// Which part of the Journal tab is showing.
    @Published var journalMode: JournalMode = .calendar
    /// The edition open in the full-screen reader.
    @Published var reading: Edition?
    @Published var sheet: Sheet?
    /// The system file picker for EPUBs.
    @Published var importing = false

    init(tab: Tab = .reading) { self.tab = tab }

    func open(_ edition: Edition) { reading = edition }
}

extension View {
    /// A tab's root screen, with its title and the add and settings buttons.
    func tabScreen(_ title: String) -> some View { modifier(TabScreen(title: title)) }
}

/// On a phone the title is set large on the same row as the buttons, as in Books: the standard large title sits on a
/// row of its own below them, which leaves an empty band at the top. On an iPad the buttons share the tab bar's row,
/// where an inline title has no room and is dropped, so the standard large title stays.
private struct TabScreen: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .toolbarTitleDisplayMode(sizeClass == .compact ? .inlineLarge : .automatic)
            .toolbar { AppToolbar() }
    }
}

/// The two actions every tab offers: add something, and settings.
struct AppToolbar: ToolbarContent {
    @EnvironmentObject private var router: AppRouter

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button { router.importing = true } label: { Label("Import EPUBs…", systemImage: "square.and.arrow.down") }
                Button { router.sheet = .logReading } label: { Label("Log Reading…", systemImage: "pencil.and.list.clipboard") }
            } label: {
                Label("Add", systemImage: "plus")
            }
            Button { router.sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
        }
    }
}
