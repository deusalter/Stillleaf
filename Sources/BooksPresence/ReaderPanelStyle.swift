import AppKit
import SwiftUI

// The reader's panels share one visual language: Contents, Search and Highlights are web
// dialogs styled by `panels.css`; the Appearance panel is native and styled here. The two
// use the same glass, header, rows, spacing and selection states, so they read as one family.

/// Colours for a reader panel, taken from the page theme the reader is currently showing.
struct ReaderPanelPalette {
    let panel: Color
    let ink: Color
    let accent: Color
    let dark: Bool

    /// Mirrors the web tokens in `panels.css`.
    var secondary: Color { ink.opacity(0.88) }
    var rim: Color { ink.opacity(0.18) }
    var hairline: Color { ink.opacity(0.12) }
    var hover: Color { ink.opacity(0.08) }
    var selected: Color { accent.opacity(0.18) }
    var field: Color { panel.opacity(0.6) }

    init(appearance: [String: Any]) {
        func rgb(_ hex: String?) -> (Double, Double, Double)? {
            guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
            return (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
        }
        func color(_ value: (Double, Double, Double)) -> Color { Color(.sRGB, red: value.0, green: value.1, blue: value.2, opacity: 1) }
        let background = rgb(appearance["panelColor"] as? String) ?? rgb(appearance["backgroundColor"] as? String) ?? (0.94, 0.97, 0.95)
        let text = rgb(appearance["textColor"] as? String) ?? (0.09, 0.24, 0.2)
        panel = color(background)
        ink = color(text)
        accent = rgb(appearance["accentColor"] as? String).map(color) ?? color(text)
        // Relative luminance decides the control scheme so system sliders and menus stay legible.
        func luminance(_ c: (Double, Double, Double)) -> Double {
            func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2)
        }
        dark = luminance(background) < 0.25
    }
}

private struct ReaderPaletteKey: EnvironmentKey {
    static let defaultValue = ReaderPanelPalette(appearance: [:])
}

extension EnvironmentValues {
    var readerPalette: ReaderPanelPalette {
        get { self[ReaderPaletteKey.self] }
        set { self[ReaderPaletteKey.self] = newValue }
    }
}

/// The glass behind every reader panel: a light tint over a clear blur, a crisp rim, and a top highlight.
/// Reduce Transparency and Increased Contrast make it the opaque theme colour.
private struct ReaderGlass: ViewModifier {
    @Environment(\.readerPalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ReadingMetrics.Radius.card, style: .continuous)
        let opaque = (previewOpaque ?? reduceTransparency) || contrast == .increased
        content
            .background(shape.fill(palette.panel.opacity(opaque ? 1 : 0.9)))
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [palette.dark ? .white.opacity(0.22) : .white.opacity(0.9), palette.rim],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(palette.rim, lineWidth: 0.5).allowsHitTesting(false)
            }
            .clipShape(shape)
    }
}

/// The panel frame: title and close button, a scrolling body and an optional footer.
struct ReaderPanelFrame<Content: View, Footer: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    @Environment(\.readerPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 30, height: 30).contentShape(Circle())
                }
                .buttonStyle(ReaderIconButtonStyle())
                .accessibilityLabel("Close \(title.lowercased())")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 20).padding(.trailing, 16).padding(.top, 16).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(palette.hairline).frame(height: 1)
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .foregroundStyle(palette.ink)
        .modifier(ReaderGlass())
    }
}

struct ReaderIconButtonStyle: ButtonStyle {
    @Environment(\.readerPalette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(palette.secondary)
            .background(Circle().fill(configuration.isPressed ? palette.hover : .clear))
            .hoverBackground(Circle(), palette.hover)
    }
}

private struct HoverBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    let color: Color
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.background(shape.fill(hovering ? color : .clear)).onHover { hovering = $0 }
    }
}

extension View {
    fileprivate func hoverBackground<S: InsettableShape>(_ shape: S, _ color: Color) -> some View { modifier(HoverBackground(shape: shape, color: color)) }
}

/// A titled group of controls, separated from the next group by a hairline.
struct ReaderPanelSection<Content: View>: View {
    let title: String
    var showsDivider = true
    @ViewBuilder let content: Content
    @Environment(\.readerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8)
                .foregroundStyle(palette.secondary).accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2).padding(.bottom, 22)
        .overlay(alignment: .bottom) { if showsDivider { Rectangle().fill(palette.hairline).frame(height: 1) } }
        .padding(.bottom, showsDivider ? 22 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A control's name on the left and its current value on the right.
struct ReaderControlLabel: View {
    let title: String
    var value: String?
    @Environment(\.readerPalette) private var palette
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            if let value { Text(value).font(.system(size: 12)).monospacedDigit().foregroundStyle(palette.secondary) }
        }
        .accessibilityHidden(true)
    }
}

/// A short set of exclusive choices, always visible. Used for Margins, Weight, Alignment and the like.
struct ReaderSegmented: View {
    let label: String
    let options: [(id: String, title: String)]
    let selection: String?
    let select: (String) -> Void
    @Environment(\.readerPalette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.id) { option in
                let on = option.id == selection
                Button { select(option.id) } label: {
                    Text(option.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 32).contentShape(Rectangle())
                }
                .buttonStyle(ReaderSegmentStyle(on: on))
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: ReadingMetrics.Radius.control, style: .continuous).fill(palette.hover))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

