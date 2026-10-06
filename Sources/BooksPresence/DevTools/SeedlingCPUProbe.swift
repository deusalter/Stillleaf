import AppKit
import SwiftUI

/// `--measure-seedling <seconds>` hosts an empty state in a real window (parked
/// by `BackgroundUI`, so it takes no focus) and prints the process CPU it used
/// while idle, so seedling pacing changes can be compared before and after.
@MainActor
func measureSeedlingCPU(seconds: Double) {
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView:
        ReadingEmptyState(title: "Your next chapter awaits", symbol: "books.vertical", message: "Books you read will appear here.")
            .frame(width: 520, height: 420).background(ReadingPalette.canvas))
    window.makeKeyAndOrderFront(nil)
    func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = { (t: timeval) in Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
    // Let the first reveal and layout settle, then sample whole seedling cycles.
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    let wallStart = Date(), cpuStart = cpuSeconds()
    // Also count distinct rendered frames, so a 0% reading cannot hide a seedling that never animates.
    var digests = Set<Int>()
    var sampleTime = wallStart
    while Date().timeIntervalSince(wallStart) < seconds {
        sampleTime = sampleTime.addingTimeInterval(0.25)
        RunLoop.current.run(until: sampleTime)
        if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            digests.insert(bitmap.representation(using: .tiff, properties: [:])?.hashValue ?? 0)
        }
    }
    let wall = Date().timeIntervalSince(wallStart)
    print("seedling-frames: \(digests.count) distinct renders; window visible=\(window.occlusionState.contains(.visible))")
    print(String(format: "seedling-cpu: %.1f%% over %.1fs", (cpuSeconds() - cpuStart) / wall * 100, wall))
    window.close()
}
