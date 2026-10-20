import AppKit
import Combine
import SwiftUI
import BooksCore
import BooksPlatform
import CSQLite
import Darwin

/// `--measure-idle <seconds>` runs the real menu-bar tracker (an `AppModel` with tracking on)
/// and prints what it costs per minute: CPU time, retired instructions and wakeups, the numbers
/// Activity Monitor's energy columns are built from. Instructions are the steadiest of the three,
/// so compare those first. No window is shown.
///
/// Scenarios (`STILLLEAF_IDLE_SCENARIOS`, default `menu,manual`):
/// - `menu`: nothing is being read; Stillleaf sits in the menu bar.
/// - `manual`: a manual reading session is running, the cheapest form of "reading".
///
/// Every scenario uses a disposable support folder seeded at a heavy reader's scale (70 books,
/// 6,000 intervals, 11,000 events) and a synthetic Apple Books catalog, so the 30-second
/// finished-books sync is included without reading the user's Books library or history. The menu
/// panel's view is built and kept hidden, as the app does at launch, since hidden SwiftUI views
/// still update when the model publishes.
@MainActor
func measureIdleCPU(seconds: Double) throws {
    let names = (ProcessInfo.processInfo.environment["STILLLEAF_IDLE_SCENARIOS"] ?? "menu,manual")
        .split(separator: ",").map(String.init)
    print("idle-cpu: \(names.joined(separator: ",")) for \(Int(seconds)) s each; per-minute figures")
    for name in names {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-idle-\(UUID().uuidString)")
        let suite = "Stillleaf.Idle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set("America/Los_Angeles", forKey: "timezoneID")
        defaults.set(true, forKey: "didConfigureLogin")
        let (model, panel) = try makeProbeApp(root: root, defaults: defaults)
        var publishes = 0
        let counter = model.objectWillChange.sink { _ in publishes += 1 }
        switch name {
        case "menu": break
        case "manual": model.startManual(title: "Synthetic manual book", author: "")
        default: throw ReadingStoreError.invalidData("unknown idle scenario \(name)")
        }
        // Launch work (first refresh, first catalog sync) settles before the window opens.
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        publishes = 0
        let start = ResourceSample.now()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let used = ResourceSample.now() - start
        let published = publishes
        model.shutdown(); counter.cancel(); panel.close()
        print(used.line(name, seconds: seconds) + String(format: ", %.0f model publishes/min", Double(published) * 60 / seconds))
    }
}

/// The parts of a launch that cost something: the tracker over a heavy synthetic history and a
/// synthetic Books catalog, and the hidden menu panel built the way `AppDelegate` builds it.
@MainActor
private func makeProbeApp(root: URL, defaults: UserDefaults) throws -> (AppModel, NSPanel) {
    let support = root.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try seedIdleHistory(at: support)
    let catalog = try seedSyntheticBooksCatalog(at: root.appendingPathComponent("catalog", isDirectory: true))
    let started = ProcessInfo.processInfo.systemUptime
    let model = try AppModel(support: support, defaults: defaults, startTracking: true,
                             accessibilityStatus: { false }, booksCatalog: catalog)
    let modelReady = ProcessInfo.processInfo.systemUptime
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 430), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    let controller = NSHostingController(rootView: PopoverView(model: model, maximumHeight: 640))
    controller.sizingOptions = [.preferredContentSize]
    panel.contentViewController = controller
    controller.view.layoutSubtreeIfNeeded()
    let panelReady = ProcessInfo.processInfo.systemUptime
    ProbeLaunch.last = (modelReady - started, panelReady - modelReady)
    return (model, panel)
}

@MainActor
enum ProbeLaunch {
    static var last: (model: TimeInterval, panel: TimeInterval) = (0, 0)
}

/// `--measure-launch`: how long the tracker takes to load the heavy synthetic history, build the
/// hidden menu panel and finish its first background history refresh, and the footprint after.
/// Run it several times in fresh processes and compare medians.
@MainActor
func measureLaunch() throws {
    var process = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&name, 4, &process, &size, nil, 0)
    let begun = process.kp_proc.p_starttime
    let processStart = Date(timeIntervalSince1970: Double(begun.tv_sec) + Double(begun.tv_usec) / 1_000_000)
    let toProbe = Date().timeIntervalSince(processStart)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-launch-\(UUID().uuidString)")
    let suite = "Stillleaf.Launch.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    defaults.set("America/Los_Angeles", forKey: "timezoneID")
    defaults.set(true, forKey: "didConfigureLogin")
    let (model, panel) = try makeProbeApp(root: root, defaults: defaults)
    let refreshStarted = ProcessInfo.processInfo.systemUptime
    let deadline = Date().addingTimeInterval(10)
    while !model.historyRefreshIsIdle && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    let refreshed = ProcessInfo.processInfo.systemUptime - refreshStarted
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    model.shutdown(); panel.close()
    print(String(format: "launch: exec to main %.0f ms, tracker ready %.0f ms, menu panel %.0f ms, first background refresh %.0f ms, footprint %.1f MB",
                 toProbe * 1000, ProbeLaunch.last.model * 1000, ProbeLaunch.last.panel * 1000, refreshed * 1000,
                 Double(info.phys_footprint) / 1_048_576))
}

