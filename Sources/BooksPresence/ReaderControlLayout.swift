import Foundation

/// The groups of the reader's Appearance panel. The web panel and the native popover
/// use the same order and names, so the two never disagree about where a control lives.
enum ReaderControlGroup: CaseIterable {
    case theme, text, layout, garden, advanced

    var title: String {
        switch self {
        case .theme: return "Theme"
        case .text: return "Text"
        case .layout: return "Layout"
        case .garden: return "Garden"
        case .advanced: return "Advanced"
        }
    }

    /// Renderer preference keys in the order they appear inside the group.
    fileprivate var keys: [String] {
        switch self {
        case .theme: return ["theme"]
        case .text: return ["fontFamily", "fontSize", "fontWeight", "lineHeight"]
        case .layout: return ["scroll", "columns", "margins", "sideMargin", "contentWidth", "measure", "immersive"]
        case .garden: return ["vines"]
        case .advanced: return ["letterSpacing", "wordSpacing", "textAlign", "hyphens", "backgroundColor", "textColor"]
        }
    }
}

enum ReaderControlLayout {
    /// Places each reported preference key in exactly one group. A key this build has never
    /// heard of goes last in Advanced, so a newer renderer's preference is never unreachable.
    static func sections(for reported: [String]) -> [(group: ReaderControlGroup, keys: [String])] {
        let known = Set(ReaderControlGroup.allCases.flatMap(\.keys))
        let present = Set(reported)
        return ReaderControlGroup.allCases.compactMap { group in
            var keys = group.keys.filter(present.contains)
            if group == .advanced { keys += reported.filter { !known.contains($0) } }
            return keys.isEmpty ? nil : (group, keys)
        }
    }
}
