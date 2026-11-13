import AppKit
import SwiftUI
import BooksCore

/// `--capture-finish-moment <dir> [--preview-appearance light|dark] [--reduce-motion] [--scenario today|sheet|detail]`
///
/// Plays the finish-a-book moment the two ways it really happens, with synthetic history in a
/// disposable store: a completion arriving while Today is on screen, the sheet that
/// "Mark as finished" opens from the Library, and "Mark as finished" pressed in Book details. For each it first measures the moment without
/// capturing (main-thread stalls and CPU time against the idle second before it), then plays it
/// again and saves composited window frames about 30 times a second. Windows are parked by
/// background mode, so nothing takes focus.
@MainActor
func captureFinishMoment(to destination: URL) throws {
    let arguments = CommandLine.arguments
    let reduceMotion = arguments.contains("--reduce-motion")
    let appearance = arguments.firstIndex(of: "--preview-appearance")
        .flatMap { arguments.indices.contains($0 + 1) ? DashboardAppearance(rawValue: arguments[$0 + 1]) : nil }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Finish moment capture")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    var report: [[String: Any]] = []
    // `--scenario today|sheet|detail` plays just one.
    let only = arguments.firstIndex(of: "--scenario").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    for scenario in ["today", "sheet", "detail"] where only == nil || only == scenario {
        for pass in ["measure", "frames"] {
            let support = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-finish-\(UUID().uuidString)")
            let suite = "Stillleaf.FinishMoment.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set("America/Los_Angeles", forKey: "timezoneID")
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: support)
            }
            ThemeStore.shared.reload(from: defaults)
            if let appearance { ThemeStore.shared.select(appearance: appearance) }
            try seedPreviewHistory(at: support)
            let model = try AppModel(support: support, defaults: defaults, startTracking: false)
            defer { model.shutdown() }
            let finished = Set(model.finishedBooks.map(\.id))
            guard let book = model.books.first(where: { !finished.contains($0.id) }) else { throw FinishMomentCaptureError.noUnfinishedBook }
            let frames = pass == "frames" ? destination.appendingPathComponent(scenario) : nil
            if let frames { try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true) }
            var result = try playFinishMoment(scenario: scenario, model: model, book: book, reduceMotion: reduceMotion, frames: frames)
            result["scenario"] = scenario; result["pass"] = pass
            report.append(result)
        }
    }
    ThemeStore.shared.reload(from: .standard)
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: destination.appendingPathComponent("finish-moment.json"))
    print(String(decoding: data, as: UTF8.self))
}

private enum FinishMomentCaptureError: Error { case noUnfinishedBook }

@MainActor
private func playFinishMoment(scenario: String, model: AppModel, book: BookRecord, reduceMotion: Bool, frames: URL?) throws -> [String: Any] {
    let window = DashboardWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Stillleaf"
    window.contentViewController = NSHostingController(rootView: DashboardView(model: model, initialSection: scenario == "today" ? .today : .library)
        .environment(\.nativePreviewReduceMotion, reduceMotion))
    window.setContentSize(NSSize(width: 1060, height: 760))
    window.makeKeyAndOrderFront(nil)
    defer { window.contentViewController = nil; window.close() }
    var sheet: NSWindow?
    // Book details is already open; the moment is a real click on its Mark as finished button.
    if scenario == "detail" { sheet = presentBookDetail(model: model, book: book, over: window, reduceMotion: reduceMotion) }
    // Let the screen, its entrance and the garden settle before anything is finished.
    spin(for: 2.0)
    let idle = sampleMainThread(for: 1.0)

    let moment: () -> Void = {
        if scenario == "detail", let sheet {
            clickProbe("mark-finished", in: sheet)
            return
        }
        guard let entry = model.markFinished(book) else { return }
        guard scenario == "sheet" else { return }
        let content = CompletionReviewSheet(model: model, entry: entry)
            .buttonStyle(ReadingButtonStyle()).readingMotionAccessibility()
            .environment(\.gardenBackdrop, false)
            .environment(\.nativePreviewReduceMotion, reduceMotion)
        let hosted = NSWindow(contentViewController: NSHostingController(rootView: content))
        hosted.isReleasedWhenClosed = false
        window.beginSheet(hosted)
        sheet = hosted
    }
    defer { if let sheet { window.endSheet(sheet); sheet.close() } }

    let duration = 3.4
    if let frames {
        moment()
        let target = { sheet ?? window }
        var manifest: [[String: Any]] = []
        let start = CACurrentMediaTime()
        var index = 0
        while CACurrentMediaTime() - start < duration {
            let due = start + Double(index) / 30
            while CACurrentMediaTime() < due { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002)) }
            let at = CACurrentMediaTime() - start
            if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(target().windowNumber), [.boundsIgnoreFraming, .nominalResolution]),
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                let name = String(format: "frame-%03d.png", index)
                try png.write(to: frames.appendingPathComponent(name))
                manifest.append(["file": name, "ms": Int((at * 1000).rounded())])
            }
            index += 1
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try data.write(to: frames.appendingPathComponent("frames.json"))
        return ["frames": manifest.count]
    }
    let cpuBefore = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
    let started = CACurrentMediaTime()
    moment()
    let commit = CACurrentMediaTime() - started
    let busy = sampleMainThread(for: duration - commit)
    let cpu = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuBefore) / 1e6
    return ["idleSecond": idle, "moment": busy, "momentCPUms": Int(cpu.rounded()),
            "markFinishedAndPresentMs": Int((commit * 1000).rounded())]
}

/// Runs the main loop for `seconds`.
@MainActor
private func spin(for seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01))) }
}

/// Runs the main loop for `seconds` with a 4 ms probe timer, reporting how long the main thread
/// was unavailable: the longest gap between probes and how many gaps would drop frames at 60 Hz.
@MainActor
private func sampleMainThread(for seconds: Double) -> [String: Any] {
    final class Probe { let start = CACurrentMediaTime(); var last = CACurrentMediaTime(); var gaps: [Double] = []; var ends: [Double] = [] }
    let probe = Probe()
    let timer = Timer(timeInterval: 0.004, repeats: true) { _ in
        let now = CACurrentMediaTime()
        probe.gaps.append(now - probe.last)
        probe.ends.append(now - probe.start)
        probe.last = now
    }
    timer.tolerance = 0
    RunLoop.main.add(timer, forMode: .common)
    let cpuBefore = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
    spin(for: seconds)
    timer.invalidate()
    let cpu = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuBefore) / 1e6
    let ms = probe.gaps.map { $0 * 1000 }
    let longest = ms.indices.max { ms[$0] < ms[$1] }
    return ["longestStallMs": Int((ms.max() ?? 0).rounded()),
            // When the longest stall began, from the start of sampling.
            "longestStallAtMs": longest.map { Int(((probe.ends[$0] * 1000) - ms[$0]).rounded()) } ?? 0,
            "stallsOver25ms": ms.filter { $0 > 25 }.count,
            "stallsOver50ms": ms.filter { $0 > 50 }.count,
            "cpuMs": Int(cpu.rounded()), "seconds": seconds]
}
