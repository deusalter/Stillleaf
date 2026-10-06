import AppKit
import Combine
import SwiftUI
import BooksCore

/// Self-checks for what keeps text clear of the garden: the header clearing, bare text
/// on screens that draw over it, and a garden that follows Low Power Mode live.
/// Developer-only; nothing here is reachable from the shipping app's own flows.

private enum GardenSmokeError: Error { case failed(String) }

// MARK: Low Power Mode

@MainActor
func checkLowPowerIsLive() throws {
    let center = NotificationCenter()
    var lowPower = false
    let suite = "stillleaf-lowpower-smoke-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ThemeStore(defaults: defaults, lowPower: LowPowerSource(isEnabled: { lowPower }, center: center))
    var revisions = 0
    let subscription = store.$revision.dropFirst().sink { _ in revisions += 1 }
    defer { subscription.cancel() }
    let fail = { (message: String) in GardenSmokeError.failed("Low Power Mode: " + message) }

    guard store.effectiveGardenMode(reduceMotion: false) == .animated else { throw fail("an idle garden is not animated") }
    lowPower = true
    center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    // The reader window re-sends its garden mode when `revision` changes, so that is what must move.
    guard revisions == 1, store.effectiveGardenMode(reduceMotion: false) == .still else {
        throw fail("entering it did not still the garden and publish a change (revisions \(revisions))")
    }
    center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    guard revisions == 1 else { throw fail("a notification that changed nothing republished (revisions \(revisions))") }
    lowPower = false
    center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    guard revisions == 2, store.effectiveGardenMode(reduceMotion: false) == .animated else {
        throw fail("leaving it did not animate the garden again (revisions \(revisions))")
    }
    // A garden the user turned Still or Off has nothing to change, so it must not re-key every screen.
    for fixed in [GardenMode.still, .off] {
        store.select(garden: fixed)
        let before = revisions
        lowPower = true
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        lowPower = false
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        guard revisions == before, store.effectiveGardenMode(reduceMotion: false) == fixed else {
            throw fail("a \(fixed.rawValue) garden republished when Low Power Mode changed")
        }
    }
    print("ui-smoke: Low Power Mode changes reach the garden live and republish only when the mode really changes")
}

// MARK: Header clearing

/// The clearing the dashboard gives its garden and the banner height it measured, read
/// from the real view through its preferences.
@MainActor
private func dashboardClearing(_ model: AppModel, section: DashboardSection) -> (clearing: CGFloat, banner: CGFloat) {
    var clearing: CGFloat = 0, banner: CGFloat = 0
    let host = NSHostingView(rootView: DashboardView(model: model, initialSection: section)
        .onPreferenceChange(GardenClearingKey.self) { clearing = $0 }
        .onPreferenceChange(ErrorBannerHeightKey.self) { banner = $0 })
    host.frame = NSRect(x: 0, y: 0, width: 1060, height: 760)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    host.layoutSubtreeIfNeeded()
    return (clearing, banner)
}

@MainActor
func checkErrorBannerClearing(_ model: AppModel) throws {
    let message = "Could not save."
    // Laid out as the dashboard does: same button style, a width wide enough for one line.
    let standalone = NSHostingView(rootView: ErrorBanner(message: message, refresh: {}).buttonStyle(ReadingButtonStyle()).frame(width: 800))
    standalone.frame = NSRect(x: 0, y: 0, width: 800, height: 200)
    let expected = standalone.fittingSize.height
    guard expected > 20 else { throw GardenSmokeError.failed("The error banner measured \(expected) pt") }
    defer { model.errorMessage = nil }
    for section in [DashboardSection.today, .history, .library] {
        model.errorMessage = nil
        let resting = dashboardClearing(model, section: section)
        model.errorMessage = message
        let shown = dashboardClearing(model, section: section)
        guard resting.banner == 0, resting.clearing > 0, abs(shown.banner - expected) < 1 else {
            throw GardenSmokeError.failed("The \(section.rawValue) page measured an error banner of \(shown.banner) pt, not \(expected) pt")
        }
        guard abs(shown.clearing - resting.clearing - shown.banner) < 0.5 else {
            throw GardenSmokeError.failed("The \(section.rawValue) garden clearing went from \(resting.clearing) to \(shown.clearing) under a \(shown.banner) pt error banner")
        }
        model.errorMessage = nil
        guard dashboardClearing(model, section: section).clearing == resting.clearing else {
            throw GardenSmokeError.failed("The \(section.rawValue) garden clearing stayed taller after the error banner went away")
        }
    }
    print("ui-smoke: an error banner pushes the garden clearing down by its own height and back")
}

