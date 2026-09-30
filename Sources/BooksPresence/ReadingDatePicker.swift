import AppKit
import SwiftUI

/// Native segmented date editing inside the same field surface as the journal's text inputs.
struct ReadingDatePicker: View {
    let label: String
    @Binding var selection: Date
    var minimumDate: Date? = nil
    var maximumDate: Date? = nil
    var includesDate = true
    @Environment(\.isEnabled) private var isEnabled

    init(_ label: String, selection: Binding<Date>, minimumDate: Date? = nil,
         maximumDate: Date? = nil, includesDate: Bool = true) {
        self.label = label
        _selection = selection
        self.minimumDate = minimumDate
        self.maximumDate = maximumDate
        self.includesDate = includesDate
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.callout).foregroundStyle(ReadingPalette.ink)
            Spacer(minLength: 0)
            NativeReadingDateField(label: label, selection: $selection,
                minimumDate: minimumDate, maximumDate: maximumDate, includesDate: includesDate)
                .fixedSize()
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(ReadingPalette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(ReadingPalette.border, lineWidth: 1))
        }
        .opacity(isEnabled ? 1 : 0.42)
    }
}

private struct NativeReadingDateField: NSViewRepresentable {
    let label: String
    @Binding var selection: Date
    let minimumDate: Date?
    let maximumDate: Date?
    let includesDate: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerMode = .single
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.font = .systemFont(ofSize: 13)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        // Keep AppKit's focus ring and segmented keyboard editing.
        picker.focusRingType = .default
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.selection = $selection
        picker.datePickerElements = includesDate ? [.yearMonthDay, .hourMinute] : [.hourMinute]
        picker.locale = locale
        picker.calendar = calendar
        picker.timeZone = timeZone
        picker.minDate = minimumDate
        picker.maxDate = maximumDate
        if picker.dateValue != selection { picker.dateValue = selection }
        picker.isEnabled = isEnabled
        picker.textColor = NSColor(ReadingPalette.ink)
        picker.setAccessibilityLabel(label)
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject {
        var selection: Binding<Date>
        init(selection: Binding<Date>) { self.selection = selection }
        @objc func changed(_ picker: NSDatePicker) { selection.wrappedValue = picker.dateValue }
    }
}
