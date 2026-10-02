import AppKit

private enum StatusMenuPanelSmokeError: Error { case failed(String) }

@MainActor
private final class StatusMenuPanelSmokeDelegate: NSObject, NSWindowDelegate, NSApplicationDelegate {
    weak var panel: StatusMenuPanel?
    func windowDidResignKey(_ notification: Notification) { panel?.dismissAfterFocusLeaves() }
    func windowDidEndSheet(_ notification: Notification) { panel?.sheetDidEnd() }
    func applicationDidResignActive(_ notification: Notification) { panel?.dismissForApplicationDeactivation() }
}

/// Real AppKit windows exercise the same focus, event and sizing methods as the
/// status-item panel. The sheet contains only a synthetic editable draft.
@MainActor
func checkStatusMenuPanelInteractions(directory: URL) async throws {
    let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
    let anchor = NSRect(x: visible.midX - 10, y: visible.maxY, width: 20, height: 24)
    let panel = StatusMenuPanel(contentRect: NSRect(x: visible.midX, y: visible.midY, width: 350, height: 300),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.anchorGeometry = { (anchor, visible) }
    let delegate = StatusMenuPanelSmokeDelegate()
    let previousApplicationDelegate = NSApp.delegate
    delegate.panel = panel
    panel.delegate = delegate
    NSApp.delegate = delegate
    var dismissals = 0
    panel.cancelHandler = { [weak panel] in dismissals += 1; panel?.hideKeepingSheetDraft() }
    let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
        styleMask: [.titled], backing: .buffered, defer: false)
    sheet.isReleasedWhenClosed = false
    let draft = NSTextField(string: "Synthetic unsaved reading title")
    draft.frame = NSRect(x: 20, y: 60, width: 260, height: 24)
    sheet.contentView?.addSubview(draft)
    defer {
        NSApp.delegate = previousApplicationDelegate
        panel.delegate = nil
        panel.cancelHandler = nil
        if panel.attachedSheet != nil { panel.endSheet(sheet) }
        sheet.orderOut(nil); sheet.close(); panel.close()
    }

    // Several intrinsic-size notifications in one run-loop turn use only the
    // last target, and a hidden panel never needs an entrance resize animation.
    panel.scheduleContentSize(NSSize(width: 350, height: 330))
    panel.scheduleContentSize(NSSize(width: 350, height: 420))
    panel.scheduleContentSize(NSSize(width: 350, height: 390))
    try await Task.sleep(nanoseconds: 40_000_000)
    let expected = StatusMenuPanel.anchoredFrame(size: NSSize(width: 350, height: 390), anchor: anchor, visibleFrame: visible)
    guard abs(panel.frame.height - expected.height) < 1, abs(panel.frame.maxY - expected.maxY) < 1 else {
        throw StatusMenuPanelSmokeError.failed("Coalesced hidden sizing lost the newest size or top anchor")
    }
    panel.showKeepingSheetDraft()
    NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(nanoseconds: 80_000_000)
    dismissals = 0

    panel.scheduleContentSize(NSSize(width: 350, height: 440))
    panel.applyPendingContentSize(reduceMotion: false)
    try await Task.sleep(nanoseconds: 40_000_000)
    panel.scheduleContentSize(NSSize(width: 350, height: 410))
    panel.applyPendingContentSize(reduceMotion: false)
    try await Task.sleep(nanoseconds: 260_000_000)
    guard abs(panel.frame.height - 410) < 1, abs(panel.frame.maxY - expected.maxY) < 1 else {
        throw StatusMenuPanelSmokeError.failed("Retargeted resize drifted from the status-item anchor")
    }
    panel.scheduleContentSize(NSSize(width: 350, height: 390))
    panel.applyPendingContentSize(reduceMotion: true)
    guard abs(panel.frame.height - 390) < 1 else {
        throw StatusMenuPanelSmokeError.failed("Reduce Motion did not apply the resize immediately")
    }

    panel.beginSheet(sheet, completionHandler: nil)
    sheet.makeFirstResponder(draft)
    try await Task.sleep(nanoseconds: 180_000_000)
    guard panel.attachedSheet === sheet, panel.isVisible, dismissals == 0, panel.owns(sheet) else {
        throw StatusMenuPanelSmokeError.failed("Opening a reading sheet dismissed the status panel")
    }
    guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53),
          panel.routeEscape(escape) != nil, dismissals == 0 else {
        throw StatusMenuPanelSmokeError.failed("Escape was intercepted before the sheet could handle it")
    }
    panel.scheduleContentSize(NSSize(width: 350, height: 450))
    try await Task.sleep(nanoseconds: 40_000_000)
    guard abs(panel.frame.height - 390) < 1 else {
        throw StatusMenuPanelSmokeError.failed("The parent resized under an attached sheet")
    }
    panel.dismissForOutsideClick(in: sheet)
    guard dismissals == 0 else { throw StatusMenuPanelSmokeError.failed("A click inside the form dismissed it") }
    panel.dismissForOutsideClick(in: nil)
    guard !panel.isVisible, panel.attachedSheet === sheet, draft.stringValue == "Synthetic unsaved reading title" else {
        throw StatusMenuPanelSmokeError.failed("Outside dismissal lost the attached reading draft")
    }
    panel.showKeepingSheetDraft()
    try await Task.sleep(nanoseconds: 60_000_000)
    guard panel.isVisible, sheet.isVisible, draft.stringValue == "Synthetic unsaved reading title" else {
        throw StatusMenuPanelSmokeError.failed("Reopening failed to restore the reading sheet")
    }
    NSApp.activate(ignoringOtherApps: true)
    let activationDeadline = Date().addingTimeInterval(2)
    while !NSApp.isActive && Date() < activationDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    guard NSApp.isActive else { throw StatusMenuPanelSmokeError.failed("Could not activate the synthetic panel for deactivation check") }
    NSApp.deactivate()
    let deactivationDeadline = Date().addingTimeInterval(2)
    while panel.isVisible && Date() < deactivationDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    guard !panel.isVisible, !sheet.isVisible, panel.attachedSheet === sheet,
          draft.stringValue == "Synthetic unsaved reading title" else {
        throw StatusMenuPanelSmokeError.failed("Application deactivation left the panel floating or discarded its sheet draft")
    }
    NSApp.activate(ignoringOtherApps: true)
    panel.showKeepingSheetDraft()
    try await Task.sleep(nanoseconds: 80_000_000)
    guard panel.isVisible, sheet.isVisible, draft.stringValue == "Synthetic unsaved reading title" else {
        throw StatusMenuPanelSmokeError.failed("Reopening after application deactivation lost the draft")
    }
    panel.endSheet(sheet)
    sheet.orderOut(nil)
    panel.makeKeyAndOrderFront(nil)
    try await Task.sleep(nanoseconds: 260_000_000)
    guard abs(panel.frame.height - 450) < 1 else {
        throw StatusMenuPanelSmokeError.failed("Deferred sizing did not resume after the sheet closed")
    }
    guard let panelEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53),
          panel.routeEscape(panelEscape) == nil, !panel.isVisible else {
        throw StatusMenuPanelSmokeError.failed("Escape no longer dismisses the menu itself")
    }
    let report: [String: Any] = ["sheetFocus": true, "sheetEscapePassthrough": true, "outsideClickRetainsDraft": true,
        "reopenedDraft": true, "coalescedSizing": true, "resizeRetargeting": true, "reduceMotion": true,
        "sheetDefersResize": true, "menuEscape": true, "applicationDeactivationRetainsDraft": true]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("status-menu-interactions.json"))
    print("status-menu-smoke: sheet focus, Escape, outside/app dismissal, draft restoration and anchored resize passed")
}