// MARK: Menu panel vine

/// The menu panel's vine has to stay in the padding beside its text column, measured in
/// points on the panel's real layout rather than in grid cells.
@MainActor
func checkPopoverVineClearsText() throws {
    let textRight = PopoverView.width - PopoverView.inset
    var grown = 0
    for height in [CGFloat(420), 520, 640] {
        for seed in UInt32(1)...UInt32(12) {
            var layout = PopoverView.gardenLayout(seed: seed)
            layout.size = CGSize(width: PopoverView.width, height: height)
            var panel = GardenModel.plant(layout)
            panel.growToCompletion(limit: 2_000)
            for cell in panel.cells.values {
                let left = Double(cell.x) * panel.cellWidth
                guard left >= Double(textRight) + 2 else {
                    throw GardenSmokeError.failed("A menu panel vine cell starts at \(left) pt, inside the text column that ends at \(textRight) pt (seed \(seed), height \(height))")
                }
            }
            grown += panel.cells.count
        }
    }
    guard grown > 100 else { throw GardenSmokeError.failed("The menu panel vine did not grow (\(grown) cells over 36 gardens)") }
    print("ui-smoke: the menu panel vine stays at least 2 pt right of its text column")
}

// MARK: Bare text over the garden

/// Finds text drawn straight over the garden. Every screen already keeps its text on
/// glass; this proves it from pixels, so a new bare `Text` cannot slip in unnoticed.
/// The theme's text colours are swapped for magenta, the screen is rendered with a
/// grown garden, and any magenta outside a glass panel and below the header clearing
/// is bare text. It lives entirely in self-test code, so release builds carry nothing.
@MainActor
private enum BareTextAudit {
    static let magenta: UInt32 = 0xFF00FF
    /// Every backing surface, so a control's own capsule can be told from open garden.
    static let cyan: UInt32 = 0x00FFFF

    struct Case {
        var name: String
        var view: AnyView
        /// Rendered without waiting, to catch a screen's loading state.
        var immediate = false
        /// The window; History cases are tall so content below the fold is drawn too.
        var size = CGSize(width: 1060, height: 760)
    }

    /// Sets the garden still and the text colours magenta for the duration of `body`.
    static func withAuditPalette<T>(_ body: () throws -> T) rethrows -> T {
        let suite = "stillleaf-bare-text-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        ThemeStore.shared.reload(from: defaults)
        ThemeStore.shared.select(garden: .still)
        let theme = ThemeStore.shared.theme
        func tinted(_ colors: ThemeColors) -> ThemeColors {
            var colors = colors
            colors.ink = magenta; colors.secondaryInk = magenta; colors.warning = magenta
            colors.surface = cyan; colors.elevated = cyan
            return colors
        }
        ThemeSnapshot.update(light: tinted(theme.light), dark: tinted(theme.dark))
        defer {
            ThemeStore.shared.reload(from: .standard)
            defaults.removePersistentDomain(forName: suite)
        }
        return try body()
    }

