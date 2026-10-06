import SwiftUI
import AppKit

// Reusable glass controls: a sliding-indicator segmented control, an inline
// editable number field with a joined stepper, a switch and a disclosure row.
// They sit inside glass cards, so they are inset "wells" rather than a second
// layer of glass, and each one honours Reduce Motion, Reduce Transparency and
// Increased Contrast. Nothing here knows about Settings.

// MARK: - Well surface

/// A recessed control surface for use inside a glass card.
private struct GlassWell: ViewModifier {
    let shape: GlassWellShape
    var tint: Color? = nil
    var outline: Color? = nil
    var outlineWidth: CGFloat = 1
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        let opaque = (previewOpaque ?? reduceTransparency) || contrast == .increased
        content
            .background {
                if opaque { shape.fill(ReadingPalette.surface) }
                else { shape.fill(tint ?? ReadingPalette.ink.opacity(dark ? 0.12 : 0.06)) }
            }
            .overlay {
                if let outline { shape.stroke(outline, lineWidth: outlineWidth) }
                else {
                    shape.stroke(LinearGradient(
                        colors: [ReadingPalette.ink.opacity(dark ? 0.20 : 0.16), ReadingPalette.ink.opacity(dark ? 0.08 : 0.06)],
                        startPoint: .top, endPoint: .bottom), lineWidth: contrast == .increased ? 1.5 : 1)
                }
            }
    }
}

/// A small type eraser so one well modifier serves capsules and rounded rectangles.
struct GlassWellShape: Shape {
    private let build: (CGRect) -> Path
    init<S: Shape>(_ shape: S) { build = { shape.path(in: $0) } }
    func path(in rect: CGRect) -> Path { build(rect) }
}

extension View {
    /// The recessed surface used by glass controls inside a card.
    func glassWell<S: Shape>(_ shape: S = Capsule(), tint: Color? = nil, outline: Color? = nil, outlineWidth: CGFloat = 1) -> some View {
        modifier(GlassWell(shape: GlassWellShape(shape), tint: tint, outline: outline, outlineWidth: outlineWidth))
    }
}

// MARK: - Segmented control

/// One choice from a few, with a selection pill that slides between segments.
///
/// - `.value` marks a value choice (Pages or Minutes) with a solid accent pill.
/// - `.navigation` switches a page's category and uses the same quiet accent tint
///   as the dashboard sidebar, so a screen of tabs does not shout.
struct GlassSegmentedControl<Value: Hashable>: View {
    enum Style { case value, navigation }

    let label: String
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var systemImage: ((Value) -> String)? = nil
    var style: Style = .value
    /// Segments share the width equally (a value choice). Navigation sizes to its labels.
    var equalWidth = true
    /// A small dot on a segment, such as unsaved changes in that category.
    var marker: ((Value) -> Bool)? = nil
    var markerLabel = "Unsaved changes"
    /// The control floats on the page (over the garden) instead of sitting inside a card,
    /// so its track is a glass surface rather than an inset well.
    var onGlass = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativePreviewReduceMotion) private var previewReduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Value?
    @Namespace private var pill

    var body: some View {
        let motionOff = previewReduceMotion ?? reduceMotion
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(3)
        .modifier(SegmentedTrack(onGlass: onGlass))
        .animation(motionOff ? nil : ReadingMotion.selection, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .onMoveCommand { direction in
            guard direction == .left || direction == .right,
                  let index = options.firstIndex(of: focused ?? selection) else { return }
            if let next = Self.neighbour(of: index, count: options.count, forward: direction == .right) {
                selection = options[next]; focused = selection
            }
        }
    }

    /// The segment a Left/Right press moves to; `nil` at either end.
    static func neighbour(of index: Int, count: Int, forward: Bool) -> Int? {
        let next = index + (forward ? 1 : -1)
        return (0..<count).contains(next) ? next : nil
    }

    private func segment(_ option: Value) -> some View {
        let selected = selection == option
        let prominent = style == .value
        let foreground: Color = selected ? (prominent ? ReadingPalette.onAccent : ReadingPalette.ink) : ReadingPalette.secondaryInk
        return Button { selection = option } label: {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage(option)).font(.system(size: 12, weight: .medium)).accessibilityHidden(true)
                }
                Text(title(option)).lineLimit(1)
                if marker?(option) == true {
                    Circle().fill(ReadingPalette.accent).frame(width: 6, height: 6)
                        .accessibilityLabel(markerLabel)
                }
            }
            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(maxWidth: equalWidth ? .infinity : nil, minHeight: 28)
            .background {
                if selected {
                    Capsule()
                        .fill(prominent ? ReadingPalette.accent : ReadingPalette.accent.opacity(0.26))
                        .overlay(Capsule().stroke(ReadingPalette.accent.opacity(prominent ? 0 : 0.35), lineWidth: 1))
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focused, equals: option)
        .overlay(Capsule().stroke(focused == option ? ReadingPalette.accent : .clear, lineWidth: 2))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct SegmentedTrack: ViewModifier {
    let onGlass: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if onGlass { content.glassSurface(cornerRadius: 20) } else { content.glassWell(Capsule()) }
    }
}

// MARK: - Number field with stepper

/// The arithmetic behind `GlassNumberField`, kept apart from the view so it can be tested.
enum GlassNumber {
    /// Digits only, at most `maxLength` of them, so a field can't hold "abc" or a sign.
    static func sanitize(_ text: String, maxLength: Int) -> String {
        String(text.filter(\.isNumber).prefix(maxLength))
    }

