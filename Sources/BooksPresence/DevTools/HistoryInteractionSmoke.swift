import AppKit
import SwiftUI
import BooksCore

private enum HistoryInteractionSmokeError: Error { case failed(String) }

/// Drives History's controls the way a person does: native menus through real
/// mouse events and their items, a day's ring through clicks. Exercised by
/// `--self-test-ui` on macOS CI.
@MainActor
func runHistoryInteractionSmoke(model: AppModel) throws {
    // Every check always runs so one CI pass reports every broken interaction.
    var failures: [String] = []
    let checks: [(String, () throws -> Void)] = [
        ("timescale menu in isolation", checkHistoryTimescaleMenu),
        ("timescale menu in the dashboard window", { try checkTimescaleInDashboard(model: model) }),
        ("timescale pick reaches the published chart", { try checkTimescalePublishes(model: model) }),
        ("month day opening", checkMonthDayOpening),
        ("day view disclosures", checkDayDisclosures),
    ]
    for (name, check) in checks {
        do { try check() } catch { failures.append("[\(name)] \(error)") }
    }
    if !failures.isEmpty { throw HistoryInteractionSmokeError.failed(failures.joined(separator: "\n--\n")) }
}

// MARK: - Shared helpers

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
private func settle(_ host: NSView, passes: Int = 3) {
    for _ in 0..<passes {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
}

@MainActor
private func pump(timeout: TimeInterval = 10, until finished: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !finished(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    return finished()
}

private func popupButtons(in view: NSView) -> [NSPopUpButton] {
    ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap { popupButtons(in: $0) }
}

private func textFields(in view: NSView) -> [String] {
    ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
}

private func describe(_ view: NSView, depth: Int = 0) -> String {
    let line = String(repeating: "  ", count: depth) + String(describing: type(of: view))
        + (view.menu.map { " menu[\($0.items.map(\.title).joined(separator: "|"))]" } ?? "")
    return ([line] + view.subviews.map { describe($0, depth: depth + 1) }).joined(separator: "\n")
}

@MainActor
private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, count: Int = 1,
                   after delay: TimeInterval = 0) {
    guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime + delay, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0) else { return }
    window.sendEvent(event)
}

/// Runs `trigger` (a click) and reads the popup's items while its menu is
/// tracking, then cancels. nil means tracking never began: the click did nothing.
@MainActor
private func trackMenu(of popup: NSPopUpButton, trigger: () -> Void) -> [NSMenuItem]? {
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
    trigger()
    return items
}

