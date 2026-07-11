# Local verification — 2026-09-24

Scope: website only. Native reference baseline is `0e23ba6`. This does not certify the built-in reader, Windows application, release binaries, signing, or distribution.

## Automated checks

- `npm test`: 19/19 tests pass (8 release-gate checks and 11 progress/preset/journey checks).
- Shared journey tests cover bounds, invalid input, complete daily goals, arc-to-reader handoff, continuous visual channels, forward/reverse behavior, and the final reader preset.
- Production builds pass release validation and Vite bundling.
- `node scripts/validate-release.mjs --for-publication` exits 1 as required: publication is not approved and no verified release is available.

## Upper narrative and controls

Checked the actual production server at `http://127.0.0.1:4173/` in the Codex browser, including 1280×800 and 1440×900 desktop compositions.

- All five original books have active 9–13 second drift half-cycles. Their transforms change between observations. Separate scroll trajectories translate the book solids laterally, downward, and in depth, with individual rotation; full hero travel adds 160–310px downward before the shared hero offset.
- The daily arc uses the native 37/31-dot geometry, not a generic ring. Automatic 0→12→24 sample pages and reverse 24→12 were observed with the optional slider closed. The shared scene subsequently expanded this into one arc-to-reader timeline.
- The daily arc/card visibly enters with translation, rotation and scale. The original Quiet Hours jacket, page layers, leaves and orbit continue through the shared stage; the background deepens from pale green to forest.
- Reader views observed live: Sea glass/literary/1.8, Paper/classic/1.65, Dusk/modern/1.75, and Midnight/literary/1.9. These are illustrative presentation examples, not a claim about the final app's theme inventory.
- Manual typeface and spacing choices work. Ordinary subsequent scrolling restores automatic state without a Follow scroll control. The automatic output elements use `aria-live="off"` to avoid announcing every scroll update.
- Ink and paper switch together; they do not interpolate through a low-contrast midpoint. The page itself has a bounded movement/fade transition.
- One small pause icon serves the page. Pausing stops ambient effects and shows ordinary stacked content at full opacity. A paused reader retained its viewport position (top approximately 0px), and Resume returned to the reader stage. The system motion preference remains authoritative.
- Direct reader navigation lands after the wipe is complete. A keyboard-focus-only continuation link gives sequential keyboard users a route from daily goals into the reader stage; inactive overlapping content is inert.
- At 390×844, 320×720, 768×720, and 1280×600, the shared stage becomes ordinary stacked content and the document has no horizontal overflow. Phone-width theme/typeface controls worked; content below the preview remains reachable by ordinary scrolling.
- Narrow mouse-driven desktop windows can keep inexpensive book drift; a narrow viewport test does not emulate a physical touch device.

## Final lower-page pass

- The lower page is an editorial composition of the original Quiet Hours book and an original sample personal review. The real native screenshots remain in an optional gallery; opening it and selecting Reviews updates the image, alt text and pressed state correctly.
- Shared closing-scene book descent was observed changing from -21.17px to206.52px as scroll progressed, and returning to -125.51px on reverse scroll. Rotation/depth changed with it. The same background and object sequence extends through the Mac/Windows release cards.
- Inspected the journal and release sections at1440×900,390×844 and320×720. No horizontal overflow; platform cards stack on phone widths. Corrected a320px caption overlap and darkened the small folio labels after contrast review.
- Actual release grid contains zero links. All inspected images loaded successfully. Final production browser logs reported no warnings/errors.
- Production bundle:17.49KB JavaScript(6.71KB gzip),51.52KB CSS(12.33KB gzip), plus local fonts, original vector assets and existing compressed native screenshots.
- Final viewport captures are `final-journal-desktop.png`, `final-journal-phone.png`, `final-downloads-desktop.png`, `final-downloads-phone.png`, and `final-platforms-phone.png` under ignored `artifacts/showcase/`.

## Performance and fallback limits

One passive scroll listener coalesces work into a single requested frame. IntersectionObserver limits rendering to visible/exiting scenes; there is no continuous JavaScript animation loop. Arc updates write only changed dot opacities. The site uses plain HTML/CSS/JS, SVG and locally served fonts/assets; no 3D runtime, canvas engine, or UI framework.

The browser tool does not expose media/connection emulation. Reduced Motion, Save Data, low-core/device-memory, document visibility and no-JavaScript fallbacks were reviewed in source. Narrow/short-window layout gates, offscreen pausing, manual controls and explicit pause were exercised live. No physical-device power profile, Windows browser run, full screen-reader audit, or JavaScript-disabled browser test is claimed.

No-JavaScript content includes a static sample arc, original passage and unavailable release states. Native details/summary content remains usable. Animated decoration starts paused until eligibility is evaluated.

## Artifacts and publication

Ignored `artifacts/showcase/` contains viewport captures and observed DOM state. Earlier captures may document intermediate iterations; the final lower-page captures and final observations are identified separately. Full-page screenshots from this browser tool can show duplicate stitched bands, so verification uses viewport images.

Release configuration and original cover sources remain unchanged. The current site has no enabled download links. Mac/Windows remain in development; Android/iOS are roadmap-only, Coming soon, without release dates.

See README.md for actual publication prerequisites. No remote push, deployment, domain purchase, installed app replacement/relaunch, default-app change, or system permission change was performed.
