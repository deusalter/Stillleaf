import Foundation

/// Bounds expensive tracking notifications without owning or discarding the latest position.
/// The host retains the latest value immediately and delivers it on the trailing deadline.
public struct ReaderProgressDeliveryGate {
    public let interval: TimeInterval
    private var lastDelivery: TimeInterval?
    public private(set) var pending = false

    public init(interval: TimeInterval = 1) {
        precondition(interval > 0 && interval.isFinite)
        self.interval = interval
    }

    /// Repeated requests retain the original deadline rather than postponing it.
    public mutating func request(at uptime: TimeInterval) -> TimeInterval {
        pending = true
        guard let lastDelivery else { return 0 }
        return max(0, lastDelivery + interval - uptime)
    }

    /// Also used to flush pending work before closing. An idle flush is a no-op.
    @discardableResult
    public mutating func deliver(at uptime: TimeInterval) -> Bool {
        guard pending else { return false }
        pending = false
        lastDelivery = uptime
        return true
    }
}
