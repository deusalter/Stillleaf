import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(("reader-controls-smoke FAILED: " + message + "\n").data(using: .utf8)!)
        exit(1)
    }
}

/// The native Appearance panel groups the renderer's controls the way the web panel does,
/// and never drops a preference the renderer reports.
@main
enum ReaderControlsSmoke {
    static func main() {
        // Keys exactly as the renderer's definitions list them (nativeDefinitions in main.js).
        let keys = ["theme", "fontFamily", "margins", "vines", "columns", "fontWeight", "textAlign", "hyphens",
                    "fontSize", "lineHeight", "measure", "contentWidth", "sideMargin", "letterSpacing", "wordSpacing",
                    "scroll", "immersive", "backgroundColor", "textColor"]
        let sections = ReaderControlLayout.sections(for: keys)
        check(sections.map(\.group) == [.theme, .text, .layout, .garden, .advanced], "groups appear as Theme, Text, Layout, Garden, Advanced: \(sections.map(\.group))")
        check(sections.map(\.group.title) == ["Theme", "Text", "Layout", "Garden", "Advanced"], "group titles")
        let byGroup = Dictionary(uniqueKeysWithValues: sections.map { ($0.group, $0.keys) })
        check(byGroup[.theme] == ["theme"], "theme group")
        check(byGroup[.text] == ["fontFamily", "fontSize", "fontWeight", "lineHeight"], "text group order: \(byGroup[.text] ?? [])")
        check(byGroup[.layout] == ["scroll", "columns", "margins", "sideMargin", "contentWidth", "measure", "immersive"], "layout group order: \(byGroup[.layout] ?? [])")
        check(byGroup[.garden] == ["vines"], "garden group")
        check(byGroup[.advanced] == ["letterSpacing", "wordSpacing", "textAlign", "hyphens", "backgroundColor", "textColor"], "advanced group order: \(byGroup[.advanced] ?? [])")
        check(Set(sections.flatMap(\.keys)) == Set(keys) && sections.flatMap(\.keys).count == keys.count, "every key is placed exactly once")

        // A preference the panel has never heard of is still reachable, behind Advanced, after the known ones.
        let extended = ReaderControlLayout.sections(for: keys + ["futurePreference"])
        check(extended.last?.group == .advanced && extended.last?.keys.last == "futurePreference", "unknown keys land last in Advanced")
        check(extended.flatMap(\.keys).count == keys.count + 1, "unknown keys are not dropped")

        // Groups with no controls are omitted.
        check(ReaderControlLayout.sections(for: ["fontSize"]).map(\.group) == [.text], "empty groups are omitted")
        check(ReaderControlLayout.sections(for: []).isEmpty, "no definitions, no sections")
        print("reader-controls-smoke: Theme/Text/Layout/Garden/Advanced grouping places every control once; unknown preferences stay reachable")
    }
}
