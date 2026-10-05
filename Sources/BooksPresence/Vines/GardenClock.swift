import Foundation

/// Frame pacing for the garden: growth at 60 fps, breathing at 20 fps, and no
/// frames at all when the garden is still, off or frozen for a render.
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
        guard mode == .animated, Self.frozenTime == nil else { return nil }
        return growing ? 1.0 / 60 : 1.0 / 20
    }
}
