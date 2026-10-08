import SwiftUI
import AppKit

private struct NativePreviewOpaque: EnvironmentKey { static let defaultValue: Bool? = nil }
private struct NativePreviewReduceMotion: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    var nativePreviewOpaque: Bool? { get { self[NativePreviewOpaque.self] } set { self[NativePreviewOpaque.self] = newValue } }
    var nativePreviewReduceMotion: Bool? {
        get { self[NativePreviewReduceMotion.self] }
        set { self[NativePreviewReduceMotion.self] = newValue }
    }
}

extension View {
    func nativePopoverSurface() -> some View { modifier(NativePopoverSurface()) }
    func nativeMenuSurface(hovering: Bool) -> some View { modifier(NativeMenuSurface(hovering: hovering)) }
    func nativeDashboardSidebarToggle(isCollapsed: Bool, toggle: @escaping () -> Void) -> some View {
        modifier(NativeDashboardSidebarToggle(isCollapsed: isCollapsed, toggle: toggle))
    }
}

private struct NativeDashboardSidebarToggle: ViewModifier {
    let isCollapsed: Bool
    let toggle: () -> Void

    func body(content: Content) -> some View {
        // The dashboard has no system split view, so this is the only sidebar
        // control on every macOS version.
        content
            .toolbar {
                ToolbarItem(id: "dashboard-sidebar-toggle", placement: .navigation) {
                    DashboardSidebarToggleButton(isCollapsed: isCollapsed, toggle: toggle)
                        .frame(width: 32, height: 28)
                }
            }
    }
}

/// An AppKit control keeps native toolbar focus, Return/Space activation and
/// the standard sidebar keyboard equivalent while SwiftUI owns visibility.
private struct DashboardSidebarToggleButton: NSViewRepresentable {
    let isCollapsed: Bool
    let toggle: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")!,
                              target: context.coordinator, action: #selector(Coordinator.performToggle))
        button.identifier = NSUserInterfaceItemIdentifier("dashboard-sidebar-toggle")
        button.setAccessibilityIdentifier("dashboard-sidebar-toggle")
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.keyEquivalent = "s"
        button.keyEquivalentModifierMask = [.command, .control]
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.toggle = toggle
        let title = isCollapsed ? "Show sidebar" : "Hide sidebar"
        button.toolTip = title
        button.setAccessibilityLabel(title)
    }

    func makeCoordinator() -> Coordinator { Coordinator(toggle: toggle) }

    final class Coordinator: NSObject {
        var toggle: () -> Void
        init(toggle: @escaping () -> Void) { self.toggle = toggle }
        @objc func performToggle() { toggle() }
    }
}

private struct NativeMenuSurface: ViewModifier {
    let hovering: Bool
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !(previewOpaque ?? opaque), contrast != .increased {
            content.glassEffect(.clear, in: .capsule)
                .overlay(Capsule().stroke(ReadingPalette.accent.opacity(hovering ? 0.24 : 0.14)))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content.background(ReadingPalette.surface, in: Capsule())
            .overlay(Capsule().stroke(ReadingPalette.accent.opacity(contrast == .increased ? 0.7 : (hovering ? 0.3 : 0.16))))
    }
}

/// The menu panel's shell: clear glass tinted from the theme, with a crisp rim
/// and a soft highlight. Text never sits on it directly; the cards do the work
/// (see `PanelGlass`), so the shell can stay light.
private struct NativePopoverSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ReadingMetrics.Radius.window, style: .continuous)
        let dark = colorScheme == .dark
        if (previewOpaque ?? opaque) || contrast == .increased {
            content.background(ReadingPalette.canvas, in: shape).overlay(rim(shape, dark: dark, solid: true))
        } else {
            clear(content, shape: shape, dark: dark).overlay(rim(shape, dark: dark, solid: false))
        }
    }

    @ViewBuilder private func clear(_ content: Content, shape: RoundedRectangle, dark: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.clear, in: shape).background(tint(shape, dark: dark))
        } else {
            content.background(tint(shape, dark: dark)).background { blur(shape) }
        }
        #else
        content.background(tint(shape, dark: dark)).background { blur(shape) }
        #endif
    }

    /// The theme canvas laid thinly over the desktop, with a wash of the accent from a corner.
    private func tint(_ shape: RoundedRectangle, dark: Bool) -> some View {
        ZStack {
            shape.fill(ReadingPalette.canvas.opacity(PanelGlass.shellTint(dark: dark)))
            shape.fill(LinearGradient(colors: [ReadingPalette.accent.opacity(dark ? 0.12 : 0.10), .clear],
                                      startPoint: .topTrailing, endPoint: UnitPoint(x: 0.4, y: 0.6)))
            shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.05 : 0.22), .white.opacity(0)],
                                      startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3)))
        }
    }

    /// Before macOS 26: a faint blur, mixed in at `PanelGlass.blurMix` so the desktop stays recognisable.
    private func blur(_ shape: RoundedRectangle) -> some View {
        DesktopBlur(material: .underWindowBackground).opacity(PanelGlass.blurMix).clipShape(shape)
    }

    private func rim(_ shape: RoundedRectangle, dark: Bool, solid: Bool) -> some View {
        ZStack {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.30 : 0.95), .white.opacity(dark ? 0.06 : 0.35)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            if solid { shape.strokeBorder(ReadingPalette.border, lineWidth: 1) }
        }
        .allowsHitTesting(false)
    }
}

/// Share sampling between adjacent controls without merging their shapes at rest.
struct ReadingGlassGroup<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    @ViewBuilder var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 4) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
