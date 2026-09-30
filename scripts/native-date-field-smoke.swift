import AppKit
import SwiftUI

// Color-only fixture keeps this control semantics check independent of app startup.
// Production theme colors are checked by the offscreen UI previews.
enum ReadingPalette {
    static let ink = Color.primary
    static let surface = Color.gray
    static let border = Color.secondary
}

@main struct DateFieldSmoke {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var value = Date(timeIntervalSince1970: 1_700_000_000)
        let lower = value.addingTimeInterval(-1000), upper = value.addingTimeInterval(1000)
        let zone = TimeZone(identifier: "Asia/Kathmandu")!
        let root = VStack {
            ReadingDatePicker("Started listening", selection: Binding(get: { value }, set: { value = $0 }), minimumDate: lower, maximumDate: upper)
                .environment(\.locale, Locale(identifier: "en_GB")).environment(\.timeZone, zone)
            ReadingDatePicker("Time", selection: .constant(value), includesDate: false).disabled(true)
        }.padding(20).frame(width: 450, height: 150)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 150), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSDatePicker] {
            (view as? NSDatePicker).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let pickers = fields(host)
        precondition(pickers.count == 2)
        precondition(pickers.allSatisfy { host.bounds.contains($0.convert($0.bounds, to: host)) },
                     "Native date fields must fit the compact form viewport")
        let editable = pickers.first { $0.isEnabled }!
        let disabled = pickers.first { !$0.isEnabled }!
        precondition(editable.minDate == lower && editable.maxDate == upper)
        precondition(editable.locale?.identifier == "en_GB" && editable.timeZone == zone)
        precondition(editable.datePickerElements.contains(.yearMonthDay) && editable.datePickerElements.contains(.hourMinute))
        precondition(disabled.datePickerElements == [.hourMinute])
        precondition(editable.focusRingType == .default && !editable.isBezeled && !editable.drawsBackground)
        precondition(editable.accessibilityLabel() == "Started listening")
        let changed = value.addingTimeInterval(60)
        editable.dateValue = changed
        editable.sendAction(editable.action, to: editable.target)
        precondition(value == changed)
        precondition(!window.isVisible && !window.isKeyWindow)
        window.contentView = nil
        window.close()
        print("native-date-field: PASS range/locale/timezone/date+time/time-only/disabled/native-focus/action-binding, no visible window")
    }
}
