import Foundation

public struct AtlasPageTotals {
    public internal(set) var pages = 0
    public internal(set) var byBook: [String: Int] = [:]
    public internal(set) var byDay: [String: Int] = [:]
    public internal(set) var byDayBook: [String: [String: Int]] = [:]
}
