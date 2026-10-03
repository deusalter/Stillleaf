import SwiftUI
import AppKit

private struct NativePreviewOpaque: EnvironmentKey { static let defaultValue: Bool? = nil }
private struct NativeNavigationBackdropInstalled: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var nativePreviewOpaque: Bool? { get { self[NativePreviewOpaque.self] } set { self[NativePreviewOpaque.self] = newValue } }
    fileprivate var nativeNavigationBackdropInstalled: Bool {
        get { self[NativeNavigationBackdropInstalled.self] }
        set { self[NativeNavigationBackdropInstalled.self] = newValue }
    }
}

private struct NativeSidebarSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque
    @ViewBuilder func body(content: Content) -> some View {
        if (previewOpaque ?? opaque) || contrast == .increased {
            content.background(ReadingPalette.canvas, in: RoundedRectangle(cornerRadius: 20))
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                // NavigationSplitView owns the glass on Tahoe. A second glass
                // effect here produces nested outlines and double refraction.
                content
            } else {
                content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
            #else
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            #endif
        }
    }
}

extension View {
    func nativeSidebarSurface() -> some View { modifier(NativeSidebarSurface()) }
    func nativePopoverSurface() -> some View { modifier(NativePopoverSurface()) }
    func nativeMenuSurface(hovering: Bool) -> some View { modifier(NativeMenuSurface(hovering: hovering)) }
    func nativeNavigationBackdrop() -> some View { modifier(NativeNavigationBackdrop()) }
    func nativeDashboardSidebarToggle(isCollapsed: Bool, toggle: @escaping () -> Void) -> some View {
        modifier(NativeDashboardSidebarToggle(isCollapsed: isCollapsed, toggle: toggle))
    }
}

private struct NativeDashboardSidebarToggle: ViewModifier {
    let isCollapsed: Bool
    let toggle: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .toolbar(removing: .sidebarToggle)
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

private struct NativeNavigationBackdrop: ViewModifier {
    @Environment(\.nativeNavigationBackdropInstalled) private var installed
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if installed { content }
            else { content.backgroundExtensionEffect().environment(\.nativeNavigationBackdropInstalled, true) }
        } else {
            content
        }
        #else
        content
        #endif
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
            content.glassEffect(.regular.tint(ReadingPalette.accent.opacity(hovering ? 0.12 : 0.08)), in: .capsule)
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

/// A text-heavy menu needs the system popover material, not a refracting glass
/// sheet over desktop text. Glass belongs to the controls above this surface.
private struct NativePopoverSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque

    @ViewBuilder func body(content: Content) -> some View {
        if (previewOpaque ?? opaque) || contrast == .increased {
            content.background(ReadingPalette.canvas, in: RoundedRectangle(cornerRadius: 20))
        } else {
            content.background {
                PopoverMaterial()
                    // Carry the same paper hue into the menu without a second
                    // refracting surface or desktop text showing through it.
                    .overlay(ReadingPalette.canvas.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
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
