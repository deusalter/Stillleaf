import AppKit

private enum RecordedDateMenuSmokeError: Error { case failed(String) }

@MainActor
func checkRecordedDateMenu() throws {
    let button = RecordedDateMenuButton()
    let dates = [Date(timeIntervalSince1970: 1_700_100_000), Date(timeIntervalSince1970: 1_700_000_000)]
    var selected: Date?
    button.configure(dates: dates, timezoneID: "America/Los_Angeles", bookTitle: "Synthetic book", enabled: true) { selected = $0 }
    guard let menu = button.menu, menu.numberOfItems == 1, button.isEnabled else {
        throw RecordedDateMenuSmokeError.failed("Closed year menu eagerly populated its dates")
    }
    button.menuNeedsUpdate(menu)
    guard menu.numberOfItems == 3, let olderItem = menu.item(at: 2),
          olderItem.representedObject as? Date == dates[1], let action = olderItem.action else {
        throw RecordedDateMenuSmokeError.failed("Opening the menu did not populate exact dates")
    }
    // Dispatch through AppKit, as the native keyboard menu does.
    menu.performActionForItem(at: 2)
    guard selected == dates[1] else { throw RecordedDateMenuSmokeError.failed("Native date selection did not dispatch") }

    selected = nil
    button.configure(dates: [dates[0]], timezoneID: "UTC", bookTitle: "Updated book", enabled: true) { selected = $0 }
    NSApp.sendAction(action, to: olderItem.target, from: olderItem)
    guard selected == nil else { throw RecordedDateMenuSmokeError.failed("A removed date remained actionable while its menu tracked") }
    button.menuNeedsUpdate(menu)
    guard menu.numberOfItems == 2 else { throw RecordedDateMenuSmokeError.failed("Reopened menu retained stale dates") }
    menu.performActionForItem(at: 1)
    guard selected == dates[0] else { throw RecordedDateMenuSmokeError.failed("Updated date menu lost its action") }

    selected = nil
    button.configure(dates: dates, timezoneID: "UTC", bookTitle: "Disabled book", enabled: false) { selected = $0 }
    menu.performActionForItem(at: 1)
    guard selected == nil else { throw RecordedDateMenuSmokeError.failed("A disabled history chart dispatched a date action") }
    button.configure(dates: [], timezoneID: "UTC", bookTitle: "Empty book", enabled: true) { selected = $0 }
    guard !button.isEnabled else { throw RecordedDateMenuSmokeError.failed("An empty date menu remained enabled") }
    print("ui-smoke: native year menu lazily populates, dispatches exact dates, and rejects disabled/stale actions")
}
