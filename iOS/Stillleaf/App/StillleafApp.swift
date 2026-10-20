import SwiftUI

@main
struct StillleafApp: App {
    @StateObject private var launch = AppLaunch()

    var body: some Scene {
        WindowGroup {
            if let journal = launch.journal {
                RootView().environmentObject(journal)
            } else if let failure = launch.failure {
                ContentUnavailableView("Stillleaf can't open your journal", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            }
        }
    }
}

/// Opens the journal once. Under XCTest the app stays empty: tests build their own journals.
@MainActor
final class AppLaunch: ObservableObject {
    let journal: Journal?
    let failure: String?

    init() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            journal = nil; failure = nil
            return
        }
        do { journal = try Journal.live(); failure = nil }
        catch { journal = nil; failure = error.localizedDescription }
    }
}
