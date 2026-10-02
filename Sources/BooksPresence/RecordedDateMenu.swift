import AppKit
import SwiftUI

/// One native keyboard/VoiceOver destination per chart row. Date labels and
/// menu items are created only when this row's menu opens, not for the year.
struct RecordedDateMenu: NSViewRepresentable {
    let dates: [Date]
    let timezoneID: String
    let bookTitle: String
    let select: (Date) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> RecordedDateMenuButton { RecordedDateMenuButton() }

    func updateNSView(_ button: RecordedDateMenuButton, context: Context) {
        button.configure(dates: dates, timezoneID: timezoneID, bookTitle: bookTitle,
                         enabled: isEnabled, select: select)
    }
}

@MainActor
final class RecordedDateMenuButton: NSPopUpButton, NSMenuDelegate {
    private var dates: [Date] = []
    private var timezoneID = "UTC"
    private var selectDate: (Date) -> Void = { _ in }

    init() {
        super.init(frame: .zero, pullsDown: true)
        controlSize = .mini
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        isBordered = false
        focusRingType = .default
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        let dateMenu = NSMenu()
        dateMenu.autoenablesItems = false
        dateMenu.addItem(withTitle: "0 dates", action: nil, keyEquivalent: "")
        dateMenu.delegate = self
        menu = dateMenu
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(dates: [Date], timezoneID: String, bookTitle: String, enabled: Bool,
                   select: @escaping (Date) -> Void) {
        self.dates = dates
        self.timezoneID = timezoneID
        selectDate = select
        title = "\(dates.count) \(dates.count == 1 ? "date" : "dates")"
        isEnabled = enabled && !dates.isEmpty
        setAccessibilityLabel("Choose a recorded date for \(bookTitle)")
        toolTip = "Open a recorded day, pending day, or finish date"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // A pull-down's first item supplies its title; it is not a destination.
        menu.addItem(withTitle: "\(dates.count) \(dates.count == 1 ? "date" : "dates")", action: nil, keyEquivalent: "")
        for date in dates {
            let item = NSMenuItem(title: AtlasStyle.date(date, zone: timezoneID, pattern: "EEEE, MMMM d, yyyy"),
                                  action: #selector(openDate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = date
            menu.addItem(item)
        }
    }

    @objc private func openDate(_ item: NSMenuItem) {
        guard isEnabled, let date = item.representedObject as? Date, dates.contains(date) else { return }
        selectDate(date)
    }
}