    /// Cells (in points) holding bare text, after dropping glass panels and the clearing.
    static func bareText(_ item: Case, dark: Bool) -> (cells: [CGRect], clearing: CGFloat, glass: Int, evidence: String) {
        let size = item.size
        var glass: [CGRect] = []
        var clearing: CGFloat = 0
        // Hosted like the real window, with animations off so a page's entrance has finished.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.appearance = appearance
        let root = item.view
            .environment(\.colorScheme, dark ? .dark : .light)
            .onPreferenceChange(GlassRegionsKey.self) { glass = $0 }
            .onPreferenceChange(GardenClearingKey.self) { clearing = $0 }
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(size)
        let host = controller.view
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = appearance
        defer { window.contentViewController = nil; window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        if !item.immediate { RunLoop.current.run(until: Date().addingTimeInterval(0.6)) }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return ([], clearing, glass.count, "") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // STILLLEAF_BARE_TEXT_DUMP=<folder> keeps every render, to see what was flagged.
        if let folder = ProcessInfo.processInfo.environment["STILLLEAF_BARE_TEXT_DUMP"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(item.name)-\(dark ? "dark" : "light").png"))
        }
        let flagged = cells(in: bitmap, size: size, glass: glass, clearing: clearing)
        return (flagged, clearing, glass.count, flagged.first.map { evidence(bitmap, size: size, around: $0, glass: glass, clearing: clearing) } ?? "")
    }

    /// What a failure needs to be diagnosed from a log alone: the glass panels and a crop of the render
    /// around the first flagged cell, as base64 PNG.
    private static func evidence(_ bitmap: NSBitmapImageRep, size: CGSize, around cell: CGRect, glass: [CGRect], clearing: CGFloat) -> String {
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let area = CGRect(x: max(0, cell.midX - 200), y: max(0, cell.midY - 70), width: 400, height: 160)
            .intersection(CGRect(origin: .zero, size: size))
        let pixels = CGRect(x: area.minX * scale, y: area.minY * scale, width: area.width * scale, height: area.height * scale)
        var text = "clearing \(Int(clearing)); glass " + glass.prefix(14).map { "[\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))]" }.joined(separator: " ")
        if let image = bitmap.cgImage?.cropping(to: pixels),
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            text += "\n    crop(\(Int(area.minX)),\(Int(area.minY))) png-base64: " + png.base64EncodedString()
        }
        return text
    }

    private static func cells(in bitmap: NSBitmapImageRep, size: CGSize, glass: [CGRect], clearing: CGFloat) -> [CGRect] {
        guard let data = bitmap.bitmapData, bitmap.samplesPerPixel >= 3, bitmap.bitsPerSample == 8 else { return [] }
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let stride = bitmap.bytesPerRow, step = bitmap.bitsPerPixel / 8
        let alphaFirst = bitmap.bitmapFormat.contains(.alphaFirst)
        let (rOffset, gOffset, bOffset) = alphaFirst ? (1, 2, 3) : (0, 1, 2)
        let cell: CGFloat = 16
        let columns = Int((size.width / cell).rounded(.up))
        var counts: [Int: Int] = [:]
        // Text on a control's own capsule: a surface colour lies close by in all four directions.
        let reach = Int(16 * scale)
        func surface(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else { return false }
            let p = y * stride + x * step
            return Int(data[p + rOffset]) < 130 && Int(data[p + gOffset]) > 140 && Int(data[p + bOffset]) > 140
        }
        func backed(_ x: Int, _ y: Int) -> Bool {
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                guard (1...reach).contains(where: { surface(x + dx * $0, y + dy * $0) }) else { return false }
            }
            return true
        }
        let firstRow = Int(clearing * scale)
        guard firstRow < bitmap.pixelsHigh else { return [] }
        for y in firstRow..<bitmap.pixelsHigh {
            let rowStart = y * stride
            for x in 0..<bitmap.pixelsWide {
                let p = rowStart + x * step
                let r = Int(data[p + rOffset]), g = Int(data[p + gOffset]), b = Int(data[p + bOffset])
                guard r > 215, b > 220, g < 90 else { continue }
                let point = CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale)
                if glass.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) { continue }
                let key = Int(point.y / cell) * columns + Int(point.x / cell)
                if counts[key, default: 0] >= 4 || backed(x, y) { continue }
                counts[key, default: 0] += 1
            }
        }
        return counts.filter { $0.value >= 4 }.keys.sorted().map { key in
            CGRect(x: CGFloat(key % columns) * cell, y: CGFloat(key / columns) * cell, width: cell, height: cell)
        }
    }

    /// A bare caption over a grown garden, and the same caption on a glass panel.
    static func control(onGlass: Bool) -> AnyView {
        let text = Text("Importing local audio and a longer line of text").font(.system(size: 20, weight: .semibold))
            .foregroundStyle(ReadingPalette.ink)
        let content: AnyView = onGlass ? AnyView(text.padding(24).glassSurface()) : AnyView(text)
        return AnyView(ZStack {
            GardenCanvas(layout: GardenLayout(clearingHeight: 0, seed: 11, roots: 9), mode: .still)
            content.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .coordinateSpace(name: GardenCanvas.space)
        .environment(\.gardenBackdrop, true))
    }
}

