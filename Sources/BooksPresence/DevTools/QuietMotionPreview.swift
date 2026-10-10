import AppKit
import SwiftUI

/// Offscreen frames of the Quiet UI motion for review: the goal ring at rest, at the peak of its
/// pulse and with the light part-way along, and a ripple spreading through the garden. Core
/// Animation renders model values, not running animations, so each frame is posed by hand on the
/// same layers the app animates. No window is shown. Run with `--render-ui <dir> --offscreen --quiet-ui`.
@MainActor
func renderQuietMotionPreviews(to destination: URL) throws {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    for dark in [false, true] {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let scheme: ColorScheme = dark ? .dark : .light
        let suffix = dark ? "dark" : "light"
        try renderRingFrames(scheme: scheme, appearance: appearance, to: destination.appendingPathComponent("quiet-ring-\(suffix).png"))
        try renderRippleFrames(scheme: scheme, appearance: appearance, to: destination.appendingPathComponent("quiet-ripple-\(suffix).png"))
    }
    print("ui-render: Quiet UI ring and ripple frames saved to \(destination.path)")
}

private enum QuietPreviewError: Error { case renderFailed }

@MainActor
private func capture(_ hosting: NSView, to output: URL) throws {
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw QuietPreviewError.renderFailed }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw QuietPreviewError.renderFailed }
    try data.write(to: output, options: .atomic)
}

@MainActor
private func hostPreview<V: View>(_ view: V, size: NSSize, appearance: NSAppearance?, _ inspect: (NSView) -> Void, to output: URL) throws {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.appearance = appearance
    window.contentView = hosting
    defer { window.contentView = nil; window.close() }
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    hosting.layoutSubtreeIfNeeded()
    inspect(hosting)
    try capture(hosting, to: output)
}

@MainActor
private func renderRingFrames(scheme: ColorScheme, appearance: NSAppearance?, to output: URL) throws {
    let snapshot = ThemeSnapshot.current()
    let accent = (scheme == .dark ? snapshot.dark : snapshot.light).accent
    let progress = 0.63
    let ring = ZStack {
        DottedReadingArc(progress: progress)
        RingLife(progress: progress, reading: true, motion: .full, accent: accent,
                 glint: RingLifeView.glintColor(accent: accent, dark: scheme == .dark))
    }
    .frame(width: 254, height: 250)
    let view = HStack(spacing: 16) { ring; ring; ring }
        .padding(20)
        .background(ReadingPalette.canvas)
        .environment(\.colorScheme, scheme)
    try hostPreview(view, size: NSSize(width: 254 * 3 + 16 * 2 + 40, height: 290), appearance: appearance, { hosting in
        let rings = descendants(of: hosting).sorted { $0.convert($0.bounds, to: hosting).minX < $1.convert($1.bounds, to: hosting).minX }
        guard rings.count == 3 else { return }
        // At rest, at the pulse's peak, and with the light a little over half way along the filled dots.
        rings[0].pose(pulse: 0, lightAt: nil)
        rings[1].pose(pulse: 1, lightAt: nil)
        rings[2].pose(pulse: 0.5, lightAt: 0.55)
    }, to: output)
}

@MainActor
private func descendants(of root: NSView) -> [RingLifeView] {
    root.subviews.flatMap { ($0 as? RingLifeView).map { [$0] } ?? [] } + root.subviews.flatMap { descendants(of: $0) }
}

@MainActor
private func rippleHosts(in root: NSView) -> [RippleHostView] {
    root.subviews.flatMap { ($0 as? RippleHostView).map { [$0] } ?? [] } + root.subviews.flatMap { rippleHosts(in: $0) }
}

@MainActor
private func renderRippleFrames(scheme: ColorScheme, appearance: NSAppearance?, to output: URL) throws {
    // The same garden three times, with a ripple a fifth, half and four fifths of the way through.
    let garden = GardenCanvas(layout: GardenLayout(seed: 5), mode: .animated).frame(width: 420, height: 300)
    let view = HStack(spacing: 12) { garden; garden; garden }
        .padding(12)
        .background(ReadingPalette.canvas)
        .environment(\.colorScheme, scheme)
    try hostPreview(view, size: NSSize(width: 420 * 3 + 12 * 4, height: 324), appearance: appearance, { hosting in
        let hosts = rippleHosts(in: hosting).sorted { $0.convert($0.bounds, to: hosting).minX < $1.convert($1.bounds, to: hosting).minX }
        guard hosts.count == 3 else { return }
        for (host, progress) in zip(hosts, [0.2, 0.5, 0.8]) {
            host.pose(atLocal: CGPoint(x: 210, y: 150), progress: progress, strength: 1)
        }
    }, to: output)
}
