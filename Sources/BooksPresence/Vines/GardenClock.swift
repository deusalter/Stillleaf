import Foundation

/// Frame pacing for the garden. Only growth needs frames (30 fps); a grown
/// garden breathes through a compositor animation, and a still, off or frozen
/// garden schedules nothing.
struct GardenClock {
    let mode: GardenMode

    /// A fixed moment to draw every frame at, so offscreen renders are deterministic.
    /// Set from `--vine-time <seconds>` or `STILLLEAF_VINE_TIME`.
    static var frozenTime: TimeInterval? = {
        if let index = CommandLine.arguments.firstIndex(of: "--vine-time"), CommandLine.arguments.indices.contains(index + 1) {
            return TimeInterval(CommandLine.arguments[index + 1])
        }
        return ProcessInfo.processInfo.environment["STILLLEAF_VINE_TIME"].flatMap(TimeInterval.init)
    }()

    /// `nil` means no timeline at all: draw one frame and stop.
    func frameInterval(growing: Bool) -> TimeInterval? {
        guard mode == .animated, growing, Self.frozenTime == nil else { return nil }
        return 1.0 / 30
    }
}