@MainActor
func checkBareTextOverGarden(populated: AppModel, emptyRoot: URL, defaults: UserDefaults) throws {
    let empty = try AppModel(support: emptyRoot, defaults: defaults, startTracking: false)
    defer { empty.shutdown() }
    var cases: [BareTextAudit.Case] = []
    func dashboard(_ model: AppModel, _ section: DashboardSection, scale: CalendarScale = .month) -> AnyView {
        AnyView(DashboardView(model: model, initialSection: section, initialCalendarScale: scale))
    }
    for section in DashboardSection.allCases {
        cases.append(.init(name: "\(section.rawValue)", view: dashboard(populated, section)))
    }
    // History is audited at full height, wide and at the narrowest window, where the day card
    // stacks under the calendar instead of sitting beside it.
    let tall = CGSize(width: 1060, height: 1500), narrow = CGSize(width: 920, height: 1700)
    for scale in CalendarScale.allCases {
        cases.append(.init(name: "history-\(scale.rawValue)-tall", view: dashboard(populated, .history, scale: scale), size: tall))
        cases.append(.init(name: "history-\(scale.rawValue)-narrow", view: dashboard(populated, .history, scale: scale), size: narrow))
    }
    for section in [DashboardSection.today, .history, .library, .timeline, .review, .health] {
        cases.append(.init(name: "empty-\(section.rawValue)", view: dashboard(empty, section)))
    }
    cases.append(.init(name: "history-loading", view: dashboard(populated, .history), immediate: true))
    cases.append(.init(name: "history-updating", view: AnyView(dashboard(populated, .history).environment(\.forcedScreenStates, ForcedScreenStates(historyUpdating: true)))))
    cases.append(.init(name: "library-importing-audio", view: AnyView(dashboard(populated, .library).environment(\.forcedScreenStates, ForcedScreenStates(importingAudio: true)))))
    cases.append(.init(name: "empty-library-importing-audio", view: AnyView(dashboard(empty, .library).environment(\.forcedScreenStates, ForcedScreenStates(importingAudio: true)))))

    try BareTextAudit.withAuditPalette {
        // The audit has to be able to fail: bare text is found, text on glass is not.
        let bare = BareTextAudit.bareText(.init(name: "control-bare", view: BareTextAudit.control(onGlass: false)), dark: false)
        guard bare.cells.count >= 4 else { throw GardenSmokeError.failed("The bare-text audit missed a bare caption over the garden") }
        let panel = BareTextAudit.bareText(.init(name: "control-glass", view: BareTextAudit.control(onGlass: true)), dark: false)
        // How many panels register depends on Reduce Transparency, so only the result is checked.
        guard panel.cells.isEmpty else {
            throw GardenSmokeError.failed("The bare-text audit flagged a caption on glass at \(panel.cells.prefix(3))")
        }
        var failures: [String] = []
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for item in cases {
                let found = BareTextAudit.bareText(item, dark: dark)
                if !found.cells.isEmpty { failures.append("\(item.name) \(dark ? "dark" : "light"): bare text near \(found.cells.prefix(3).map { "(\(Int($0.minX)), \(Int($0.minY)))" }.joined(separator: " "))"); if failures.count <= 2 { print("bare-text-evidence \(item.name) \(dark ? "dark" : "light"): \(found.evidence)") } }
            }
        }
        // Each state set above renders with the error banner too: the subtitle moves down with it.
        populated.errorMessage = "Could not save."
        defer { populated.errorMessage = nil }
        for section in [DashboardSection.today, .library, .timeline, .history] {
            let found = BareTextAudit.bareText(.init(name: "banner-\(section.rawValue)", view: dashboard(populated, section)), dark: false)
            if !found.cells.isEmpty { failures.append("banner-\(section.rawValue): bare text near \(found.cells.prefix(3).map { "(\(Int($0.minX)), \(Int($0.minY)))" }.joined(separator: " "))") }
        }
        NSApp.appearance = nil
        guard failures.isEmpty else {
            throw GardenSmokeError.failed("Text sits straight over the garden:\n  " + failures.joined(separator: "\n  "))
        }
    }
    print("ui-smoke: no text sits over the garden outside glass on \(cases.count) screens and states, light and dark, with and without the error banner")
}
