import Foundation

/// Content seconds, independent of wall-clock listening time and playback rate.
public struct AudiobookProgress: Codable, Equatable {
    public var positionSeconds: Double
    public var durationSeconds: Double
    public init(positionSeconds: Double, durationSeconds: Double) {
        self.positionSeconds = positionSeconds; self.durationSeconds = durationSeconds
    }
    public var isValid: Bool {
        positionSeconds.isFinite && durationSeconds.isFinite && durationSeconds > 0 &&
        positionSeconds >= 0 && positionSeconds <= durationSeconds
    }
    public var fraction: Double { isValid ? positionSeconds / durationSeconds : 0 }
    public var description: String {
        "\(Self.timestamp(positionSeconds)) / \(Self.timestamp(durationSeconds))"
    }
    public static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
        let value = Int(seconds)
        return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
    /// Accept H:MM:SS or H:MM; plain numbers are minutes.
    public static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Double($0)?.isFinite == true }) else { return nil }
        let values = parts.map { Double($0)! }
        if values.count == 1 { return values[0] * 60 }
        guard values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return values[0] * 3600 + values[1] * 60 + (values.count == 3 ? values[2] : 0)
    }
}

/// Checkpoint clock: neither seeking nor changing speed can create listening time.
/// Long scheduling gaps (sleep/suspension) are conservatively left uncredited.
public struct ListeningClock {
    private var date: Date?
    private var uptime: Double?
    public init() {}
    public mutating func start(date: Date, uptime: Double) { self.date = date; self.uptime = uptime }
    public mutating func checkpoint(date: Date, uptime: Double) -> (start: Date, seconds: Double)? {
        defer { start(date: date, uptime: uptime) }
        guard let previousDate = self.date, let previousUptime = self.uptime else { return nil }
        let elapsed = uptime - previousUptime, wall = date.timeIntervalSince(previousDate)
        guard elapsed.isFinite, elapsed > 0, elapsed <= 6, wall > 0, abs(wall - elapsed) < 1 else { return nil }
        return (previousDate, min(elapsed, wall))
    }
}
