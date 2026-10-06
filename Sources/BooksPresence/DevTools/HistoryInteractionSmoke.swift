import AppKit
import SwiftUI
import BooksCore

private enum HistoryInteractionSmokeError: Error { case failed(String) }

/// Drives History's controls the way a person does: the timescale menu through
/// its native menu items, and a day's ring through real clicks and the
/// accessibility tree. Exercised by `--self-test-ui` on macOS CI.
@MainActor
func runHistoryInteractionSmoke() throws {
    try checkHistoryTimescaleMenu()
    try checkMonthDayOpening()
}

// MARK: - Timescale menu

@MainActor
private final class NavigationProbe: ObservableObject {
    @Published var navigation: CalendarNavigation
    init(_ navigation: CalendarNavigation) { self.navigation = navigation }
}

private struct NavigationProbeView: View {
    @ObservedObject var probe: NavigationProbe
    var body: some View {
        HistoryNavigationControls(navigation: $probe.navigation, canMoveForward: true).padding(20)
    }
}

@MainActor
private func hostedWindow<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSHostingView<V>) {
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    settle(host)
    return (window, host)
}

@MainActor
private func settle(_ host: NSView) {
    for _ in 0..<3 {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
}

private func nativeMenus(in view: NSView) -> [NSMenu] {
    var found: [NSMenu] = []
    if let menu = (view as? NSPopUpButton)?.menu ?? view.menu { found.append(menu) }
    for subview in view.subviews { found += nativeMenus(in: subview) }
    return found
}

private func describe(_ view: NSView, depth: Int = 0) -> String {
    let line = String(repeating: "  ", count: depth) + String(describing: type(of: view))
        + (view.menu.map { " menu[\($0.items.map(\.title).joined(separator: "|"))]" } ?? "")
    return ([line] + view.subviews.map { describe($0, depth: depth + 1) }).joined(separator: "\n")
}

@MainActor
private func checkHistoryTimescaleMenu() throws {
    let anchor = ISO8601DateFormatter().date(from: "2024-03-15T12:00:00Z")!
    let probe = NavigationProbe(CalendarNavigation(timezoneID: "UTC", anchor: anchor, scale: .month))
    let (window, host) = hostedWindow(NavigationProbeView(probe: probe), size: NSSize(width: 420, height: 90))
    defer { window.contentView = nil; window.close() }

    let titles = CalendarScale.allCases.map(\.title)
    // The menu must be a real native menu of the scales, not a plain button
    // that merely carries the current scale's name.
    func scaleMenu() -> NSMenu? {
        nativeMenus(in: host).first { menu in
            if let delegate = menu.delegate { delegate.menuNeedsUpdate?(menu) }
            return titles.allSatisfy { title in menu.items.contains { $0.title == title } }
        }
    }
    guard scaleMenu() != nil else {
        throw HistoryInteractionSmokeError.failed("History's timescale control exposes no native menu of \(titles). View tree:\n\(describe(host))")
    }
    for scale in [CalendarScale.week, .year, .day, .month] {
        guard let menu = scaleMenu(), let index = menu.items.firstIndex(where: { $0.title == scale.title }) else {
            throw HistoryInteractionSmokeError.failed("Timescale menu lost its \(scale.title) item after a selection")
        }
        menu.performActionForItem(at: index)
        settle(host)
        guard probe.navigation.scale == scale else {
            throw HistoryInteractionSmokeError.failed("Choosing \(scale.title) from the timescale menu left History on \(probe.navigation.scale.title)")
        }
        // Selecting a scale changes the anchor's period, never the anchor itself.
        guard probe.navigation.anchor == anchor else {
            throw HistoryInteractionSmokeError.failed("Choosing \(scale.title) moved History's anchor date")
        }
    }
    print("ui-smoke: History timescale menu lists every scale as native items and each one applies through its binding")
}

// MARK: - Double-click a day

private func accessibilityNodes(_ root: Any) -> [NSAccessibilityProtocol] {
    guard let node = root as? NSAccessibilityProtocol else { return [] }
    return [node] + (node.accessibilityChildren() ?? []).flatMap { accessibilityNodes($0) }
}

@MainActor
private func checkMonthDayOpening() throws {
    let zone = "UTC"
    let anchor = ISO8601DateFormatter().date(from: "2024-03-15T12:00:00Z")!
    let navigation = CalendarNavigation(timezoneID: zone, anchor: anchor, scale: .month)
    let calendar = navigation.calendar
    let book = BookRecord(id: "double-click-book", title: "Double Click")
    let readDay = calendar.date(from: DateComponents(year: 2024, month: 3, day: 8, hour: 12))!
    let interval = ReadingInterval(sessionID: "double-click-0", bookID: book.id, start: readDay,
        end: readDay.addingTimeInterval(1_200), duration: 1_200, timezoneID: zone, mode: .manual)
    let source = HistoryAtlasSource(books: [book], intervals: [interval], events: [], progress: [], merges: [],
        finishedBooks: [], pageEvidence: PageStatistics.snapshot(events: [], effectiveIntervals: [interval], merges: []))
    let presentation = HistoryAtlasPeriod(source: source, navigation: navigation, now: anchor)

    var opened: [Date] = []
    let (window, host) = hostedWindow(
        AtlasMonthView(navigation: navigation, presentation: presentation, select: { opened.append($0) })
            .frame(width: 1_000, height: 820),
        size: NSSize(width: 1_000, height: 820))
    defer { window.contentView = nil; window.close() }

    let label = DateText.string(readDay, zone: zone, pattern: "EEEE, MMMM d")
    func dayNode() throws -> NSAccessibilityProtocol {
        guard let node = accessibilityNodes(host).first(where: { $0.accessibilityLabel()?.hasPrefix(label) == true }) else {
            throw HistoryInteractionSmokeError.failed("Month view exposes no accessibility element for \(label)")
        }
        return node
    }
    func click(_ node: NSAccessibilityProtocol, count: Int) throws {
        let frame = node.accessibilityFrame()
        guard !frame.isEmpty else { throw HistoryInteractionSmokeError.failed("\(label) has an empty frame") }
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for number in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: number, pressure: type == .leftMouseDown ? 1 : 0) else {
                    throw HistoryInteractionSmokeError.failed("Could not construct a mouse event")
                }
                window.sendEvent(event)
            }
        }
        settle(host)
    }

    try click(try dayNode(), count: 1)
    guard opened.isEmpty else {
        throw HistoryInteractionSmokeError.failed("A single click on a day opened it; it must only select")
    }
    try click(try dayNode(), count: 2)
    guard opened.count == 1, calendar.isDate(opened[0], inSameDayAs: readDay) else {
        throw HistoryInteractionSmokeError.failed("Double-clicking \(label) opened \(opened.count) days instead of exactly that one")
    }

    opened = []
    let actions = try dayNode().accessibilityCustomActions() ?? []
    guard let open = actions.first(where: { $0.name == "Open day" }), open.handler?() == true else {
        throw HistoryInteractionSmokeError.failed("\(label) does not expose an \"Open day\" accessibility action (found \(actions.map(\.name)))")
    }
    guard opened.count == 1, calendar.isDate(opened[0], inSameDayAs: readDay) else {
        throw HistoryInteractionSmokeError.failed("The \"Open day\" accessibility action did not open \(label)")
    }
    print("ui-smoke: month day ring selects on one click, opens on double-click, and exposes an Open day accessibility action")
}
