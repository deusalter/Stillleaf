import SwiftUI
import BooksCore
import BooksPlatform

// Small glass controls for the manual-entry sheet. They are deliberately self-contained so they can
// be swapped for the shared Settings segmented/stepper components when those land.

/// A glass track with a sliding accent pill behind the chosen option.
struct ManualSegmentedControl<Value: Hashable>: View {
    let label: String
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var systemImage: ((Value) -> String)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Value?
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = selection == option
                Button {
                    if reduceMotion { selection = option } else { withAnimation(ReadingMotion.selection) { selection = option } }
                } label: {
                    HStack(spacing: 6) {
                        if let systemImage { Image(systemName: systemImage(option)).accessibilityHidden(true) }
                        Text(title(option))
                    }
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .foregroundStyle(selected ? ReadingPalette.ink : ReadingPalette.secondaryInk)
                    .padding(.vertical, 8).frame(maxWidth: .infinity)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(ReadingPalette.accent.opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(ReadingPalette.accent.opacity(0.5), lineWidth: 1))
                                .matchedGeometryEffect(id: "pill", in: highlight)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .focused($focused, equals: option)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(focused == option ? ReadingPalette.accent : .clear, lineWidth: 2))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityLabel(title(option))
            }
        }
        .padding(3)
        .glassSurface(cornerRadius: 13)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .contain).accessibilityLabel(label)
        .onMoveCommand { direction in
            guard direction == .left || direction == .right,
                  let index = options.firstIndex(of: focused ?? selection) else { return }
            let next = min(options.count - 1, max(0, index + (direction == .right ? 1 : -1)))
            selection = options[next]; focused = selection
        }
    }
}

/// A selectable capsule for a short list of quick choices (durations, days).
struct GlassChip: View {
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

/// − value + on a glass capsule. The value is whatever view the caller supplies, so it can be an editable field.
struct GlassStepper<Value: View>: View {
    let decrementLabel: String
    let incrementLabel: String
    var canDecrement = true
    var canIncrement = true
    let decrement: () -> Void
    let increment: () -> Void
    @ViewBuilder let value: Value

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", label: decrementLabel, enabled: canDecrement, action: decrement)
            value.frame(minWidth: 78).multilineTextAlignment(.center)
            stepButton("plus", label: incrementLabel, enabled: canIncrement, action: increment)
        }
        .glassSurface(cornerRadius: 11)
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(ReadingPalette.border, lineWidth: 1))
    }

    private func stepButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(enabled ? ReadingPalette.accent : ReadingPalette.secondaryInk.opacity(0.5))
        .disabled(!enabled).accessibilityLabel(label)
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
        GlassStepper(decrementLabel: "Five minutes earlier", incrementLabel: "Five minutes later",
                     decrement: { clock = ManualEntryDraft.shifted(clock, minutes: -5) },
                     increment: { clock = ManualEntryDraft.shifted(clock, minutes: 5) }) {
            TextField("", text: $text).textFieldStyle(.plain).focused($focused)
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .accessibilityLabel(label)
                .onSubmit(commit)
        }
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(invalid ? ReadingPalette.warning : (focused ? ReadingPalette.accent : .clear), lineWidth: 1.5))
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

/// A result's cover, fetched through the search service and remembered for the session.
struct RemoteCover: View {
    let book: OutsideBook
    let service: BookSearchService
    @State private var image: NSImage?
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { CoverPlaceholder(title: book.title) }
        }
        .frame(width: 38, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(ReadingPalette.ink.opacity(0.13)))
        .task(id: book.key) {
            if let cached = Self.cache.object(forKey: book.key as NSString) { image = cached; return }
            guard book.coverURL != nil, let data = try? await service.coverData(for: book),
                  let loaded = NSImage(data: data), !Task.isCancelled else { return }
            Self.cache.setObject(loaded, forKey: book.key as NSString)
            image = loaded
        }
        .accessibilityHidden(true)
    }
}

struct CoverPlaceholder: View {
    let title: String
    var body: some View {
        ZStack {
            ReadingPalette.elevated
            HStack(spacing: 0) {
                Rectangle().fill(ReadingPalette.accent.opacity(0.3)).frame(width: 4)
                Spacer()
            }
            Image(systemName: "book.closed").font(.system(size: 13, weight: .light))
                .foregroundStyle(ReadingPalette.ink.opacity(0.6))
        }
    }
}
