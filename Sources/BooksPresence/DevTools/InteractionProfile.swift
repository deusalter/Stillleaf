import AppKit
import SwiftUI
import BooksCore
import Darwin

/// Main-thread cost of the dashboard's everyday interactions, measured on the real view tree in a
/// window that is never shown: switching screens, a model update (what every tracking tick sends
/// while a book is open) and scrolling. `--render-ui <dir> --offscreen --profile-interactions`.
/// `STILLLEAF_PROFILE_SUPPORT` points at a copy of a real support folder; without it, the preview
/// history is used. Writes `interactions.json` to the render directory and prints a table.
@MainActor
func runInteractionProfile(to destination: URL) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-profile-\(UUID().uuidString)")
    let suite = "Stillleaf.Profile.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    // Mirror the installed app's look and goals, so the garden and theme match what is on screen.
    if let installed = UserDefaults(suiteName: "com.bookspresence.app") {
        for key in ["appearanceAccent", "appearanceMode", "appearanceTheme", "gardenMode", "goalMinutes", "pageGoal", "timezoneID", "dailyGoalUnit", "annualBookGoal"] {
            if let value = installed.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }
    ThemeStore.shared.reload(from: defaults)
    defer { ThemeStore.shared.reload(from: .standard) }
    let support: URL
    if let path = ProcessInfo.processInfo.environment["STILLLEAF_PROFILE_SUPPORT"] {
        support = URL(fileURLWithPath: path, isDirectory: true)
    } else {
        support = root
        try seedPreviewHistory(at: support)
    }
    let model = try AppModel(support: support, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    let dark = ThemeStore.shared.appearanceMode != .light
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    NSApp.appearance = appearance

    let size = NSSize(width: 1100, height: 760)
    let window = DashboardWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    let controller = NSHostingController(rootView: DashboardView(model: model, initialSection: .today))
    controller.sizingOptions = []
    window.contentViewController = controller
    window.setContentSize(size)
    let host = controller.view
    defer { window.close() }

    func cpu() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
    func ms(_ start: UInt64) -> Double { Double(cpu() - start) / 1_000_000 }
    func settle() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
    /// Main-thread CPU spent while the run loop drains for `seconds`, including timelines and
    /// deferred updates, plus a final layout and display.
    func drain(_ seconds: TimeInterval) -> Double {
        let start = cpu()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60))
            settle()
        }
        return ms(start)
    }
    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
    func scrollViews(_ view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView, let document = scroll.documentView,
           document.frame.height > scroll.contentView.bounds.height + 80 { found.append(scroll) }
        for child in view.subviews { found += scrollViews(child) }
        return found
    }

    // Optional focus for sampling: `STILLLEAF_PROFILE_SECTIONS=timeline,health` limits the screens,
    // and `STILLLEAF_PROFILE_LOOP=update|switch|scroll:<seconds>` repeats one measurement for that
    // long (print the pid first), so `sample <pid>` can attribute where the time goes.
    let environment = ProcessInfo.processInfo.environment
    let onlySections = environment["STILLLEAF_PROFILE_SECTIONS"].map { Set($0.split(separator: ",").map(String.init)) }
    let loop = environment["STILLLEAF_PROFILE_LOOP"].flatMap { spec -> (String, TimeInterval)? in
        let parts = spec.split(separator: ":")
        return parts.count == 2 ? (String(parts[0]), TimeInterval(parts[1]) ?? 20) : nil
    }
    print("interaction-profile: pid \(getpid())")
    print("interaction-profile: \(model.books.count) books, \(model.intervals.count) intervals, \(model.events.count) events, garden \(ThemeStore.shared.gardenMode.rawValue)")
    _ = drain(1.5)
    var rows: [[String: Any]] = []
    for pass in 0..<2 {
        for section in DashboardSection.allCases where onlySections?.contains(section.rawValue) ?? true {
            // Screen switch: the synchronous update, then the following second of frames.
            let switchStart = cpu()
            model.dashboardSectionRequest = section
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            settle()
            let switchMs = ms(switchStart)
            let followMs = drain(1.0)
            if environment["STILLLEAF_PROFILE_LAYERS"] != nil {
                // Large layers are repainted whole on the CPU: list them (class, size in points, tiling).
                func dump(_ layer: CALayer, _ depth: Int) {
                    let area = layer.bounds.width * layer.bounds.height
                    if area > 300_000 {
                        print("layers: \(section.rawValue) \(String(repeating: " ", count: depth))\(type(of: layer)) \(Int(layer.bounds.width))x\(Int(layer.bounds.height)) contents=\(layer.contents.map { String(describing: type(of: $0)) } ?? "-") mask=\(layer.mask != nil) delegate=\(layer.delegate.map { String(describing: type(of: $0)) } ?? "-")")
                    }
                    for child in layer.sublayers ?? [] { dump(child, depth + 1) }
                }
                if let layer = host.layer { dump(layer, 0) }
            }
            if let (kind, seconds) = loop {
                // Sampling mode: repeat the chosen interaction for `seconds`, then move on.
                let end = Date().addingTimeInterval(seconds)
                let other: DashboardSection = section == .review ? .health : .review
                while Date() < end {
                    switch kind {
                    case "switch":
                        model.dashboardSectionRequest = other
                        RunLoop.current.run(until: Date().addingTimeInterval(0.001)); settle()
                        model.dashboardSectionRequest = section
                        RunLoop.current.run(until: Date().addingTimeInterval(0.001)); settle()
                    case "scroll":
                        if let scroll = scrollViews(host).max(by: { $0.documentView!.frame.height < $1.documentView!.frame.height }) {
                            let clip = scroll.contentView
                            let limit = (scroll.documentView?.frame.height ?? 0) - clip.bounds.height
                            var y: CGFloat = 0
                            while y + 40 <= limit && Date() < end {
                                y += 40
                                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y)); scroll.reflectScrolledClipView(clip)
                                RunLoop.current.run(until: Date().addingTimeInterval(0.001)); settle()
                            }
                            clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip); settle()
                        }
                    default:
                        model.objectWillChange.send()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.001)); settle()
                    }
                }
                return
            }
            // A model update, as sent once a second by tracking while a book is open.
            var updates: [Double] = []
            let heightsBefore = scrollViews(host).map { Int($0.documentView!.frame.height * 100) }
            for _ in 0..<8 {
                let start = cpu()
                model.objectWillChange.send()
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                settle()
                updates.append(ms(start))
            }
            if environment["STILLLEAF_PROFILE_LAYERS"] != nil {
                print("layers: \(section.rawValue) document heights (x100) before updates \(heightsBefore), after \(scrollViews(host).map { Int($0.documentView!.frame.height * 100) })")
            }
            // Scrolling the screen's main scroll view in 40 pt steps.
            var steps: [Double] = []
            if let scroll = scrollViews(host).max(by: { $0.documentView!.frame.height < $1.documentView!.frame.height }) {
                let clip = scroll.contentView
                let limit = (scroll.documentView?.frame.height ?? 0) - clip.bounds.height
                var y: CGFloat = 0
                for _ in 0..<24 where y + 40 <= limit {
                    y += 40
                    let start = cpu()
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y)); scroll.reflectScrolledClipView(clip)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                    settle()
                    steps.append(ms(start))
                }
                clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip); settle()
            }
            let row: [String: Any] = ["pass": pass, "section": section.rawValue, "switchMs": switchMs, "followingSecondMs": followMs,
                                      "modelUpdateMedianMs": median(updates), "modelUpdateMaxMs": updates.max() ?? 0,
                                      "scrollStepMedianMs": median(steps), "scrollStepMaxMs": steps.max() ?? 0, "scrollSteps": steps.count]
            if pass == 1 { rows.append(row) }
            print(String(format: "interaction-profile: pass %d %-9@ switch %7.1f  next-second %7.1f  model-update %6.1f (max %6.1f)  scroll-step %6.1f (max %6.1f, n=%d)",
                         pass, section.rawValue as NSString, switchMs, followMs, median(updates), updates.max() ?? 0,
                         median(steps), steps.max() ?? 0, steps.count))
        }
    }
    // Saving an edit, as the book sheet does when a rating is chosen: the write, the history
    // reload that follows it and the dashboard's update, on whichever screen was shown last.
    var edits: [Double] = []
    if let book = model.finishedBooks.first {
        for _ in 0..<6 {
            let start = cpu()
            model.saveRating(model.rating(for: book.id), for: book.id)
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            settle()
            edits.append(ms(start))
        }
        print(String(format: "interaction-profile: save a rating %7.1f (max %7.1f)", median(edits), edits.max() ?? 0))
    }
    let data = try JSONSerialization.data(withJSONObject: ["rows": rows, "books": model.books.count, "intervals": model.intervals.count,
                                                           "saveRatingMedianMs": median(edits)],
                                          options: [.prettyPrinted, .sortedKeys])
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try data.write(to: destination.appendingPathComponent("interactions.json"))
}
