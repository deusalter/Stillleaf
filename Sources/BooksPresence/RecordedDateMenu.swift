import AppKit
import SwiftUI

/// Rows remain SwiftUI-only until activated. A native anchor and menu exist
/// only for the open row, keeping native view preferences out of year layout.
struct RecordedDateMenu: View {
    let dates: [Date]
    let timezoneID: String
    let bookTitle: String
    let select: (Date) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPresented = false
    @FocusState private var focused: Bool

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 4) {
                Text("\(dates.count) \(dates.count == 1 ? "date" : "dates")")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium)).accessibilityHidden(true)
            }.font(.caption2).foregroundStyle(ReadingPalette.secondaryInk)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focused($focused)
        .disabled(dates.isEmpty)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(focused ? ReadingPalette.accent : .clear, lineWidth: 2))
        .accessibilityLabel("Choose a recorded date for \(bookTitle)")
        .accessibilityHint("Opens recorded days, pending days, and finish dates")
        .background {
            if isPresented {
                RecordedDateMenuAnchor(dates: dates, timezoneID: timezoneID,
                                      enabled: isEnabled, select: select, dismiss: { isPresented = false })
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .onChange(of: isEnabled) { if !$0 { isPresented = false } }
    }
}

private struct RecordedDateMenuAnchor: NSViewRepresentable {
    let dates: [Date]
    let timezoneID: String
    let enabled: Bool
    let select: (Date) -> Void
    let dismiss: () -> Void

    func makeNSView(context: Context) -> RecordedDateMenuAnchorView { RecordedDateMenuAnchorView() }

    func updateNSView(_ view: RecordedDateMenuAnchorView, context: Context) {
        view.configure(dates: dates, timezoneID: timezoneID, enabled: enabled,
                       select: select, dismiss: dismiss)
    }

    static func dismantleNSView(_ view: RecordedDateMenuAnchorView, coordinator: ()) {
        view.activeDateMenu?.cancelTracking()
    }
}

@MainActor
final class RecordedDateMenuAnchorView: NSView {
    private var dates: [Date] = []
    private var timezoneID = "UTC"
    private var selectDate: (Date) -> Void = { _ in }
    private var dismiss: () -> Void = { }
    private var scheduled = false
    private var didPresent = false
    private(set) var isMenuEnabled = false
    private(set) var activeDateMenu: NSMenu?

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(dates: [Date], timezoneID: String, enabled: Bool,
                   select: @escaping (Date) -> Void, dismiss: @escaping () -> Void = {}) {
        let changed = self.dates != dates || self.timezoneID != timezoneID
        self.dates = dates
        self.timezoneID = timezoneID
        selectDate = select
        self.dismiss = dismiss
        isMenuEnabled = enabled && !dates.isEmpty
        if changed || !isMenuEnabled { activeDateMenu?.cancelTracking() }
        schedulePresentation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { activeDateMenu?.cancelTracking() }
        else { schedulePresentation() }
    }

    override func layout() {
        super.layout()
        schedulePresentation()
    }

    private func schedulePresentation() {
        guard window != nil, !scheduled, !didPresent else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard self.window != nil, !self.bounds.isEmpty, !self.didPresent else { return }
            self.didPresent = true
            self.showDates()
        }
    }

    func prepareDateMenu() -> NSMenu? {
        guard isMenuEnabled, !dates.isEmpty else { return nil }
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

    private func showDates() {
        defer {
            activeDateMenu = nil
            // Cancellation can originate in updateNSView/dismantle. Publish
            // dismissal on the next turn, after that SwiftUI update finishes.
            let dismiss = dismiss
            DispatchQueue.main.async { dismiss() }
        }
        guard let menu = prepareDateMenu() else { return }
        // Anchoring to the control works for keyboard/VoiceOver activation too;
        // there need not be a pointer event or a pointer over this row.
        let anchor = NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY : bounds.minY)
        menu.popUp(positioning: nil, at: anchor, in: self)
    }

    @objc private func openDate(_ item: NSMenuItem) {
        guard isMenuEnabled, let date = item.representedObject as? Date, dates.contains(date) else { return }
        selectDate(date)
    }
}
