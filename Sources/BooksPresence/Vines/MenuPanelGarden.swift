import SwiftUI

/// The garden behind the menu bar panel: vines rise from the bottom, spill from
/// all four corners and reach in from both sides at three heights, so they fill
/// the panel evenly rather than banking up at one edge. Drawn by the same
/// `GardenCanvas` as the dashboard. Wherever glass covers it the garden shows
/// softly frosted; only what is left uncovered at the panel's edge stays crisp.
///
/// The garden tracks the panel's visibility: while the panel is closed nothing
/// grows, breathes or redraws.
struct MenuPanelGarden: View {
    let day: String
    let mode: GardenMode
    let frost: FrostRegions

    static func layout(day: String) -> GardenLayout {
        GardenLayout(seed: GardenSeed.daily("popover", day: day), roots: 2, pollen: false,
                     cornerRoots: [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing], sideRoots: 3,
                     budget: 600, vigor: 1.2)
    }

    var body: some View {
        GardenCanvas(layout: Self.layout(day: day), mode: mode, frost: frost)
    }
}
