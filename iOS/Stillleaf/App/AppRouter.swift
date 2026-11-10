import SwiftUI

/// Where the app is: the selected tab, the open book and the one sheet or picker in front.
/// Views ask the router instead of each presenting their own copies of the same sheets.
@MainActor
final class AppRouter: ObservableObject {
    enum Tab: Hashable { case reading, library, journal }

    enum Sheet: String, Identifiable {
        case settings, logReading
        var id: String { rawValue }
    }

    @Published var tab: Tab
    /// The edition open in the full-screen reader.
    @Published var reading: Edition?
    @Published var sheet: Sheet?
    /// The system file picker for EPUBs.
    @Published var importing = false

    init(tab: Tab = .reading) { self.tab = tab }

    func open(_ edition: Edition) { reading = edition }
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
