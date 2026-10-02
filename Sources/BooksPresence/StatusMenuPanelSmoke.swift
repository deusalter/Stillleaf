import AppKit

private enum StatusMenuPanelSmokeError: Error { case failed(String) }

@MainActor
private final class StatusMenuPanelSmokeDelegate: NSObject, NSWindowDelegate, NSApplicationDelegate {
    weak var panel: StatusMenuPanel?
    var applicationDeactivations = 0
    func windowDidResignKey(_ notification: Notification) { panel?.dismissAfterFocusLeaves() }
    func windowDidEndSheet(_ notification: Notification) { panel?.sheetDidEnd() }
    func windowWillBeginSheet(_ notification: Notification) { panel?.prepareForSheet() }
    func applicationDidResignActive(_ notification: Notification) {
        applicationDeactivations += 1
        panel?.dismissForApplicationDeactivation()
    }
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
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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
    func diagnosticState() -> String {
        "active=\(NSApp.isActive) panelVisible=\(panel.isVisible) sheetVisible=\(sheet.isVisible) " +
        "panelLevel=\(panel.level.rawValue) sheetLevel=\(sheet.level.rawValue) floating=\(panel.isFloatingPanel) " +
        "attached=\(panel.attachedSheet === sheet) sheetParent=\(sheet.sheetParent === panel) " +
        "panelKey=\(NSApp.keyWindow === panel) sheetKey=\(NSApp.keyWindow === sheet) " +
        "dismissals=\(dismissals) deactivationCallbacks=\(delegate.applicationDeactivations) " +
        "collection=\(panel.collectionBehavior.rawValue) draft=\(draft.stringValue)"
    }
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
    guard panel.isVisible, sheet.isVisible, panel.attachedSheet === sheet, dismissals == 0,
          !panel.hideKeepingSheetDraft(), draft.stringValue == "Synthetic unsaved reading title" else {
        throw StatusMenuPanelSmokeError.failed("Outside dismissal bypassed sheet modality or lost its draft")
    }
    guard panel.level == .normal, sheet.level == .normal, !panel.isFloatingPanel,
          !panel.collectionBehavior.contains(.canJoinAllSpaces) else {
        throw StatusMenuPanelSmokeError.failed("The reading sheet still floats at menu level")
    }
    NSApp.activate(ignoringOtherApps: true)
    let activationDeadline = Date().addingTimeInterval(2)
    while !NSApp.isActive && Date() < activationDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    guard NSApp.isActive else { throw StatusMenuPanelSmokeError.failed("Could not activate the synthetic panel for deactivation check") }
    print("status-menu-deactivation-before: \(diagnosticState())")
    let sheetSwitchCallbacks = delegate.applicationDeactivations
    try await switchStatusMenuSmokeToFinder()
    print("status-menu-deactivation-after-focus-transfer: \(diagnosticState())")
    let deactivationDeadline = Date().addingTimeInterval(2)
    while (NSApp.isActive || delegate.applicationDeactivations == sheetSwitchCallbacks) && Date() < deactivationDeadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard !NSApp.isActive, delegate.applicationDeactivations > sheetSwitchCallbacks,
          panel.level == .normal, sheet.level == .normal, !panel.isFloatingPanel,
          panel.attachedSheet === sheet, dismissals == 0,
          draft.stringValue == "Synthetic unsaved reading title" else {
        throw StatusMenuPanelSmokeError.failed("Application deactivation left a floating form or discarded its attached draft: \(diagnosticState())")
    }
    NSApp.activate(ignoringOtherApps: true)
    panel.showKeepingSheetDraft()
    let reactivationDeadline = Date().addingTimeInterval(2)
    while (!NSApp.isActive || !panel.isVisible || !sheet.isVisible) && Date() < reactivationDeadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard NSApp.isActive, panel.isVisible, sheet.isVisible, draft.stringValue == "Synthetic unsaved reading title" else {
        throw StatusMenuPanelSmokeError.failed("Returning to the application lost the attached reading draft")
    }
    panel.endSheet(sheet)
    sheet.orderOut(nil)
    panel.makeKeyAndOrderFront(nil)
    let sheetEndDeadline = Date().addingTimeInterval(2)
    while (panel.attachedSheet != nil || abs(panel.frame.height - 450) >= 1 || panel.level != .statusBar) && Date() < sheetEndDeadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard panel.attachedSheet == nil, abs(panel.frame.height - 450) < 1, panel.level == .statusBar, panel.isFloatingPanel,
          panel.collectionBehavior.contains(.canJoinAllSpaces) else {
        throw StatusMenuPanelSmokeError.failed("Closing the sheet did not restore menu presentation and deferred sizing")
    }
    let menuSwitchCallbacks = delegate.applicationDeactivations
    try await switchStatusMenuSmokeToFinder()
    let menuDismissalDeadline = Date().addingTimeInterval(2)
    while (panel.isVisible || delegate.applicationDeactivations == menuSwitchCallbacks) && Date() < menuDismissalDeadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard !NSApp.isActive, !panel.isVisible, delegate.applicationDeactivations > menuSwitchCallbacks else {
        throw StatusMenuPanelSmokeError.failed("Application deactivation no longer dismisses the ordinary menu")
    }
    NSApp.activate(ignoringOtherApps: true)
    panel.showKeepingSheetDraft()
    let menuActivationDeadline = Date().addingTimeInterval(2)
    while (!NSApp.isActive || !panel.isVisible) && Date() < menuActivationDeadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard NSApp.isActive, panel.isVisible else {
        throw StatusMenuPanelSmokeError.failed("Could not reactivate the ordinary menu for Escape check")
    }
    guard let panelEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53),
          panel.routeEscape(panelEscape) == nil, !panel.isVisible else {
        throw StatusMenuPanelSmokeError.failed("Escape no longer dismisses the menu itself")
    }
    let report: [String: Any] = ["sheetFocus": true, "sheetEscapePassthrough": true, "outsideClickPreservesModalDraft": true,
        "sheetUsesNormalWindowLevel": true, "coalescedSizing": true, "resizeRetargeting": true, "reduceMotion": true,
        "sheetDefersResize": true, "menuEscape": true, "applicationDeactivationRetainsDraft": true,
        "ordinaryMenuDeactivation": true, "menuPresentationRestored": true]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("status-menu-interactions.json"))
    print("status-menu-smoke: sheet modality, application switching, draft retention, Escape and anchored resize passed")
}

/// NSApp.deactivate() does not transfer foreground focus away from an active
/// sheet. Activate another real application, matching Command-Tab instead.
@MainActor
private func switchStatusMenuSmokeToFinder() async throws {
    let finder: NSRunningApplication
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
        finder = running
    } else {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        finder = try await NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), configuration: configuration)
    }
    guard finder.activate(options: [.activateIgnoringOtherApps]) else {
        throw StatusMenuPanelSmokeError.failed("Finder rejected foreground activation for the application-switch fixture")
    }
    let deadline = Date().addingTimeInterval(3)
    while (NSApp.isActive || !finder.isActive) && Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard !NSApp.isActive, finder.isActive else {
        throw StatusMenuPanelSmokeError.failed("Application focus did not transfer to Finder: stillleafActive=\(NSApp.isActive) finderActive=\(finder.isActive)")
    }
}
