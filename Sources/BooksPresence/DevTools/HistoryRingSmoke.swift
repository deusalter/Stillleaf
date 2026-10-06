import AppKit
import SwiftUI
import BooksCore

/// Compare the Canvas against the original Shape renderer at the real hosting
/// seam. This catches clipped strokes, rotated seams, and lost book colours.
@MainActor
func checkHistoryRingRendering(entries: [AtlasBookTime]) throws {
    let fixtures = [[], Array(entries.prefix(1)), entries]
    for fixture in fixtures {
        let reference = try ringBitmap(ReferenceHistoryRing(entries: fixture))
        let candidate = try ringBitmap(AtlasTimeRing(entries: fixture))
        guard reference.pixelsWide == candidate.pixelsWide,
              reference.pixelsHigh == candidate.pixelsHigh,
              reference.bytesPerRow == candidate.bytesPerRow,
              let before = reference.bitmapData, let after = candidate.bitmapData else {
            throw HistoryRingSmokeError.renderFailed
        }
        let count = reference.bytesPerRow * reference.pixelsHigh
        let difference = (0..<count).reduce(0) { $0 + abs(Int(before[$1]) - Int(after[$1])) }
        // Canvas/Shape antialiasing can differ at segment seams by a few pixels.
        guard Double(difference) / Double(count) < 0.25 else {
            throw HistoryRingSmokeError.appearanceChanged
        }
    }
    print("ui-smoke: History Canvas matches empty, single-book and segmented Shape rings")
}

private enum HistoryRingSmokeError: Error { case renderFailed, appearanceChanged }

@MainActor
private func ringBitmap<V: View>(_ view: V) throws -> NSBitmapImageRep {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view.frame(width: 100, height: 100).padding(10).background(Color.white))
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw HistoryRingSmokeError.renderFailed
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap
}

private struct ReferenceHistoryRing: View {
    let entries: [AtlasBookTime]
    @Environment(\.colorScheme) private var scheme
    private var total: Double { entries.reduce(0) { $0 + $1.creditedSeconds } }
    var body: some View {
        ZStack {
            Circle().stroke(ReadingPalette.border, lineWidth: 3)
            if total > 0 {
                ForEach(Array(entries.enumerated()), id: \.element.bookID) { index, entry in
                    let start = entries.prefix(index).reduce(0) { $0 + $1.creditedSeconds } / total
                    Circle().trim(from: start, to: start + entry.creditedSeconds / total)
                        .stroke(AtlasStyle.book(entry.bookID, dark: scheme == .dark),
                                style: StrokeStyle(lineWidth: 3.5, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
        }
    }
}
