import AppKit

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
