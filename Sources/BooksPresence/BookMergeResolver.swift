import Foundation
import BooksCore

struct BookMergeResolver {
    private let targets: [String: String]
    let activeMerges: [BookMerge]

    init(merges: [BookMerge]) {
        var latestIndex: [String: Int] = [:]
        for (index, merge) in merges.enumerated() {
            latestIndex[merge.sourceID] = index
        }
        activeMerges = merges.enumerated().compactMap { index, merge in
            latestIndex[merge.sourceID] == index && merge.active ? merge : nil
        }
        targets = activeMerges.reduce(into: [String: String]()) { result, item in
            result[item.sourceID] = item.targetID
        }
    }

    func resolvedID(for id: String) -> String {
        var current = id
        var visited = Set<String>()
        while let next = targets[current], visited.insert(current).inserted {
            current = next
        }
        return current
    }
}

