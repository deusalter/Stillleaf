import AppKit
import SwiftUI

/// Isolated native component fixture. No AppModel, database, tracking, or user defaults.
@MainActor private final class Selection: ObservableObject {
    @Published var value = "Reading"
}

private struct SharedStyleFixture: View {
    @ObservedObject var selection: Selection
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader("Your reading", subtitle: "A little time with a good book.")
            ReadingSegmentedControl(label: "Bookshelf", options: ["Reading", "Finished", "All books"],
                                    selection: $selection.value, title: { $0 })
                .frame(width: 380)
            ReadingSection("Today") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("24").font(ReadingType.numeral(64)).monospacedDigit()
                    Text("of 30 pages").font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                }
                HStack(spacing: 30) {
                    StatLine(value: "48", label: "Minutes read")
                    StatLine(value: "7", label: "Reading days")
                    StatLine(value: "12", label: "Books finished")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("A Room of One’s Own").font(ReadingType.bookTitle(24))
                Text("Virginia Woolf").font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
            }
            Button("Continue reading") {}.buttonStyle(ReadingButtonStyle(emphasis: .primary))
        }
        .padding(36).frame(width: 640, height: 560, alignment: .topLeading)
        .foregroundStyle(ReadingPalette.ink).background(ReadingPalette.canvas)
    }
}

@main private struct SharedStylePreview {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            for reduced in [false, true] {
                let name = "\(dark ? "dark" : "light")-\(reduced ? "reduced" : "motion")"
                let directory = output.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let selection = Selection()
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                app.appearance = appearance
                let hosting = NSHostingView(rootView: SharedStyleFixture(selection: selection)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    // Swift 5.8's public Reduce Motion value is read-only. Its writable
                    // preview hook stays in this standalone fixture, never the app.
                    .environment(\._accessibilityReduceMotion, reduced))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.contentView = hosting
                window.orderBack(nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                // Ordinary selection, then three reversals 67 ms apart, then settle.
                for frame in 0..<90 {
                    if frame == 15 { selection.value = "Finished" }
                    if frame == 36 { selection.value = "All books" }
                    if frame == 40 { selection.value = "Reading" }
                    if frame == 44 { selection.value = "Finished" }
                    if frame == 65 { selection.value = "All books" }
                    RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60))
                    hosting.layoutSubtreeIfNeeded()
                    hosting.displayIfNeeded()
                    let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to:
                        directory.appendingPathComponent(String(format: "%03d.png", frame)))
                }
                window.contentView = nil
                window.close()
            }
        }
        print("Native component frames: \(output.path)")
    }
}
