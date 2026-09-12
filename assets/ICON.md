# Stillleaf Pageleaf identity

The user selected Pageleaf: paired leaves suggesting an open book. `Sources/BooksPresence/Pageleaf.swift` is the shared geometry for SwiftUI dashboard/popover/walkthrough marks and the monochrome AppKit status image (`isTemplate = true`, 18 pt). Native colors inherit the active theme.

`BooksPresence.png` is the generated 1024px RGBA Dock artwork: the approved warm-ivory Pageleaf on a green rounded tile, with transparent outer corners. `BooksPresence.icns` includes the standard 16, 32, 128, 256 and 512 point representations at 1x and 2x. Existing bundle icon filenames and identifiers remain compatible with the package pipeline.

Run `scripts/generate-pageleaf.sh` from any directory to regenerate the PNG, ICNS, `Pageleaf.svg`, website SVG, desktop-reader SVG/PNG, and reader favicon. It compiles a local rendering helper using the same native vector geometry and uses macOS `iconutil`; it never launches Stillleaf. `scripts/package-app.sh` calls this generator before building and copying the ICNS into the app bundle.

The SVG adapts standalone favicon color to light/dark appearance. Inline SVG uses in website and reader wordmarks inherit their surrounding text color. Electron development windows use the generated PNG; macOS Electron sets its Dock icon when ready. A future packaged Windows executable still needs installer/executable icon configuration because no Windows packaging pipeline exists here.

Original concept studies remain in `design/icon-concepts/`. Adoption inventory, validation, overlap notes and before/after previews are in `design/pageleaf-adoption/`.
