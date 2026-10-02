import AppKit
import SwiftUI

/// One lightweight keyboard/VoiceOver button per chart row. The native menu
/// itself, date labels, and items exist only when someone opens this row.
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
final class RecordedDateMenuButton: NSButton {
    private var dates: [Date] = []
    private var timezoneID = "UTC"
    private var selectDate: (Date) -> Void = { _ in }
    private(set) var activeDateMenu: NSMenu?
    private static let disclosureImage = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)

    init() {
        super.init(frame: .zero)
        setButtonType(.momentaryPushIn)
        controlSize = .mini
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        isBordered = false
        image = Self.disclosureImage
        imagePosition = .imageTrailing
        focusRingType = .default
        target = self
        action = #selector(showDates(_:))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
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
        toolTip = "Open the menu of recorded days, pending days, and finish dates"
    }

    func prepareDateMenu() -> NSMenu? {
        guard isEnabled, !dates.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for date in dates {
            let item = NSMenuItem(title: AtlasStyle.date(date, zone: timezoneID, pattern: "EEEE, MMMM d, yyyy"),
                                  action: #selector(openDate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = date
            menu.addItem(item)
        }
        activeDateMenu = menu
        return menu
    }

    @objc private func showDates(_ sender: NSButton) {
        guard let menu = prepareDateMenu() else { return }
        defer { activeDateMenu = nil }
        // Anchoring to the control works for keyboard/VoiceOver activation too;
        // there need not be a pointer event or a pointer over this row.
        let anchor = NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY : bounds.minY)
        menu.popUp(positioning: nil, at: anchor, in: self)
    }

    @objc private func openDate(_ item: NSMenuItem) {
        guard isEnabled, let date = item.representedObject as? Date, dates.contains(date) else { return }
        selectDate(date)
    }
}