private struct ReaderSegmentStyle: ButtonStyle {
    let on: Bool
    @Environment(\.readerPalette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .foregroundStyle(on ? palette.ink : palette.secondary)
            .background(shape.fill(on ? palette.selected : .clear))
            .overlay(shape.strokeBorder(on ? palette.accent.opacity(0.45) : .clear, lineWidth: 1))
            .hoverBackground(shape, on ? .clear : palette.hover)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A larger, labelled choice with a drawn picture, like the Reading mode tiles.
struct ReaderTileChoice<Glyph: View>: View {
    let title: String
    let hint: String
    let on: Bool
    let select: () -> Void
    @ViewBuilder let glyph: Glyph
    @Environment(\.readerPalette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ReadingMetrics.Radius.control, style: .continuous)
        Button(action: select) {
            VStack(spacing: 7) {
                glyph.frame(height: 44).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.hover))
                Text(title).font(.system(size: 11, weight: on ? .semibold : .regular))
            }
            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 8)
            .foregroundStyle(on ? palette.ink : palette.secondary)
            .background(shape.fill(on ? palette.selected : .clear))
            .overlay(shape.strokeBorder(on ? palette.accent : palette.rim, lineWidth: on ? 1.5 : 1))
            .hoverBackground(shape, on ? .clear : palette.hover)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A slider with its name and value above it.
struct ReaderSliderRow: View {
    let title: String
    let valueText: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    @Environment(\.readerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ReaderControlLabel(title: title, value: valueText)
            // A stepped SwiftUI slider draws tick marks on macOS, so the step is applied to the value instead.
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, (($0 - range.lowerBound) / step).rounded() * step + range.lowerBound)) }), in: range)
                .tint(palette.accent)
                .accessibilityLabel(title).accessibilityValue(valueText)
        }
    }
}

/// A switch with its name on the left, like the web panel's Focus reading row.
struct ReaderToggleRow: View {
    let title: String
    let isOn: Binding<Bool>
    @Environment(\.readerPalette) private var palette
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).tint(palette.accent)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A collapsed-by-default group, for controls most readers never need.
struct ReaderDisclosure<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder let content: Content
    @Environment(\.readerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button { expanded.toggle() } label: {
                HStack {
                    Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(palette.secondary).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            .accessibilityHint("Shows more reading options")
            if expanded { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }
}

// MARK: - Popup window

/// A borderless panel that holds one reader panel under the toolbar. It replaces `NSPopover`,
/// whose system material is far milkier than the reader's glass and cannot be tuned.
@MainActor final class ReaderPopupPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

@MainActor final class ReaderPopup: NSObject {
    let panel: ReaderPopupPanel
    private let effect = NSVisualEffectView()
    private let container = NSView()
    private var size = NSSize(width: 380, height: 600)
    private weak var owner: NSWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// Set when a click landed on the control that opens this panel, so the same click does not reopen it.
    private(set) var swallowReopen = false
    var anchorHit: ((NSEvent) -> Bool)?
    var didShow: (() -> Void)?
    var didClose: (() -> Void)?

    var isShown: Bool { panel.isVisible }
    var window: NSWindow? { panel }
    var contentView: NSView? { container }
    var animates: Bool {
        get { panel.animationBehavior != .none }
        set { panel.animationBehavior = newValue ? .utilityWindow : .none }
    }

    override init() {
        panel = ReaderPopupPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.level = .normal
        panel.dismiss = { [weak self] in self?.close() }
        panel.setAccessibilityLabel("Appearance")
        container.wantsLayer = true
        container.layer?.cornerRadius = ReadingMetrics.Radius.card
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        // A light behind-window blur. The SwiftUI glass tints it, so little of the material's frost remains.
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)
        panel.contentView = container
    }

    func install<V: View>(_ root: V, size: NSSize) {
        self.size = size
        let host = NSHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        container.subviews.filter { $0 !== effect }.forEach { $0.removeFromSuperview() }
        container.addSubview(host)
        panel.setContentSize(size)
        container.frame = NSRect(origin: .zero, size: size)
        effect.frame = container.bounds; host.frame = container.bounds
    }

    func setDark(_ dark: Bool) { panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }

    func show(over owner: NSWindow) {
        guard !isShown else { return }
        self.owner = owner
        let area = owner.contentLayoutRect
        let height = min(size.height, max(260, area.height - 16))
        let anchor = owner.convertToScreen(NSRect(x: area.maxX - 12, y: area.maxY - 8, width: 0, height: 0)).origin
        panel.setContentSize(NSSize(width: size.width, height: height))
        panel.setFrameTopLeftPoint(NSPoint(x: anchor.x - size.width, y: anchor.y))
        effect.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        owner.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        installMonitors()
        didShow?()
    }

    func close() {
        guard isShown else { return }
        removeMonitors()
        let wasKey = panel.isKeyWindow
        owner?.removeChildWindow(panel)
        panel.orderOut(nil)
        if wasKey { owner?.makeKey() }
        didClose?()
    }

    func consumeReopenSuppression() -> Bool {
        defer { swallowReopen = false }
        return swallowReopen
    }

    private func installMonitors() {
        removeMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self, isShown, let hit = event.window, hit !== panel else { return event }
            // The colour panel and menus belong to this panel's controls.
            let name = String(describing: type(of: hit))
            if hit === NSColorPanel.shared || name.contains("Menu") || name.contains("Popup") { return event }
            if hit === owner, anchorHit?(event) == true {
                swallowReopen = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.swallowReopen = false }
            }
            close()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        localMonitor = nil; globalMonitor = nil; resignObserver = nil
    }
}