/// Whole-process counters from `proc_pid_rusage`, so work on background queues counts too.
struct ResourceSample {
    var cpuNanoseconds: Double
    var instructions: Double
    var interruptWakeups: Double
    var idleWakeups: Double

    /// `proc_pid_rusage` is in libSystem but not in the Swift overlay of every SDK.
    private typealias ProcPidRusage = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Int32
    private static let procPidRusage = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage")
        .map { unsafeBitCast($0, to: ProcPidRusage.self) }

    static func now() -> ResourceSample {
        var info = rusage_info_v4()
        let status = procPidRusage.map { call in withUnsafeMutablePointer(to: &info) { call(getpid(), RUSAGE_INFO_V4, $0) } } ?? -1
        guard status == 0 else { return ResourceSample(cpuNanoseconds: 0, instructions: 0, interruptWakeups: 0, idleWakeups: 0) }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        return ResourceSample(cpuNanoseconds: ticks * Double(timebase.numer) / Double(timebase.denom),
                              instructions: Double(info.ri_instructions),
                              interruptWakeups: Double(info.ri_interrupt_wkups),
                              idleWakeups: Double(info.ri_pkg_idle_wkups))
    }

    static func - (lhs: ResourceSample, rhs: ResourceSample) -> ResourceSample {
        ResourceSample(cpuNanoseconds: lhs.cpuNanoseconds - rhs.cpuNanoseconds, instructions: lhs.instructions - rhs.instructions,
                       interruptWakeups: lhs.interruptWakeups - rhs.interruptWakeups, idleWakeups: lhs.idleWakeups - rhs.idleWakeups)
    }

    func line(_ name: String, seconds: Double) -> String {
        let perMinute = 60 / seconds
        return String(format: "idle-cpu: %@ cpu %.1f ms/min (%.3f%%), %.1f M instructions/min, %.0f wakeups/min (%.0f package-idle)",
                      name, cpuNanoseconds / 1_000_000 * perMinute, cpuNanoseconds / 1e9 / seconds * 100,
                      instructions / 1_000_000 * perMinute, interruptWakeups * perMinute, idleWakeups * perMinute)
    }
}

/// Roughly the history of someone who has read with Stillleaf daily for two years.
@MainActor
private func seedIdleHistory(at support: URL) throws {
    var archive = HistoryArchive()
    archive.books = (0..<70).map { BookRecord(id: "book-\($0)", title: "Synthetic Book \($0)", author: "Author \($0 % 23)") }
    let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3600)
    for index in 0..<6000 {
        let start = end.addingTimeInterval(Double(index - 6000) * 10_800)
        let book = archive.books[index / 90 % archive.books.count]
        let session = "session-\(index / 3)"
        archive.intervals.append(ReadingInterval(sessionID: session, bookID: book.id, start: start,
            end: start.addingTimeInterval(900), duration: 900, timezoneID: "America/Los_Angeles", mode: .automatic))
        if index < 5000 {
            for turn in 0..<2 {
                archive.events.append(AuditEvent(date: start.addingTimeInterval(Double(300 + turn * 300)), kind: "pageTurn",
                    bookID: book.id, sessionID: session, detail: "Synthetic idle fixture",
                    pageTurn: PageTurnEvidence(fromPage: index + turn, toPage: index + turn + 2, pagesRead: 2, visiblePages: 1, layoutSignature: "fixture")))
            }
        }
    }
    for (index, book) in archive.books.prefix(40).enumerated() {
        let finished = end.addingTimeInterval(Double(-index) * 86_400 * 9)
        archive.events.append(AuditEvent(date: finished, kind: "bookCompleted", bookID: book.id, detail: "Synthetic completion",
            completion: BookCompletionEvidence(finishedAt: finished, source: "Fixture", imported: false)))
    }
    let fixture = support.appendingPathComponent("fixture.json")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(archive).write(to: fixture)
    try ReadingStore(url: support.appendingPathComponent("history.sqlite")).importJSON(from: fixture)
    try FileManager.default.removeItem(at: fixture)
}

/// A Books-shaped catalog with 60 finished books and no asset files.
func seedSyntheticBooksCatalog(at documents: URL) throws -> BooksCatalog {
    let folder = documents.appendingPathComponent("BKLibrary", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open(folder.appendingPathComponent("BKLibrary-1-synthetic.sqlite").path, &db) == SQLITE_OK, let db else {
        throw ReadingStoreError.sqlite("could not create the synthetic Books catalog")
    }
    defer { sqlite3_close(db) }
    var sql = "CREATE TABLE ZBKLIBRARYASSET (ZASSETID TEXT, ZTITLE TEXT, ZAUTHOR TEXT, ZISFINISHED INTEGER, ZDATEFINISHED REAL, ZPATH TEXT, ZSTOREID TEXT);"
    let finished = Date().addingTimeInterval(-86_400 * 30).timeIntervalSinceReferenceDate
    for index in 0..<80 {
        sql += "INSERT INTO ZBKLIBRARYASSET VALUES ('SYNTH\(index)', 'Catalog Book \(index)', 'Author \(index % 17)', \(index < 60 ? 1 : 0), \(finished - Double(index) * 86_400), NULL, NULL);"
    }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ReadingStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    return BooksCatalog(documents: documents)
}
