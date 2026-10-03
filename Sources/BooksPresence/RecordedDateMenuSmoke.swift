import AppKit
import SwiftUI

private enum RecordedDateMenuSmokeError: Error { case failed(String) }

@MainActor
func checkRecordedDateMenu() throws {
    let button = RecordedDateMenuAnchorView()
    let dates = [Date(timeIntervalSince1970: 1_700_100_000), Date(timeIntervalSince1970: 1_700_000_000)]
    var selected: Date?
    button.configure(dates: dates, timezoneID: "America/Los_Angeles", enabled: true, select: { selected = $0 })
    guard button.activeDateMenu == nil, button.menu == nil, button.isMenuEnabled else {
        throw RecordedDateMenuSmokeError.failed("Closed year control eagerly created a native menu")
    }
    guard let menu = button.prepareDateMenu(), menu.numberOfItems == 2, let olderItem = menu.item(at: 1),
          olderItem.representedObject as? Date == dates[1], let action = olderItem.action else {
        throw RecordedDateMenuSmokeError.failed("Opening the menu did not populate exact dates")
    }
    // Dispatch through AppKit, as the native keyboard menu does.
    menu.performActionForItem(at: 1)
    guard selected == dates[1] else { throw RecordedDateMenuSmokeError.failed("Native date selection did not dispatch") }

    selected = nil
    button.configure(dates: [dates[0]], timezoneID: "UTC", enabled: true, select: { selected = $0 })
    NSApp.sendAction(action, to: olderItem.target, from: olderItem)
    guard selected == nil else { throw RecordedDateMenuSmokeError.failed("A removed date remained actionable while its menu tracked") }
    guard let updatedMenu = button.prepareDateMenu(), updatedMenu.numberOfItems == 1 else {
        throw RecordedDateMenuSmokeError.failed("Reopened menu retained stale dates")
    }
    updatedMenu.performActionForItem(at: 0)
    guard selected == dates[0] else { throw RecordedDateMenuSmokeError.failed("Updated date menu lost its action") }

    selected = nil
    button.configure(dates: dates, timezoneID: "UTC", enabled: false, select: { selected = $0 })
    updatedMenu.performActionForItem(at: 0)
    guard selected == nil, button.prepareDateMenu() == nil else {
        throw RecordedDateMenuSmokeError.failed("A disabled history chart dispatched a date action or created a menu")
    }
    button.configure(dates: [], timezoneID: "UTC", enabled: true, select: { selected = $0 })
    guard !button.isMenuEnabled, button.prepareDateMenu() == nil else {
        throw RecordedDateMenuSmokeError.failed("An empty date menu remained enabled")
    }
    try checkRecordedDateMenuLifecycle(dates: dates)
    print("ui-smoke: year menu allocates on activation, opens from its inserted anchor, cancels, dispatches exact dates, and rejects disabled/stale actions")
}

@MainActor
private func checkRecordedDateMenuLifecycle(dates: [Date]) throws {
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 180, height: 40),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let anchor = RecordedDateMenuAnchorView()
    anchor.frame = NSRect(x: 0, y: 0, width: 180, height: 40)
    var opened = false, dismissed = false, expired = false
    anchor.configure(dates: dates, timezoneID: "UTC", enabled: true, select: { _ in }, dismiss: { dismissed = true })
    let deadline = Date().addingTimeInterval(3)
    // Menus run a nested event-tracking loop. Schedule the bounded cancellation
    // in both modes so a failed assertion cannot leave a native menu hanging.
    let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
        MainActor.assumeIsolated {
            if Date() >= deadline {
                expired = true
                anchor.activeDateMenu?.cancelTracking()
            } else if anchor.activeDateMenu != nil {
                opened = true
                anchor.configure(dates: dates, timezoneID: "UTC", enabled: false,
                                 select: { _ in }, dismiss: { dismissed = true })
            }
        }
    }
    RunLoop.main.add(timer, forMode: .default)
    RunLoop.main.add(timer, forMode: .eventTracking)
    defer {
        timer.invalidate()
        anchor.activeDateMenu?.cancelTracking()
        window.contentView = nil
        window.close()
    }
    window.contentView = anchor
    window.makeKeyAndOrderFront(nil)
    anchor.layoutSubtreeIfNeeded()
    while !dismissed, !expired, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    guard opened, dismissed, !expired, anchor.activeDateMenu == nil else {
        throw RecordedDateMenuSmokeError.failed("Inserted date-menu anchor did not open and dismiss after cancellation")
    }
}

