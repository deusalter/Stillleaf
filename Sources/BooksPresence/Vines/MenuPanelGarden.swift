import SwiftUI

/// Two light vines for the menu bar panel, drawn by the same `GardenCanvas` as the
/// dashboard: one rises from the bottom-left corner, the other climbs the right
/// edge to the top-right corner. Each grows in a narrow strip inside the panel's
/// outer margin, so the vines never sit behind text and never frame the content.
///
/// The garden tracks the panel's visibility: while the panel is closed nothing
/// grows, breathes or redraws.
struct MenuPanelGarden: View {
    let day: String
    let mode: GardenMode

    /// The panel's side margin: text starts this far from the edge.
    static let margin: CGFloat = 30
    /// Four glyph columns, narrower than the margin so the text stays clear of them.
    static let stripWidth: CGFloat = 25

    enum Strip: String, CaseIterable {
        /// Rises from the bottom-left corner.
        case leading = "popover-leading"
        /// Climbs to the top-right corner.
        case trailing = "popover-trailing"

        var height: CGFloat { self == .leading ? 240 : 200 }
        var budget: Int { self == .leading ? 70 : 60 }
    }

    static func layout(_ strip: Strip, day: String) -> GardenLayout {
        GardenLayout(seed: GardenSeed.daily(strip.rawValue, day: day), roots: 3, pollen: false, budget: strip.budget)
    }

    var body: some View {
        ZStack {
            GardenCanvas(layout: Self.layout(.leading, day: day), mode: mode)
                .frame(width: Self.stripWidth, height: Strip.leading.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            GardenCanvas(layout: Self.layout(.trailing, day: day), mode: mode)
                .frame(width: Self.stripWidth, height: Strip.trailing.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }
}