    /// The value one step away, clamped to `range`. An empty or unparsable field steps from the lower bound.
    static func stepped(_ text: String, by delta: Int, in range: ClosedRange<Int>) -> Int {
        guard let value = Int(text) else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, value + delta))
    }

    static func isValid(_ text: String, in range: ClosedRange<Int>) -> Bool {
        Int(text).map(range.contains) ?? false
    }

    static func maxLength(for range: ClosedRange<Int>) -> Int { String(range.upperBound).count }
}

/// An editable number with a unit and joined − / + buttons in one glass capsule.
/// Click the value to type; Up and Down step; hold Shift to step by ten.
/// The draft stays a string so an empty or out-of-range value can be shown and
/// rejected by the form instead of being silently corrected.
struct GlassNumberField: View {
    let label: String
    let unit: String
    @Binding var text: String
    let range: ClosedRange<Int>
    var step = 1
    var shiftStep = 10
    var onCommit: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    private var valid: Bool { GlassNumber.isValid(text, in: range) }
    /// The parsed value when it is in range; nil while the field is empty or out of range.
    private var current: Int? { valid ? Int(text) : nil }

    var body: some View {
        let outline: Color = focused ? ReadingPalette.accent : (valid ? ReadingPalette.ink.opacity(0.14) : ReadingPalette.warning)
        HStack(spacing: 0) {
            stepButton(symbol: "minus", delta: -1, atBound: current.map { $0 <= range.lowerBound } ?? false)
            HStack(spacing: 5) {
                TextField(label, text: $text)
                    .textFieldStyle(.plain)
                    .font(ReadingType.numeral(15).weight(.medium))
                    .multilineTextAlignment(.trailing)
                    .frame(width: CGFloat(GlassNumber.maxLength(for: range)) * 9.5 + 10)
                    .focused($focused)
                    .onSubmit(onCommit)
                    .onChange(of: text) { value in
                        let clean = GlassNumber.sanitize(value, maxLength: GlassNumber.maxLength(for: range))
                        if clean != value { text = clean }
                    }
                    .onMoveCommand { direction in
                        if direction == .up { nudge(+1) } else if direction == .down { nudge(-1) }
                    }
                    .accessibilityLabel(label)
                    .accessibilityValue(text.isEmpty ? "Empty" : "\(text) \(unit)")
                Text(unit).font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            stepButton(symbol: "plus", delta: 1, atBound: current.map { $0 >= range.upperBound } ?? false)
        }
        .padding(3)
        .glassWell(Capsule(), outline: outline, outlineWidth: focused || !valid ? 1.5 : 1)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.5)
        .animation(reduceMotion ? nil : ReadingMotion.hover, value: valid)
        .animation(reduceMotion ? nil : ReadingMotion.hover, value: focused)
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(+1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private func nudge(_ direction: Int) {
        let size = NSEvent.modifierFlags.contains(.shift) ? shiftStep : step
        text = String(GlassNumber.stepped(text, by: direction * size, in: range))
    }

    private func stepButton(symbol: String, delta: Int, atBound: Bool) -> some View {
        Button { nudge(delta) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(GlassStepButtonStyle())
        .disabled(atBound)
        .accessibilityLabel(delta > 0 ? "Increase \(label)" : "Decrease \(label)")
        .help(delta > 0 ? "Increase. Hold Shift for \(shiftStep)." : "Decrease. Hold Shift for \(shiftStep).")
    }
}

private struct GlassStepButtonStyle: ButtonStyle {
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

// MARK: - Switch

/// A glass switch: an inset track that fills with the accent, and a thumb that
/// slides. It is a single button for keyboard and VoiceOver, announced as On or Off.
struct GlassSwitch: View {
    let label: String
    @Binding var isOn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focused: Bool

    private static let trackSize = CGSize(width: 44, height: 26)
    private static let thumb: CGFloat = 20

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? ReadingPalette.accent : ReadingPalette.ink.opacity(0.14))
                    .overlay(Capsule().stroke(isOn ? ReadingPalette.accent : ReadingPalette.ink.opacity(contrast == .increased ? 0.6 : 0.22), lineWidth: 1))
                Circle()
                    // A light thumb in both appearances, so the off position stays visible on a dark track.
                    .fill(isOn ? ReadingPalette.onAccent : Color.white.opacity(0.94))
                    .overlay(Circle().stroke(Color.black.opacity(isOn ? 0 : 0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.22), radius: 1.5, x: 0, y: 1)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .padding(3)
            }
            .frame(width: Self.trackSize.width, height: Self.trackSize.height)
            .animation(reduceMotion ? nil : ReadingMotion.selection, value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .overlay(Capsule().stroke(focused ? ReadingPalette.accent : .clear, lineWidth: 2).padding(-3))
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        #if compiler(>=5.9)
        .modifier(SwitchTrait())
        #endif
    }
}

#if compiler(>=5.9)
private struct SwitchTrait: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.accessibilityAddTraits(.isToggle) } else { content }
    }
}
#endif

// MARK: - Disclosure

/// A disclosure row that lives inside a card. The header is a full-width button;
/// the content eases open and the chevron turns, unless Reduce Motion is on.
struct GlassDisclosure<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 10) {
                    if let systemImage {
                        Image(systemName: systemImage).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(ReadingPalette.accent).frame(width: 20).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.body.weight(.medium))
                        if let subtitle {
                            Text(subtitle).font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ReadingPalette.secondaryInk)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: ReadingMetrics.Radius.tight, style: .continuous)
                .stroke(focused ? ReadingPalette.accent : .clear, lineWidth: 2).padding(-3))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides the options" : "Shows the options")
            if isExpanded {
                content()
                    .padding(.top, ReadingMetrics.Space.m)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : ReadingMotion.selection, value: isExpanded)
    }
}
