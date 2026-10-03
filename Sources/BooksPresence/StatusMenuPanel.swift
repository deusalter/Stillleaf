import AppKit
import QuartzCore

/// A reading sheet follows normal window modality: it stays open until Save or
/// Cancel, and its parent stops floating above other applications meanwhile.
@MainActor
final class StatusMenuPanel: NSPanel {
    var cancelHandler: (() -> Void)?
    var anchorGeometry: (() -> (anchor: NSRect, visibleFrame: NSRect)?)?
    private var pendingContentSize: NSSize?
    private var resizeScheduled = false
    private var presentationBeforeSheet: (level: NSWindow.Level, floating: Bool, collection: NSWindow.CollectionBehavior)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window === self { return true }
        return owns(window.sheetParent ?? window.parent)
    }

    func dismissAfterFocusLeaves() {
        // AppKit announces resignation before the new sheet/key window is
        // fully installed. Check the settled relationship on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.attachedSheet == nil,
                  !self.owns(NSApp.keyWindow) else { return }
            self.cancelHandler?()
        }
    }

    func dismissForOutsideClick(in window: NSWindow?) {
        // Native menus use their own high-level window rather than a child
        // window. Let AppKit finish menu tracking before handling dismissal.
        if let window, window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue { return }
        guard isVisible, attachedSheet == nil, !owns(window) else { return }
        cancelHandler?()
    }

    func dismissForApplicationDeactivation() {
        // An unfinished sheet remains a normal-level window when the user
        // switches applications. Ordering out an attached sheet can sever its
        // AppKit attachment, so it must not use the menu's dismissal path.
        if let sheet = attachedSheet {
            prepareForSheet()
            sheet.level = .normal
            return
        }
        guard isVisible || attachedSheet?.isVisible == true else { return }
        cancelHandler?()
    }

    func routeEscape(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 53, isVisible, attachedSheet == nil,
              owns(event.window ?? NSApp.keyWindow) else { return event }
        cancelHandler?()
        return nil
    }

    override func cancelOperation(_ sender: Any?) {
        guard attachedSheet == nil else { return }
        cancelHandler?()
    }

    @discardableResult
    func hideKeepingSheetDraft() -> Bool {
        guard attachedSheet == nil else { return false }
        orderOut(nil)
        return true
    }

    func showKeepingSheetDraft() {
        makeKeyAndOrderFront(nil)
        attachedSheet?.makeKeyAndOrderFront(nil)
    }

    func prepareForSheet() {
        if presentationBeforeSheet == nil {
            presentationBeforeSheet = (level, isFloatingPanel, collectionBehavior)
        }
        isFloatingPanel = false
        level = .normal
        collectionBehavior = []
        DispatchQueue.main.async { [weak self] in self?.attachedSheet?.level = .normal }
    }

    func scheduleContentSize(_ size: NSSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        pendingContentSize = size
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.applyPendingContentSize()
        }
    }

    func sheetDidEnd() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.attachedSheet == nil else { return }
            if !NSApp.isActive { self.cancelHandler?() }
            if let previous = self.presentationBeforeSheet {
                self.isFloatingPanel = previous.floating
                self.level = previous.level
                self.collectionBehavior = previous.collection
                self.presentationBeforeSheet = nil
            }
            self.applyPendingContentSize()
        }
    }

    func applyPendingContentSize(reduceMotion: Bool? = nil) {
        // Do not move the parent's attachment point while a form is open.
        // The delegate flushes the latest pending size when its sheet ends.
        guard attachedSheet == nil, let contentSize = pendingContentSize else { return }
        pendingContentSize = nil
        let size = frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        let target = targetFrame(size: size)
        guard abs(target.width - frame.width) > 0.5 || abs(target.height - frame.height) > 0.5 ||
                abs(target.minX - frame.minX) > 0.5 || abs(target.minY - frame.minY) > 0.5 else { return }
        if isVisible && !(reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
            // A single native frame animation interpolates origin and height
            // together. New targets retarget the animator; no stale completion
            // handler can move the window back to an earlier size.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(target, display: true)
            }
        } else {
            setFrame(target, display: true)
        }
    }

    func positionAtAnchor() {
        guard attachedSheet == nil else { return }
        applyPendingContentSize(reduceMotion: true)
        setFrame(targetFrame(size: frame.size), display: true)
    }

    private func targetFrame(size: NSSize) -> NSRect {
        guard let geometry = anchorGeometry?() else {
            return NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        }
        return Self.anchoredFrame(size: size, anchor: geometry.anchor, visibleFrame: geometry.visibleFrame)
    }

    static func anchoredFrame(size: NSSize, anchor: NSRect, visibleFrame: NSRect) -> NSRect {
        let margin: CGFloat = 8
        let x = min(max(anchor.midX - size.width / 2, visibleFrame.minX + margin), visibleFrame.maxX - size.width - margin)
        let y = max(visibleFrame.minY + margin, anchor.minY - size.height - 6)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
