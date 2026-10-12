import Foundation

extension Array {
    /// The elements ordered by `key`, with equal keys in their original order, as `sorted(by:)` keeps
    /// them. Only keys and positions move while sorting, so ordering thousands of large records
    /// (events, intervals) costs a fraction of sorting the records themselves.
    /// Inlinable so callers get a version specialized for their key type; through generic dispatch
    /// the comparisons alone cost more than the sort saves.
    @inlinable
    public func orderedByKey<Key: Comparable>(_ key: (Element) -> Key, descending: Bool = false) -> [Element] {
        var order: [(key: Key, index: Int)] = []
        order.reserveCapacity(count)
        for (index, element) in enumerated() { order.append((key(element), index)) }
        order.sort { (lhs: (key: Key, index: Int), rhs: (key: Key, index: Int)) -> Bool in
            if lhs.key == rhs.key { return lhs.index < rhs.index }
            return descending ? lhs.key > rhs.key : lhs.key < rhs.key
        }
        return order.map { self[$0.index] }
    }
}