@MainActor
private final class RecordedDateFocusProbeState: ObservableObject {
    @Published var requested = false
    var focused = false
    var selected: Date?
}

@MainActor
private struct RecordedDateFocusProbe: View {
    @ObservedObject var state: RecordedDateFocusProbeState
    @FocusState private var focused: Bool
    let dates: [Date]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Recorded dates").font(.headline)
            RecordedDateMenu(dates: dates, timezoneID: "UTC", bookTitle: "Keyboard focus fixture", select: { state.selected = $0 }) {
                HStack(spacing: 10) {
                    BookCoverView(book: nil, size: .compact)
                        .scaleEffect(0.62).frame(width: 33, height: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Keyboard focus fixture").font(.system(size: 13, weight: .medium)).lineLimit(3)
                            .multilineTextAlignment(.leading)
                        RecordedDateMenuCaption(count: dates.count)
                    }
                }.frame(width: 170, alignment: .leading)
            }.focused($focused)
            Text("Space opens the date menu. Escape closes it.").font(.caption)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(ReadingPalette.canvas).foregroundStyle(ReadingPalette.ink)
        .onChange(of: state.requested) { focused = $0 }
        .onChange(of: focused) { state.focused = $0 }
    }
}

/// The one focus binding is test-only. Captures use the actual window focus
/// engine and native Keyboard Navigation, enabled/restored by the CI wrapper.
/// No isFocused environment override changes the control's appearance.
@MainActor
func checkRecordedDateKeyboardFocus(directory: URL, dark: Bool) async throws {
    print("native-year-date-focus: Keyboard Navigation enabled=\(NSApp.isFullKeyboardAccessEnabled)")
    guard NSApp.isFullKeyboardAccessEnabled else {
        throw RecordedDateMenuSmokeError.failed("Enable Keyboard Navigation before launching the native focus check; use the preview wrapper that restores the runner preference afterward")
    }
    let state = RecordedDateFocusProbeState()
    let dates = [Date(timeIntervalSince1970: 1_700_100_000), Date(timeIntervalSince1970: 1_700_000_000)]
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 210),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Recorded date keyboard focus"
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentViewController = NSHostingController(rootView: RecordedDateFocusProbe(state: state, dates: dates))
    defer { window.contentViewController = nil; window.close() }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(nanoseconds: 120_000_000)
    window.makeFirstResponder(nil)
    let appearance = dark ? "dark" : "light"
    try await captureNativeWindow(window, to: directory.appendingPathComponent("year-date-unfocused-\(appearance).png"))
    state.requested = true
    try await Task.sleep(nanoseconds: 120_000_000)
    guard state.focused else {
        print("native-year-date-focus: keyWindow=\(window.isKeyWindow) responder=\(String(describing: window.firstResponder))")
        throw RecordedDateMenuSmokeError.failed("Date button did not accept actual keyboard focus with Keyboard Navigation enabled")
    }
    try await captureNativeWindow(window, to: directory.appendingPathComponent("year-date-focused-\(appearance).png"))

    func findAnchor(_ view: NSView?) -> RecordedDateMenuAnchorView? {
        guard let view else { return nil }
        if let anchor = view as? RecordedDateMenuAnchorView { return anchor }
        return view.subviews.lazy.compactMap { findAnchor($0) }.first
    }
    var opened = false, expired = false
    let deadline = Date().addingTimeInterval(3)
    let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
        MainActor.assumeIsolated {
            let anchor = findAnchor(window.contentView)
            if Date() >= deadline {
                expired = true
                anchor?.activeDateMenu?.cancelTracking()
            } else if !opened, anchor?.activeDateMenu != nil {
                opened = true
                if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    NSApp.postEvent(escape, atStart: true)
                }
            }
        }
    }
    RunLoop.main.add(timer, forMode: .default)
    RunLoop.main.add(timer, forMode: .eventTracking)
    defer { timer.invalidate(); findAnchor(window.contentView)?.activeDateMenu?.cancelTracking() }
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard let space = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else {
            throw RecordedDateMenuSmokeError.failed("Could not construct the keyboard focus check")
        }
        window.sendEvent(space)
    }
    while (!opened || findAnchor(window.contentView) != nil), !expired, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard opened, !expired, findAnchor(window.contentView) == nil, state.selected == nil, state.focused else {
        throw RecordedDateMenuSmokeError.failed("Focused date button did not open with Space and return focus after Escape")
    }
    print("native-year-date-focus: \(appearance) actual focus, Space opens, Escape cancels, focus retained")
}
