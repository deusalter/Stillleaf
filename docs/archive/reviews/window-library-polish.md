# Window and Library polish

Based on `ui/appearance-mode` at `029b1be`. Branch: `ui/window-library-hover`.

The dashboard title bar was transparent over AppKit's default window background,
while the dashboard uses the selected theme's canvas. `DashboardWindow` supplies
a dynamic canvas backing and refreshes it on theme revisions. The title, native
traffic lights, drag region, resize behavior and fullscreen opt-in remain native.
The walkthrough was inspected as the reference for continuous themed surfaces;
its implementation is untouched.

Library hover previously filled the flexible card rectangle, whose dimensions
vary with grid columns and caption length. Covers themselves are clipped to
150 × 225 points. Hover now adds an inset outline and restrained shadow directly
to that cover, before the flexible frame. The hit target and keyboard focus ring
still cover the card. No scale or displacement is introduced; Reduce Motion
continues to disable the hover animation.

Library cards now select the newest reliable saved position across merged book
IDs. Percent is prominent, with current / total pages beneath when both exist.
Unknown totals show the known page and "Total unavailable". Fraction-only evidence
shows percent without invented pagination. Missing or invalid evidence falls back
to "pages logged" / "Position unavailable", never an invented position. A completed
book without usable position remains "Finished".

`LibraryProgressLabel.position(.time(current:total:))` supports content-time
percentage and fraction. At integration, the audiobook owner can adapt
`ProgressObservation.audio.positionSeconds` / `.durationSeconds` or
`AppModel.audiobookProgress(for:)`. This branch does not add or depend on that
unfinished schema. Elapsed listening time must not be passed as content position.

## Integration boundaries

- `BooksPresenceApp.swift`: one-line replacement of the dashboard NSWindow class.
  The icon chat also touches this file; retain both edits.
- `LibraryView.swift`: card rendering, reliable position selection, hover geometry.
- New `DashboardWindow.swift` and `LibraryProgressLabel.swift`: no shared tracker,
  model, reader, Settings, icon, History or walkthrough edits.
- Baseline native EPUB refresh passes `progress: nil` while its page position has
  no total. The reading-progress-accuracy chat owns authoritative persistence and
  source selection. Library renders saved reliable evidence; it cannot establish
  freshness or authority beyond that contract.

## Validation and reproduction

Build using `BOOKSPRESENCE_SKIP_READER_BUILD=1 scripts/build-local.sh`; this skips
unrelated web-reader asset compilation. The final Swift executable was rebuilt
against the same local BooksCore and BooksPlatform modules after progress edits.
Run `.build/local/BooksPresence --self-test-ui` for the existing synthetic UI suite.

Compile `Sources/BooksPresence/LibraryProgressLabel.swift` together with
`scripts/library-progress-smoke.swift`, linking local BooksCore. This tests page
fractions, activity/position separation, missing totals, unreliable and invalid
observations, completion fallbacks and audiobook-ready content-time formatting.

`scripts/preview-chrome-library.sh OUTPUT [BEFORE_SOURCE_DIRECTORY]` compiles an
isolated preview executable using synthetic data. It captures the complete native
window frame, and actual cards at rest/hover for portrait, square and landscape
source art. It checks that all three native window buttons and window movement
remain available, and that a live window resolves every theme's light/dark canvas.
The macOS 13 Reduce Motion environment is read-only; the harness injects its value
into temporary card sources to exercise the existing production branch. Hover is
also initialized in temporary sources. User accessibility settings are untouched.
These are settled-state renders, not a physical mouse/VoiceOver/fullscreen test.
Inactive preview windows intentionally show inactive traffic lights.

Local review images are in `.local/chrome-library/before/` and
`.local/chrome-library/after/`: `window-light.png`, `window-dark.png`, and
`covers-{light,dark}-{normal,reduced}.png`. The baseline source snapshot is ignored
under `.local/chrome-library/before-sources/`. No installed app was replaced or
relaunched; nothing was merged or deployed.

Validation result: production native build and final-source preview compilation
passed. Existing `--self-test-ui` passed, as did the dedicated progress smoke,
branch-name check and `git diff --check`. All six theme canvases matched in light
and dark. Normal/reduced settled-state PNG hashes matched for both appearances.
The existing Onboarding.swift:172 actor-conversion compiler warning remains;
this work does not modify that file. Final previews were inspected, including
outer-card shadow bounds and the known-total / unknown-total / fraction-only
progress states. Final dark shadows use neutral black, avoiding a light ink glow.
