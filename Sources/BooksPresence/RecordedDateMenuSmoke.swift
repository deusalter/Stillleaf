import AppKit

private enum RecordedDateMenuSmokeError: Error { case failed(String) }

@MainActor
func checkRecordedDateMenu() throws {
    let button = RecordedDateMenuButton()
    let dates = [Date(timeIntervalSince1970: 1_700_100_000), Date(timeIntervalSince1970: 1_700_000_000)]
    var selected: Date?
    button.configure(dates: dates, timezoneID: "America/Los_Angeles", bookTitle: "Synthetic book", enabled: true) { selected = $0 }
    guard button.activeDateMenu == nil, button.menu == nil, button.isEnabled else {
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
    button.configure(dates: [dates[0]], timezoneID: "UTC", bookTitle: "Updated book", enabled: true) { selected = $0 }
    NSApp.sendAction(action, to: olderItem.target, from: olderItem)
    guard selected == nil else { throw RecordedDateMenuSmokeError.failed("A removed date remained actionable while its menu tracked") }
    guard let updatedMenu = button.prepareDateMenu(), updatedMenu.numberOfItems == 1 else {
        throw RecordedDateMenuSmokeError.failed("Reopened menu retained stale dates")
    }
    updatedMenu.performActionForItem(at: 0)
    guard selected == dates[0] else { throw RecordedDateMenuSmokeError.failed("Updated date menu lost its action") }

    selected = nil
    button.configure(dates: dates, timezoneID: "UTC", bookTitle: "Disabled book", enabled: false) { selected = $0 }
    updatedMenu.performActionForItem(at: 0)
    guard selected == nil, button.prepareDateMenu() == nil else {
        throw RecordedDateMenuSmokeError.failed("A disabled history chart dispatched a date action or created a menu")
    }
    button.configure(dates: [], timezoneID: "UTC", bookTitle: "Empty book", enabled: true) { selected = $0 }
    guard !button.isEnabled, button.prepareDateMenu() == nil else {
        throw RecordedDateMenuSmokeError.failed("An empty date menu remained enabled")
    }
    print("ui-smoke: year menu allocates on demand, dispatches exact dates, and rejects disabled/stale actions")
}
