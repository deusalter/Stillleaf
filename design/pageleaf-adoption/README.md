# Pageleaf adoption

Approved by the user after selecting concept 01. Implemented on `ui/icon-concepts` on top of the `ui/appearance-mode` base. No merge, deployment, app installation, or relaunch of the user's app.

## Updated surfaces

| Surface | Implementation |
| --- | --- |
| Native dashboard sidebar | Theme-colored `PageleafMark`, existing wordmark retained |
| Native menu popover | Same mark at 18 pt |
| Native macOS status item | Same vector rendered into an 18 pt `NSImage`, `isTemplate = true` for system appearance/highlight handling |
| Native Dock / Finder / app bundle icon | Generated transparent PNG and complete ICNS; package script regenerates before copying |
| Welcome walkthrough | Central mark replaced; layout, typography, ring geometry and motion retained |
| Walkthrough menu hint and completion particles | Pageleaf replaces old book/leaf identity; hint text and accessibility label match |
| Website | Shared SVG in header, footer, download section and adaptive favicon |
| Desktop reader Library | Inline theme-colored SVG beside existing name; favicon |
| Desktop reader windows / macOS development Dock | Generated PNG in both BrowserWindow constructors and `app.dock.setIcon` |
| Embedded reader browser/favicon | Shared SVG in Vite public assets; Electron asset loader now serves SVG MIME type |

Generic book icons for book actions, completion checkmarks, botanical scenery and fictional book-cover illustrations remain semantic/decorative artwork. They are not alternate product marks.

## Source and rebuild

`Sources/BooksPresence/Pageleaf.swift` owns the vector commands. Native SwiftUI and AppKit use them directly; `scripts/generate-pageleaf.swift` uses them for all exported assets. `scripts/generate-pageleaf.sh` builds the helper and ICNS, and packaging invokes it. There are no new runtime resource lookup requirements in the native executable.

## Previews

- `before-after.png`: native SwiftUI component study using actual SF Symbols, approved vector, status image and old/new Dock PNGs. This is explicitly a component preview, not a screenshot of the running user's dashboard. It shows the welcome mark at rest; motion is unchanged in source.
- `website-after.png`: WebKit capture of the locally built website at 1280 × 900 CSS pixels, confirming the header's external SVG use loads correctly.
- `before-dock.png`: preserved original source artwork for comparison.
- `render.swift`: reproducible native preview; compile alongside `Sources/BooksPresence/Pageleaf.swift` and pass repository root.
- `render-web.swift`: WebKit capture helper; expects website dist on localhost:4188 and accepts an output directory.

## Validation completed

- Native `scripts/build-local.sh` passed, with only the existing Onboarding.swift actor-conversion warning. Reader resource build ran separately and passed.
- Website production build and all 19 existing tests passed.
- Pageleaf generator compiled, PNG/ICNS exports succeeded, and ICNS round-tripped through `iconutil`.
- All ten iconset sizes have transparent corner pixels; standalone SVGs parse and all copied SVGs are identical.
- Native component preview inspected in light/dark menu-bar treatments; Dock gradient clipping found during inspection was corrected before final export.
- Electron main file passes `node --check`; shell scripts pass syntax checks; `git diff --check` passes.

## Coordination and limitations

Shared-file overlaps are small: `BooksPresenceApp.swift` changes only the status image assignment; `AppViews.swift` changes two identity marks; `Onboarding.swift` changes identity marks and two icon references in text. Other changes are asset generation, reader identity references, website marks and documentation. No LibraryView, History, Settings or shared motion/type changes.

Historical screenshots in `website/public/screenshots/` and earlier design/test evidence retain their original recorded UI. Refresh website gallery screenshots after the other UI sessions are integrated, against that combined release; the provenance file calls this out. They are not falsely retouched here.

Electron Library identity is now exercised by an isolated Electron regression at the real file URL (see below). Live Dock integration remains untested. Native template rendering is checked in the preview; live menu selection/highlight and OS icon-cache refresh remain installation-time checks. Windows executable/installer branding awaits a Windows packaging pipeline, which this development project does not yet define.


## Adversarial review fix: Library file-origin rendering

The first adoption commit's external SVG `use` was blocked by Chromium at the Library's `file://` origin, and its file favicon was blocked by `img-src stillleaf-app:`. The fix generates the Library path inline from `PageleafIdentity.svgPath` and exposes the favicon through the existing exact-key resource map at `stillleaf-app://identity/pageleaf.svg`. CSP is unchanged; the handler still serves only registered resources and GET requests.

`Reader/desktop/test/electron-identity.test.mjs` launches an isolated hidden Electron instance with temporary test data and loads the actual Library HTML through the normal application entry point. It checks nonzero SVG bounds, shared exported path parity, no external `use`, successful favicon decoding, and no CSP/identity-resource violations. Confirmed the regression fails on the previous committed HTML's zero painted geometry, then passes with this fix. `library-after.png` is an actual screenshot from that test, not a mockup. No installed user app or database was touched.

Run `node --test Reader/desktop/test/electron-identity.test.mjs` after installing the desktop and publication package dependencies and building the reader. The existing desktop test command now includes this regression. Set `STILLLEAF_IDENTITY_PREVIEW` to an absolute PNG path to capture a screenshot.
