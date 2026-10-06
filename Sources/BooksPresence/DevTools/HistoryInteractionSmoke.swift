import AppKit
import SwiftUI
import BooksCore

private enum HistoryInteractionSmokeError: Error { case failed(String) }

/// Drives History's controls the way a person does: the timescale menu through
/// its native menu items, and a day's ring through real clicks and the
/// accessibility tree. Exercised by `--self-test-ui` on macOS CI.
@MainActor
func runHistoryInteractionSmoke() throws {
    // Both checks always run so one CI pass reports every broken interaction.
    var failures: [String] = []
    for check in [checkHistoryTimescaleMenu, checkMonthDayOpening] {
        do { try check() } catch { failures.append("\(error)") }
    }
    if !failures.isEmpty { throw HistoryInteractionSmokeError.failed(failures.joined(separator: "\n--\n")) }
}

// MARK: - Timescale menu

@MainActor
private final class NavigationProbe: ObservableObject {
    @Published var navigation: CalendarNavigation
    var controlPicks = 0
    init(_ navigation: CalendarNavigation) { self.navigation = navigation }
}

private struct NavigationProbeView: View {
    @ObservedObject var probe: NavigationProbe
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HistoryNavigationControls(navigation: $probe.navigation, canMoveForward: true)
            // Control: a menu styled the way Library and Settings style theirs.
            Menu("Control") { Button("One") { probe.controlPicks += 1 }; Button("Two") { probe.controlPicks += 1 } }
                .menuStyle(ReadingMenuStyle())
        }
        .padding(20)
        // The dashboard wraps every screen in this style; the controls must work under it.
        .buttonStyle(ReadingButtonStyle())
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

private func describe(_ view: NSView, depth: Int = 0) -> String {
    let line = String(repeating: "  ", count: depth) + String(describing: type(of: view))
        + (view.menu.map { " menu[\($0.items.map(\.title).joined(separator: "|"))]" } ?? "")
    return ([line] + view.subviews.map { describe($0, depth: depth + 1) }).joined(separator: "\n")
}

private func popupButtons(in view: NSView) -> [NSPopUpButton] {
    ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap { popupButtons(in: $0) }
}

/// Opens a native popup the way a click does, reads its items while the menu is
/// tracking, then cancels. nil means tracking never began (the click did nothing).
@MainActor
private func openPopup(_ popup: NSPopUpButton) -> [NSMenuItem]? {
    var items: [NSMenuItem]?
    // The timer only fires once the menu's tracking loop is running.
    let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
        MainActor.assumeIsolated {
            if items == nil { items = popup.menu?.items }
            popup.menu?.cancelTracking()
        }
    }
    RunLoop.main.add(timer, forMode: .default)
    RunLoop.main.add(timer, forMode: .eventTracking)
    defer { timer.invalidate() }
    popup.performClick(nil)
    return items
}

@MainActor
private func checkHistoryTimescaleMenu() throws {
    let anchor = ISO8601DateFormatter().date(from: "2024-03-15T12:00:00Z")!
    let probe = NavigationProbe(CalendarNavigation(timezoneID: "UTC", anchor: anchor, scale: .month))
    let (window, host) = hostedWindow(NavigationProbeView(probe: probe), size: NSSize(width: 420, height: 160))
    defer { window.contentView = nil; window.close() }

    let popups = popupButtons(in: host)
    var diagnostics = ["popup buttons: \(popups.count)"]
    // Control menu first: if it opens but History's does not, the difference is History's.
    var controlOpened: [String]?
    if let control = popups.last, popups.count == 2 {
        controlOpened = openPopup(control)?.map(\.title)
        diagnostics.append("control menu items while open: \(String(describing: controlOpened))")
    }
    guard let scalePopup = popups.first, popups.count == 2 else {
        throw HistoryInteractionSmokeError.failed("Expected the timescale and control popups, found \(popups.count). Tree:\n\(describe(host))")
    }
    guard let opened = openPopup(scalePopup) else {
        throw HistoryInteractionSmokeError.failed("Clicking History's timescale popup never began menu tracking (\(diagnostics.joined(separator: "; "))). Tree:\n\(describe(host))")
    }
    diagnostics.append("timescale items while open: \(opened.map(\.title))")
    let titles = CalendarScale.allCases.map(\.title)
    guard titles.allSatisfy({ title in opened.contains { $0.title == title } }) else {
        throw HistoryInteractionSmokeError.failed("Timescale menu opened without \(titles) (\(diagnostics.joined(separator: "; ")))")
    }
    for scale in [CalendarScale.week, .year, .day, .month] {
        guard let menu = scalePopup.menu else { throw HistoryInteractionSmokeError.failed("Timescale popup lost its menu") }
        if !menu.items.contains(where: { $0.title == scale.title }) { _ = openPopup(scalePopup) }
        guard let index = scalePopup.menu?.items.firstIndex(where: { $0.title == scale.title }) else {
            throw HistoryInteractionSmokeError.failed("Timescale menu has no \(scale.title) item after reopening (\(diagnostics.joined(separator: "; ")))")
        }
        scalePopup.menu?.performActionForItem(at: index)
        settle(host)
        guard probe.navigation.scale == scale else {
            throw HistoryInteractionSmokeError.failed("Choosing \(scale.title) from the timescale menu left History on \(probe.navigation.scale.title) (\(diagnostics.joined(separator: "; ")))")
        }
        guard probe.navigation.anchor == anchor else {
            throw HistoryInteractionSmokeError.failed("Choosing \(scale.title) moved History's anchor date")
        }
    }
    print("ui-smoke: History timescale menu opens under the dashboard's button style and each scale applies through its binding (\(diagnostics.joined(separator: "; ")))")
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
