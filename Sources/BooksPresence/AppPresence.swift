import AppKit

/// Stillleaf lives in the menu bar, but while the dashboard or a reader is on screen it is an
/// ordinary app: Dock icon, menu bar, keyboard shortcuts, and a full-screen title bar the reader
/// can reveal. AppKit gives accessory apps none of these, so a full-screen reader had no way to
/// reach its close button.
@MainActor
enum AppPresence {
    /// Call before ordering a window front: the app must be regular when it activates, or it
    /// does not take the menu bar.
    static func willPresentWindow() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// Returns to menu-bar-only once no dashboard or reader window remains. Minimized windows
    /// count, since they live in the Dock; off-screen readers opened in the background do not.
    static func refresh(closing: NSWindow? = nil) {
        let open = NSApp.windows.contains { window in
            window !== closing && !(window is NSPanel) && window.styleMask.contains(.titled)
                && (window.isMiniaturized || (window.isVisible && window.screen != nil))
        }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    static func makeMainMenu(dashboardTarget: AnyObject, dashboardAction: Selector) -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title), holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            items.forEach(menu.addItem); holder.submenu = menu; main.addItem(holder)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        let dashboard = item("Dashboard", dashboardAction, "0"); dashboard.target = dashboardTarget
        _ = submenu("Stillleaf", [
            item("About Stillleaf", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Stillleaf", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Stillleaf", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = submenu("File", [item("Close", #selector(NSWindow.performClose(_:)), "w")])
        _ = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        _ = submenu("View", [item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            dashboard,
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window
        return main
    }
}
