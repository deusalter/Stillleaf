import Foundation

// The sync scenario from Tests/BooksPlatformTests/FolderSyncScenario.swift, run without XCTest.
// scripts/check-local.sh compiles the two files together.

@main
enum SyncSmoke {
    static func main() throws {
        var failures: [String] = []
        try runFolderSyncScenario { failures.append($0); print("FAIL: " + $0) }
        guard failures.isEmpty else { print("sync-smoke: \(failures.count) failed"); exit(1) }
        print("sync-smoke: two devices exchange books, history, place, bookmarks and highlights; overlaps, deletions, declined books and idle passes behave")
    }
}
