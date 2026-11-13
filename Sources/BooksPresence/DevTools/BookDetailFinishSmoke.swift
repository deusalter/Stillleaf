import AppKit
import SwiftUI
import BooksCore

private enum BookDetailFinishSmokeError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

/// Marks books finished from Book details by clicking its real buttons, in a Book details sheet over
/// a dashboard showing Today (which shows the same pending completion behind the sheet). Checks that
/// the finish opens in place instead of stacking a sheet, that Book details owns the moment, and
/// that each way out (Save rating, Maybe later, closing Book details) saves exactly what the finish
/// sheet saved. Synthetic history in a disposable store; windows are parked by background mode.
@MainActor
func checkBookDetailFinish() throws {
    func fail(_ message: String) -> Error { BookDetailFinishSmokeError.failed("Book details finish: \(message)") }
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-detail-finish-\(UUID().uuidString)")
    let suite = "Stillleaf.DetailFinish.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set("America/Los_Angeles", forKey: "timezoneID")
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: support)
    }
    try seedPreviewHistory(at: support)
    let model = try AppModel(support: support, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    let finished = Set(model.finishedBooks.map(\.id))
    let unfinished = model.books.filter { !finished.contains($0.id) }
    guard unfinished.count >= 3 else { throw fail("the fixture needs three unfinished books, has \(unfinished.count)") }

    let dashboard = DashboardWindow.make()
    dashboard.contentViewController = NSHostingController(rootView: DashboardView(model: model, initialSection: .today))
    dashboard.makeKeyAndOrderFront(nil)
    defer { dashboard.contentViewController = nil; dashboard.close() }
    pumpMainLoop(for: 0.8)

    for (book, exit) in zip(unfinished, ["save rating", "maybe later", "close Book details"]) {
        let detail = presentBookDetail(model: model, book: book, over: dashboard)
        defer { if dashboard.attachedSheet === detail { dashboard.endSheet(detail) }; detail.close() }
        guard clickProbe("mark-finished", in: detail) else { throw fail("no Mark as finished button for \(book.title)") }
        guard pumpMainLoop(until: { probeFrame("finish-save-rating", in: detail) != nil }) else {
            throw fail("the finish question never opened in Book details")
        }
        guard detail.attachedSheet == nil, dashboard.attachedSheet === detail else { throw fail("marking finished stacked a sheet on Book details") }
        guard let entry = model.pendingCompletion, entry.id == book.id, model.finishedBooks.contains(where: { $0.id == book.id }) else {
            throw fail("\(book.title) was not saved as finished and pending")
        }
        // Book details claimed the moment as it marked the book, so Today behind it could not.
        guard !model.claimCompletionCelebration(for: entry) else { throw fail("Book details did not claim its finish moment") }
        guard pumpMainLoop(until: { probeFrame("detail-rating-section", in: detail) == nil }) else {
            throw fail("the rating section stayed beside the finish question")
        }
        switch exit {
        case "save rating":
            // The star row is a drag gesture, which synthetic events do not reach; its + button is a button.
            for _ in 0..<5 {
                guard clickProbe("rating-increase", in: detail) else { throw fail("no button to raise the rating") }
                pumpMainLoop(for: 0.05)
            }
            captureForDebugging(detail, "after-star-click")
            guard clickProbe("finish-save-rating", in: detail) else { throw fail("Save rating did not click") }
            pumpMainLoop(for: 0.2)
            captureForDebugging(detail, "after-save-click")
            guard pumpMainLoop(until: { probeFrame("finish-save-rating", in: detail) == nil && probeFrame("detail-rating-section", in: detail) != nil }) else {
                throw fail("saving a rating left the finish question open (saved rating \(String(describing: model.rating(for: book.id))), pending \(String(describing: model.pendingCompletion?.id)))")
            }
            guard model.rating(for: book.id) == 1.25, model.pendingCompletion == nil else {
                throw fail("Save rating saved \(String(describing: model.rating(for: book.id))), pending \(String(describing: model.pendingCompletion?.id))")
            }
        case "maybe later":
            guard clickProbe("finish-dismiss", in: detail) else { throw fail("Maybe later did not click") }
            guard pumpMainLoop(until: { probeFrame("finish-dismiss", in: detail) == nil && probeFrame("detail-rating-section", in: detail) != nil }) else {
                throw fail("Maybe later left the finish question open")
            }
            guard model.rating(for: book.id) == nil, model.pendingCompletion == nil,
                  model.finishedBooks.contains(where: { $0.id == book.id }) else { throw fail("Maybe later changed what was saved") }
        default:
            // As SwiftUI dismissing the sheet does: the view leaves the hierarchy, not just the screen.
            dashboard.endSheet(detail)
            detail.contentViewController = nil
            detail.close()
            pumpMainLoop(for: 0.3)
            guard model.pendingCompletion == nil, model.rating(for: book.id) == nil,
                  model.finishedBooks.contains(where: { $0.id == book.id }) else { throw fail("closing Book details did not leave the finish for later") }
        }
    }
    print("ui-smoke: Book details opens a finish in place (no stacked sheet), owns its moment, and Save rating, Maybe later and closing save as the finish sheet did")
}

/// Book details as the dashboard presents it: a sheet on the dashboard window.
@MainActor
func presentBookDetail(model: AppModel, book: BookRecord, over parent: NSWindow, reduceMotion: Bool = false) -> NSWindow {
    let content = BookDetailView(model: model, book: book)
        .buttonStyle(ReadingButtonStyle()).readingMotionAccessibility()
        .environment(\.gardenBackdrop, false)
        .environment(\.nativePreviewReduceMotion, reduceMotion)
    let sheet = NSWindow(contentViewController: NSHostingController(rootView: content))
    sheet.isReleasedWhenClosed = false
    parent.beginSheet(sheet)
    pumpMainLoop(for: 0.6)
    return sheet
}

// MARK: Probes and clicks

/// With `STILLLEAF_SMOKE_CAPTURE=<dir>`, saves the window as `<name>.png` there, to see what a step did.
@MainActor
func captureForDebugging(_ window: NSWindow, _ name: String) {
    guard let directory = ProcessInfo.processInfo.environment["STILLLEAF_SMOKE_CAPTURE"],
          let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .nominalResolution]),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
}

/// Where the control marked with `ViewProbe(id)` is, in window coordinates; nil once it has left.
@MainActor
func probeFrame(_ id: String, in window: NSWindow) -> NSRect? {
    func find(_ view: NSView) -> NSView? {
        if view.identifier == ViewProbe.identifier(id) { return view }
        for child in view.subviews { if let found = find(child) { return found } }
        return nil
    }
    guard let root = window.contentView, let probe = find(root), !probe.isHiddenOrHasHiddenAncestor else { return nil }
    let frame = probe.convert(probe.bounds, to: nil)
    return frame.width > 0 && frame.height > 0 ? frame : nil
}

/// Clicks the control marked with `ViewProbe(id)`, at its centre or at `point(frame)`, with real mouse events.
@MainActor @discardableResult
func clickProbe(_ id: String, in window: NSWindow, at point: (NSRect) -> NSPoint = { NSPoint(x: $0.midX, y: $0.midY) }) -> Bool {
    guard let frame = probeFrame(id, in: window) else { return false }
    let location = point(frame)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseDown ? 1 : 0) else { return false }
        window.sendEvent(event)
    }
    return true
}

@MainActor
func pumpMainLoop(for seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01))) }
}

/// Runs the main loop until `condition` holds, for at most `timeout` seconds.
@MainActor @discardableResult
func pumpMainLoop(until condition: () -> Bool, timeout: Double = 3) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return condition()
}
