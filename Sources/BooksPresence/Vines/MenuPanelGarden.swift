import SwiftUI

/// The vines around the menu bar panel: a trellis along the top and bottom
/// edges with a tall vine up each side, all drawn by the same `GardenCanvas`
/// as the dashboard. They grow only in the gutters around the glass card, so
/// they never sit behind text.
///
/// The garden tracks the panel's visibility: while the panel is closed nothing
/// grows, breathes or redraws.
struct MenuPanelGarden: View {
    let day: String
    let mode: GardenMode
    let frost: FrostRegions

    /// Width of a side vine: four glyph columns, the gutter beside the card.
    static let sideWidth: CGFloat = 26
    /// Rows the top and bottom trellis may occupy.
    static let trellisBand = 3

    /// The vine up one side of the panel.
    enum Side: String {
        case leading = "popover-leading", trailing = "popover-trailing"
    }

    /// The top and bottom trellis with its four corner vines.
    static func trellis(day: String) -> GardenLayout {
        GardenLayout(seed: GardenSeed.daily("popover", day: day), roots: 8, pollen: false,
                     cornerRoots: [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing],
                     budget: 280, edgeBand: trellisBand, bandEdges: [.top, .bottom])
    }

    static func side(_ side: Side, day: String) -> GardenLayout {
        GardenLayout(seed: GardenSeed.daily(side.rawValue, day: day), roots: 5, pollen: false, budget: 140)
    }

    var body: some View {
        ZStack {
            // Edges and corners; frosted where the card overlaps them.
            GardenCanvas(layout: Self.trellis(day: day), mode: mode, frost: frost)
            // A vine up each side, between the trellises. The card stops short of them.
            HStack(spacing: 0) {
                GardenCanvas(layout: Self.side(.leading, day: day), mode: mode).frame(width: Self.sideWidth)
                Spacer(minLength: 0)
                GardenCanvas(layout: Self.side(.trailing, day: day), mode: mode).frame(width: Self.sideWidth)
            }
            .padding(.vertical, CGFloat(Self.trellisBand) * GardenModel.cellHeight)
        }
    }
}