private func windowPoint(of view: NSView) -> NSPoint {
    view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
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
private func checkHistoryTimescaleMenu() throws {
    let anchor = ISO8601DateFormatter().date(from: "2024-03-15T12:00:00Z")!
    let probe = NavigationProbe(CalendarNavigation(timezoneID: "UTC", anchor: anchor, scale: .month))
    let (window, host) = hostedWindow(NavigationProbeView(probe: probe), size: NSSize(width: 420, height: 160))
    defer { window.contentView = nil; window.close() }

    let popups = popupButtons(in: host)
    guard let scalePopup = popups.first, popups.count == 2 else {
        throw HistoryInteractionSmokeError.failed("Expected the timescale and control popups, found \(popups.count). Tree:\n\(describe(host))")
    }
    guard let opened = trackMenu(of: scalePopup, trigger: { scalePopup.performClick(nil) }) else {
        throw HistoryInteractionSmokeError.failed("Clicking History's timescale popup never began menu tracking. Tree:\n\(describe(host))")
    }
    let titles = CalendarScale.allCases.map(\.title)
    guard titles.allSatisfy({ title in opened.contains { $0.title == title } }) else {
        throw HistoryInteractionSmokeError.failed("Timescale menu opened as \(opened.map(\.title)), missing some of \(titles)")
    }
    for scale in [CalendarScale.week, .year, .day, .month] {
        guard let index = scalePopup.menu?.items.firstIndex(where: { $0.title == scale.title }) else {
            throw HistoryInteractionSmokeError.failed("Timescale menu has no \(scale.title) item after a selection")
        }
        scalePopup.menu?.performActionForItem(at: index)
        settle(host)
        guard probe.navigation.scale == scale else {
            throw HistoryInteractionSmokeError.failed("Choosing \(scale.title) left History on \(probe.navigation.scale.title)")
        }
        guard probe.navigation.anchor == anchor else {
            throw HistoryInteractionSmokeError.failed("Choosing \(scale.title) moved History's anchor date")
        }
    }
    print("ui-smoke: History timescale menu opens under the dashboard's button style and each scale applies through its binding")
}

/// The full dashboard window: garden, frost, floating sidebar and transparent
/// title bar all share the window with History's controls.
@MainActor
private func checkTimescaleInDashboard(model: AppModel) throws {
    let window = DashboardWindow(contentRect: NSRect(x: 80, y: 80, width: 1180, height: 820),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: DashboardView(model: model, initialSection: .history, initialCalendarScale: .month))
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    settle(host, passes: 10)
    defer { window.contentView = nil; window.close() }

    let popups = popupButtons(in: host)
    guard let popup = popups.first(where: { textFields(in: $0).contains("Month") }) else {
        throw HistoryInteractionSmokeError.failed("No popup labelled Month in the dashboard (\(popups.count) popups). Tree:\n\(describe(host))")
    }
    let point = windowPoint(of: popup)
    // Whatever draws over the control decides whether a click reaches it.
    let hit = host.superview?.hitTest(host.superview!.convert(point, from: nil))
    var ancestor: NSView? = hit
    while let view = ancestor, view !== popup { ancestor = view.superview }
    guard ancestor === popup else {
        throw HistoryInteractionSmokeError.failed("A click on History's timescale control lands on \(hit.map { String(describing: type(of: $0)) } ?? "nothing") instead of the popup at \(point)")
    }
    let revision = ThemeStore.shared.revision
    var failures: [String] = []
    // Path 1: a real mouse-down must begin menu tracking (this is what a person does).
    if trackMenu(of: popup, trigger: { mouse(.leftMouseDown, at: point, in: window) }) == nil {
        failures.append("A real mouse-down on the timescale popup never began menu tracking")
    }
    mouse(.leftMouseUp, at: point, in: window)
    // Path 2: open it programmatically, then choose Week. If this fails but the same
    // steps pass outside the dashboard, something in the dashboard undoes the pick.
    // SwiftUI may replace the platform popup after a pick, so always look it up afresh.
    func labels() -> [[String]] { popupButtons(in: host).map { textFields(in: $0) } }
    func scaleLabelIs(_ title: String) -> Bool { labels().contains { $0.contains(title) } }
    var observed: [String] = []
    if let current = popupButtons(in: host).first(where: { textFields(in: $0).contains("Month") }) {
        let item = current.menu?.items.first(where: { $0.title == "Week" })
        observed.append("popups \(labels().count), Week item enabled \(String(describing: item?.isEnabled)), popup enabled \(current.isEnabled), key \(window.isKeyWindow), active \(NSApp.isActive)")
        guard trackMenu(of: current, trigger: { current.performClick(nil) }) != nil,
              let index = current.menu?.items.firstIndex(where: { $0.title == "Week" }) else {
            throw HistoryInteractionSmokeError.failed((failures + ["Dashboard timescale popup did not open with a Week item"]).joined(separator: " / "))
        }
        current.menu?.performActionForItem(at: index)
        observed.append("right after: \(labels())")
        _ = pump(timeout: 3, until: { scaleLabelIs("Week") })
        observed.append("settled: \(labels())")
    }
    guard scaleLabelIs("Week") else {
        failures.append("Choosing Week in the dashboard left the control reading \(labels()) (\(observed.joined(separator: "; ")); theme revision \(revision) → \(ThemeStore.shared.revision))")
        throw HistoryInteractionSmokeError.failed(failures.joined(separator: " / "))
    }
    if !failures.isEmpty { throw HistoryInteractionSmokeError.failed(failures.joined(separator: " / ")) }
    print("ui-smoke: the dashboard's timescale popup receives real clicks, opens, and applies a pick")
}

@MainActor
private func checkTimescalePublishes(model: AppModel) throws {
    var published: [HistoryAtlasKey] = []
    let view = HistoryView(model: model, initialScale: .month, benchmarkReady: { published.append($0) })
        .buttonStyle(ReadingButtonStyle())
        .frame(width: 1000, height: 800)
    let (window, host) = hostedWindow(view, size: NSSize(width: 1000, height: 800))
    defer { window.contentView = nil; window.close() }
    guard pump(until: { published.contains { $0.scale == .month } }) else {
        throw HistoryInteractionSmokeError.failed("History never published its initial month")
    }
    guard let popup = popupButtons(in: host).first(where: { textFields(in: $0).contains("Month") }),
          let opened = trackMenu(of: popup, trigger: { popup.performClick(nil) }),
          let index = popup.menu?.items.firstIndex(where: { $0.title == "Week" }) else {
        throw HistoryInteractionSmokeError.failed("History's timescale popup did not open with a Week item")
    }
    _ = opened
    popup.menu?.performActionForItem(at: index)
    guard pump(until: { published.contains { $0.scale == .week } }) else {
        throw HistoryInteractionSmokeError.failed("Choosing Week never published a week chart; published \(published.map { $0.scale.rawValue })")
    }
    print("ui-smoke: picking a timescale publishes that scale's chart")
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

    // Narrow enough that the detail pane (with its own Open day button) sits
    // below the grid, so every click in the scanned band lands on a day cell.
    let size = NSSize(width: 640, height: 1_500)
    var opened: [Date] = []
    let (window, host) = hostedWindow(
        AtlasMonthView(navigation: navigation, presentation: presentation, select: { opened.append($0) })
            .frame(width: size.width, height: size.height, alignment: .top),
        size: size)
    defer { window.contentView = nil; window.close() }

    // Black-box scan: SwiftUI vends no per-cell NSViews, so click a lattice over
    // the grid. Cells are ~75 x 91 pt. Single clicks use a lattice coarser than a
    // cell so no two consecutive clicks share one (two clicks in a cell inside the
    // double-click interval are, correctly, a double-click).
    func lattice(_ dx: CGFloat, _ dy: CGFloat) -> [NSPoint] {
        stride(from: CGFloat(30), to: 640, by: dy).flatMap { top in
            stride(from: CGFloat(14), to: size.width, by: dx).map { NSPoint(x: $0, y: size.height - top) }
        }
    }
    for point in lattice(96, 104) {
        mouse(.leftMouseDown, at: point, in: window); mouse(.leftMouseUp, at: point, in: window)
    }
    settle(host)
    guard opened.isEmpty else {
        throw HistoryInteractionSmokeError.failed("Single clicks opened \(opened.count) days; a click must only select")
    }
    var pause: TimeInterval = 0
    for point in lattice(28, 28) {
        // Each pair is a separate gesture: leave more than the double-click interval between pairs.
        pause += 1
        for count in 1...2 {
            mouse(.leftMouseDown, at: point, in: window, count: count, after: pause)
            mouse(.leftMouseUp, at: point, in: window, count: count, after: pause)
        }
    }
    settle(host)
    let openedDays = Set(opened.map { calendar.component(.day, from: $0) })
    guard openedDays.contains(8), openedDays.count > 20 else {
        throw HistoryInteractionSmokeError.failed("Double-clicking across the grid opened days \(openedDays.sorted()); expected every cell, including the 8th")
    }

    // Accessibility: the open action must be exposed on each day. SwiftUI only
    // builds its accessibility tree for an active client, so report what exists.
    let label = DateText.string(readDay, zone: zone, pattern: "EEEE, MMMM d")
    let nodes = accessibilityNodes(host)
    guard let node = nodes.first(where: { $0.accessibilityLabel()?.hasPrefix(label) == true }) else {
        let labels = nodes.compactMap { $0.accessibilityLabel() }.prefix(12)
        throw HistoryInteractionSmokeError.failed("No accessibility element for \(label); tree has \(nodes.count) nodes, labels \(Array(labels))")
    }
    opened = []
    let actions = node.accessibilityCustomActions() ?? []
    guard let open = actions.first(where: { $0.name == "Open day" }), open.handler?() == true,
          opened.count == 1, calendar.isDate(opened[0], inSameDayAs: readDay) else {
        throw HistoryInteractionSmokeError.failed("\(label) has no working \"Open day\" accessibility action (found \(actions.map(\.name)))")
    }
    print("ui-smoke: month day ring selects on one click, opens on double-click, and exposes an Open day accessibility action")
}

// MARK: - Day view disclosures

/// "Session details" on every session card is a DisclosureGroup. Click a lattice over
/// the Day view and require that at least one expands: the view must grow.
@MainActor
private func checkDayDisclosures() throws {
    let zone = "UTC"
    let anchor = ISO8601DateFormatter().date(from: "2024-03-08T12:00:00Z")!
    let navigation = CalendarNavigation(timezoneID: zone, anchor: anchor, scale: .day)
    let book = BookRecord(id: "disclosure-book", title: "Disclosure")
    let interval = ReadingInterval(sessionID: "disclosure-0", bookID: book.id, start: anchor,
        end: anchor.addingTimeInterval(1_800), duration: 1_800, timezoneID: zone, mode: .manual)
    let source = HistoryAtlasSource(books: [book], intervals: [interval], events: [], progress: [], merges: [],
        finishedBooks: [], pageEvidence: PageStatistics.snapshot(events: [], effectiveIntervals: [interval], merges: []))
    let presentation = HistoryAtlasPeriod(source: source, navigation: navigation, now: anchor)
    let size = NSSize(width: 900, height: 1_100)
    let view = AtlasDayView(navigation: navigation, presentation: presentation, editSession: { _ in })
        .frame(width: size.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .buttonStyle(ReadingButtonStyle())
    let (window, host) = hostedWindow(view, size: size)
    defer { window.contentView = nil; window.close() }
    let before = host.fittingSize.height
    var pause: TimeInterval = 0
    for top in stride(from: CGFloat(20), to: 700, by: 24) {
        for x in stride(from: CGFloat(20), to: 500, by: 40) {
            let point = NSPoint(x: x, y: size.height - top)
            pause += 1
            mouse(.leftMouseDown, at: point, in: window, after: pause)
            mouse(.leftMouseUp, at: point, in: window, after: pause)
        }
    }
    settle(host)
    let after = host.fittingSize.height
    guard after > before + 20 else {
        throw HistoryInteractionSmokeError.failed("Clicking across the Day view expanded no \"Session details\" disclosure (height \(before) → \(after))")
    }
    print("ui-smoke: Day view session details expand under the dashboard's button style")
}
