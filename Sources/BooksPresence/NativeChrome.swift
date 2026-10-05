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

private struct NativeSidebarSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque
    @ViewBuilder func body(content: Content) -> some View {
        if (previewOpaque ?? opaque) || contrast == .increased {
            content.background(ReadingPalette.canvas, in: RoundedRectangle(cornerRadius: ReadingMetrics.Radius.window))
        } else {
            // Keep the system's single glass surface. A light theme tint
            // tempers wallpaper colour without adding a second blur layer.
            content.background(ReadingPalette.canvas.opacity(0.22), in: RoundedRectangle(cornerRadius: ReadingMetrics.Radius.window))
        }
    }
}

extension View {
    func nativeSidebarSurface() -> some View { modifier(NativeSidebarSurface()) }
    func nativePopoverSurface() -> some View { modifier(NativePopoverSurface()) }
    func nativeMenuSurface(hovering: Bool) -> some View { modifier(NativeMenuSurface(hovering: hovering)) }
    func nativeSidebarToolbar() -> some View { modifier(NativeSidebarToolbar()) }
    func nativeDashboardWindowBackground() -> some View { modifier(NativeDashboardWindowBackground()) }
    func nativeDashboardSidebarToggle(isCollapsed: Bool, toggle: @escaping () -> Void) -> some View {
        modifier(NativeDashboardSidebarToggle(isCollapsed: isCollapsed, toggle: toggle))
    }
}

private struct NativeDashboardWindowBackground: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // The detail column already paints its paper. Clear SwiftUI's
            // separate window-container fill so the native sidebar's glass
            // can sample the backdrop, just as the clear NSWindow allows.
            content.containerBackground(.clear, for: .window)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct NativeSidebarToolbar: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        // toolbar(removing:) needs the macOS 14 SDK, which ships with Swift 5.9.
        #if compiler(>=5.9)
        if #available(macOS 14.0, *) { content.toolbar(removing: .sidebarToggle) }
        else { content }
        #else
        content
        #endif
    }
}

private struct NativeDashboardSidebarToggle: ViewModifier {
    let isCollapsed: Bool
    let toggle: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .toolbar {
                    // A root navigation item stays ahead of the title. The
                    // system's split-view toggle migrates with its column.
                    ToolbarItem(id: "dashboard-sidebar-toggle", placement: .navigation) {
                        DashboardSidebarToggleButton(isCollapsed: isCollapsed, toggle: toggle)
                            .frame(width: 32, height: 28)
                    }
                }
        } else {
            // macOS 13 does not expose the default-item removal API. Keep its
            // native toggle rather than present duplicate controls there.
            content
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

/// Use clear glass for the menu shell rather than the strongly blurred popover
/// material. A neutral backing preserves themed text contrast over dark windows.
private struct NativePopoverSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque

    @ViewBuilder func body(content: Content) -> some View {
        if (previewOpaque ?? opaque) || contrast == .increased {
            content.background(ReadingPalette.canvas, in: RoundedRectangle(cornerRadius: ReadingMetrics.Radius.window))
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(.clear, in: .rect(cornerRadius: ReadingMetrics.Radius.window))
                    .background(ReadingPalette.canvas.opacity(0.68), in: RoundedRectangle(cornerRadius: ReadingMetrics.Radius.window))
            } else {
                fallback(content)
            }
            #else
            fallback(content)
            #endif
        }
    }

    private func fallback(_ content: Content) -> some View {
        content.background {
            PopoverMaterial().clipShape(RoundedRectangle(cornerRadius: ReadingMetrics.Radius.window, style: .continuous))
        }
    }
}

private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { }
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
