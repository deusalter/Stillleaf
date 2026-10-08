import SwiftUI
import BooksCore

// The sheet's few controls with no shared equivalent in GlassControls.swift: a quick-choice chip and a
// time-of-day / length stepper. The stepper sits on the shared glass well so it matches the number field.

/// A selectable capsule for a short list of quick choices (durations, days).
struct ManualChip: View {
    let title: String
    var systemImage: String? = nil
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
                Text(title)
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? ReadingPalette.onAccent : ReadingPalette.ink)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background {
                Capsule().fill(isSelected ? ReadingPalette.accent : ReadingPalette.surface.opacity(hovering ? 1 : 0.7))
            }
            .overlay(Capsule().stroke(isSelected ? .clear : ReadingPalette.accent.opacity(hovering ? 0.35 : 0.18), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : ReadingMotion.hover, value: hovering)
        .animation(reduceMotion ? nil : ReadingMotion.selection, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// − value + in one glass well. The value is whatever the caller supplies, so it can be an editable field.
struct ManualStepper<Value: View>: View {
    let decrementLabel: String
    let incrementLabel: String
    var outline: Color? = nil
    var outlineWidth: CGFloat = 1
    let decrement: () -> Void
    let increment: () -> Void
    @ViewBuilder let value: Value

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", label: decrementLabel, action: decrement)
            value.frame(minWidth: 78).multilineTextAlignment(.center)
            stepButton("plus", label: incrementLabel, action: increment)
        }
        .padding(3)
        .glassWell(Capsule(), outline: outline, outlineWidth: outlineWidth)
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 28).contentShape(Capsule())
        }
        .buttonStyle(ManualStepButtonStyle())
        .accessibilityLabel(label)
    }
}

private struct ManualStepButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ReadingPalette.ink)
            .background(Capsule().fill(ReadingPalette.accent.opacity(configuration.isPressed ? 0.28 : (hovering && isEnabled ? 0.16 : 0))))
            .opacity(isEnabled ? 1 : 0.32)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : ReadingMotion.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : ReadingMotion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// A time of day you can type ("7:42 pm") or nudge by five minutes.
struct ClockField: View {
    let label: String
    @Binding var clock: ManualEntryParsing.Clock
    let zone: TimeZone
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        ManualStepper(decrementLabel: "Five minutes earlier", incrementLabel: "Five minutes later",
                      outline: invalid ? ReadingPalette.warning : (focused ? ReadingPalette.accent : nil),
                      outlineWidth: invalid || focused ? 1.5 : 1,
                      decrement: { clock = ManualEntryDraft.shifted(clock, minutes: -5) },
                      increment: { clock = ManualEntryDraft.shifted(clock, minutes: 5) }) {
            TextField("", text: $text).textFieldStyle(.plain).focused($focused)
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .accessibilityLabel(label)
                .onSubmit(commit)
        }
        .onAppear { text = ManualEntryDraft.clockText(clock, zone: zone) }
        .onChange(of: clock) { value in
            text = ManualEntryDraft.clockText(value, zone: zone); invalid = false
        }
        .onChange(of: focused) { isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        if let parsed = ManualEntryParsing.clock(text) { invalid = false; clock = parsed }
        else if !text.isEmpty { invalid = true; return }
        text = ManualEntryDraft.clockText(clock, zone: zone)
    }
}
