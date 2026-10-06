import AppKit
import SwiftUI
import BooksCore
import CoreFoundation
import Darwin

/// Cloud main-thread responsiveness gate. Await actual prepared History content
/// appearance, then force its final layout/display; never infer readiness from a sleep.
@MainActor func runSettledUIBenchmark(output: URL) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-benchmark-\(UUID().uuidString)")
    let suite = "Stillleaf.Benchmark.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set("America/Los_Angeles", forKey: "timezoneID")
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var archive = HistoryArchive()
    archive.books = (0..<60).map { BookRecord(id: "book-\($0)", title: "Synthetic Book \($0)") }
    let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3600)
    for index in 0..<2000 {
        let start = end.addingTimeInterval(Double(index - 2000) * 1800)
        let book = archive.books[index % archive.books.count]
        let session = "session-\(index / 10)"
        archive.intervals.append(ReadingInterval(sessionID: session, bookID: book.id, start: start,
            end: start.addingTimeInterval(600), duration: 600, timezoneID: "America/Los_Angeles", mode: .automatic))
        let turn = 1
        archive.events.append(AuditEvent(date: start.addingTimeInterval(600), kind: "pageTurn",
                bookID: book.id, sessionID: session, detail: "Synthetic performance fixture",
                pageTurn: PageTurnEvidence(fromPage: turn, toPage: turn + 3, pagesRead: 3, visiblePages: 1, layoutSignature: "fixture")))
    }
    for (index, book) in archive.books.enumerated() {
        let finished = end.addingTimeInterval(Double(-index) * 86_400)
        archive.events.append(AuditEvent(date: finished, kind: "bookCompleted", bookID: book.id, detail: "Synthetic completion",
            completion: BookCompletionEvidence(finishedAt: finished, source: "Fixture", imported: true)))
        archive.events.append(AuditEvent(date: finished, kind: "bookReviewed", bookID: book.id, detail: "Synthetic written review",
            review: BookReviewEvidence(text: String(repeating: "A memorable chapter. ", count: 35))))
    }
    let fixture = root.appendingPathComponent("fixture.json")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(archive).write(to: fixture)
    let store = try ReadingStore(url: root.appendingPathComponent("history.sqlite"))
    try store.importJSON(from: fixture)
    let model = try AppModel(support: root, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    // Fit the 1024×768 hosted display. Disable hosting-driven intrinsic window
    // resizing so both builds measure exactly the same visible content area.
    let viewport = NSSize(width: 960, height: 620)
    NSApp.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 16, y: 32), size: viewport), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AnyView(Text("Ready")))
    host.sizingOptions = []
    window.contentView = host
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    let focusDeadline = ProcessInfo.processInfo.systemUptime + 3
    while (!NSApp.isActive || !window.isKeyWindow) && ProcessInfo.processInfo.systemUptime < focusDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
    // Activation can change modern titlebar geometry. Lock the content area
    // after that transition, rather than pinning its earlier outer frame.
    window.setContentSize(viewport)
    window.minSize = window.frame.size; window.maxSize = window.frame.size
    print("settled-ui-geometry: window=\(window.frame) host=\(host.bounds) expected=\(viewport) appActive=\(NSApp.isActive) key=\(window.isKeyWindow)")
    let sourceDeadline = ProcessInfo.processInfo.systemUptime + 20
    while model.historyAtlasSource == nil && ProcessInfo.processInfo.systemUptime < sourceDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
    guard model.historyAtlasSource != nil else { throw NSError(domain: "Stillleaf.Benchmark", code: 1) }
    var workStart: Double?, cpuStart: UInt64?, work: [Double] = [], cpuWork: [Double] = [], recording = false
    // Darwin CPU clocks exclude sleep, descheduling and WindowServer waits.
    func threadCPU() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
    func processCPU() -> UInt64 { clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) }
    func elapsedCPU(_ start: UInt64, _ end: UInt64) -> Double { Double(end - start) / 1_000_000 }
    let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
    let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
        MainActor.assumeIsolated {
            guard recording else { return }
            if activity == .afterWaiting { workStart = ProcessInfo.processInfo.systemUptime; cpuStart = threadCPU() }
            else if let start = workStart, let cpu = cpuStart {
                work.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                cpuWork.append(elapsedCPU(cpu, threadCPU()))
                workStart = nil; cpuStart = nil
            }
        }
    }!
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    let measuredSamples = ProcessInfo.processInfo.environment["STILLLEAF_UI_BENCHMARK_SAMPLES"].flatMap(Int.init) ?? 20
    guard [5, 20].contains(measuredSamples) else { throw NSError(domain: "Stillleaf.Benchmark", code: 3) }
    var records: [[String: Any]] = [], warmups: [[String: Any]] = []
    for scale in CalendarScale.allCases {
        for sample in -2..<measuredSamples {
            host.rootView = AnyView(Text("Ready")); host.layoutSubtreeIfNeeded()
            await Task.yield()
            var ready = false
            work.removeAll(); cpuWork.removeAll(); workStart = nil; cpuStart = nil; recording = true
            let start = ProcessInfo.processInfo.systemUptime
            let totalCPUStart = processCPU(), assignmentCPUStart = threadCPU()
            host.rootView = AnyView(HistoryView(model: model, initialScale: scale, anchor: end, benchmarkReady: { key in if key.scale == scale { ready = true } }).id(UUID()).transaction { $0.disablesAnimations = true; $0.animation = nil })
            work.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            cpuWork.append(elapsedCPU(assignmentCPUStart, threadCPU()))
            let deadline = start + 10
            while !ready && ProcessInfo.processInfo.systemUptime < deadline {
                let layoutStart = ProcessInfo.processInfo.systemUptime, layoutCPUStart = threadCPU()
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                work.append((ProcessInfo.processInfo.systemUptime - layoutStart) * 1000)
                cpuWork.append(elapsedCPU(layoutCPUStart, threadCPU()))
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard ready else { throw NSError(domain: "Stillleaf.Benchmark", code: 2) }
            await Task.yield()
            let finalStart = ProcessInfo.processInfo.systemUptime, finalCPUStart = threadCPU()
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            work.append((ProcessInfo.processInfo.systemUptime - finalStart) * 1000)
            cpuWork.append(elapsedCPU(finalCPUStart, threadCPU()))
            let settledCPU = elapsedCPU(totalCPUStart, processCPU())
            recording = false
            guard abs(host.bounds.width - viewport.width) < 0.5, abs(host.bounds.height - viewport.height) < 0.5 else { throw NSError(domain: "Stillleaf.Benchmark", code: 4, userInfo: [NSLocalizedDescriptionKey: "Rendered bounds \(host.bounds) differ from \(viewport); outer frame \(window.frame)"]) }
            let record: [String: Any] = ["viewportWidth": host.bounds.width, "viewportHeight": host.bounds.height, "appActive": NSApp.isActive, "keyWindow": window.isKeyWindow, "scale": scale.rawValue, "sample": sample, "settledMs": (ProcessInfo.processInfo.systemUptime - start) * 1000, "maxMainWorkMs": work.max() ?? 0, "settledProcessCPUMs": settledCPU, "maxMainThreadCPUMs": cpuWork.max() ?? 0]
            if sample >= 0 { records.append(record) } else { warmups.append(record) }
        }
    }
    let data = try JSONSerialization.data(withJSONObject: ["fixture": "60 books / 2000 intervals / 2000 page events", "method": "\(measuredSamples) samples per scale; two warmups; fresh view/controller; actual prepared-content onAppear; animation disabled; run-loop wall/thread CPU work plus explicit layout/display; process CPU across settled readiness", "samples": records, "warmups": warmups], options: [.prettyPrinted, .sortedKeys])
    try data.write(to: output)
    print("settled-ui-benchmark: \(records.count) async History samples written to \(output.path)")
}
