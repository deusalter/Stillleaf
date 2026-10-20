import XCTest
@testable import Stillleaf

/// A clock tests advance by hand, standing in for wall time and monotonic uptime.
final class ManualClock {
    var date = Date(timeIntervalSince1970: 1_790_000_000)
    var uptime: TimeInterval = 10_000
    func advance(_ seconds: TimeInterval) { date += seconds; uptime += seconds }
    var reading: Journal.Clock { { (self.date, self.uptime) } }
}

/// A private temporary folder per test; never the app's own journal.
final class Scratch {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillleaf-tests-" + UUID().uuidString, isDirectory: true)
    let defaults: UserDefaults
    private let suite = "stillleaf-tests-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
    }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    @MainActor
    func journal(_ name: String = "journal", clock: ManualClock? = nil) throws -> Journal {
        try Journal(paths: JournalPaths(root: url(name)), defaults: defaults, usesTimer: false,
                    clock: clock?.reading ?? { (Date(), ProcessInfo.processInfo.systemUptime) })
    }

    func epub(_ name: String = "garden.epub", entries: [SyntheticEPUB.Entry] = SyntheticEPUB.book()) throws -> URL {
        try SyntheticEPUB.write(entries, to: url(name))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

extension XCTestCase {
    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    @MainActor
    func waitUntil(_ description: String, timeout: TimeInterval, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw TimeoutError(description: "Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

struct TimeoutError: Error, CustomStringConvertible {
    let description: String
}
