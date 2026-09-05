# Stillleaf integrated baseline

Integration branch: `maintenance/consolidate-stillleaf`, based on GitHub main
`f07fbb5e61ee5627499c9ae05a737bd7b063d9b1`. The user authorized integrating the
remaining work, merging to main and preparing an updated app for UI comparison.

## What is integrated

- Existing main: dashboard/themes, welcome tour, Apple Books in-place reading,
  lazy resources/covers, reader teardown and serialized navigation fixes.
- `reader/window-polish`: native fullscreen, Mac menu bar and Dock presence while
  windows are open, visual reading-mode buttons, and seamless continuous reading
  in the native host. The newer main teardown fix is retained.
- The dirty `reader/integrated-epub-reader` work: eight bundled font families,
  additional/custom page colours, custom page spacing, fine text-size controls,
  Focus reading, matching native/Node validation and portable state transfer.
  Existing theme/font/margin IDs and publisher-default styling are preserved.
- Archive package `e6465d9` and its Electron Library UI: complete managed-library
  export and preservation/re-export of recovery archives. Preservation does not
  activate foreign journal records or replace the current Library.
- The isolated Windows journal prototype and menu-bar design/review artifacts
  are retained under `prototypes/windows-journal` and `design/menu-bar-concept`.
- Standard desktop tests now include the previously omitted journal suites;
  project CI also checks publication, archives, desktop/journal and website.

Website, `ReadingMotion`, completion celebration, session grouping/History
optimisation and optional date editor match the preserved contributor versions
already on main. They require no second implementation. `wip/epub-reader` and the
recovery-before-split branches are historical snapshots, not independent feature
queues. Old engine-comparison experiments remain in their preserved worktree;
they are not part of the application build.

## Application boundaries

The native Mac app is the product being packaged. `Reader/desktop/reader` is its
shared renderer. `Reader/desktop` is a separate Electron development host with
its own SQLite journal and archive controls; it is not a validated Windows
release. The older Windows prototype has its own data model and stays isolated.
The website remains a preview with unapproved publication/download gates.

The previous [implementation checkpoint](READER_IMPLEMENTATION_CHECKPOINT.md)
is a historical log, not the current ownership or milestone queue.

## Verification

All verification uses synthetic EPUBs and temporary databases. Personal books
and history are excluded from destructive tests.

- Publication: 85 tests.
- Archive package: 12 tests, including byte-preserving round trips and rejection.
- Desktop/journal: 66 tests, including host archive integration, no-overwrite,
  unsafe-source rejection, appearance persistence and portable transfer.
- Windows prototype: 10 core tests.
- Shared renderer: eight headless Chrome suites, including continuous page
  evidence, old appearance compatibility, custom colours, bundled font loading,
  focus controls, navigation, notes and state retention.
- Hidden Electron host integration, including the Library archive dialog.
- Optimized native build, 15 portable smoke suites and synthetic native UI.
- Website: 19 tests and production build passed at the unchanged website baseline.

Native WebKit appearance stress verification passed and checks bundled-font
rendering, semantic reading targets, wide/facing/continuous layouts, narrow
large-text layouts and focus mode. Final results are retained in
`.build/integrated/appearance-review` and `.local/integration`.

These local checks do not establish Windows hardware, assistive-technology
conformance, live Discord/Apple Books permission state, mobile support or
notarized distribution. XCTest and release/package checks also run in GitHub CI.

## Repeatable checks

From the repository root, using Node 22.12+:

```sh
npm --prefix Reader/packages/publication ci --ignore-scripts
npm --prefix Reader/packages/archive ci --ignore-scripts
npm --prefix Reader/packages/publication test
npm --prefix Reader/packages/archive test
npm --prefix Reader/desktop test
npm --prefix prototypes/windows-journal test
npm --prefix Reader/desktop/reader ci
npm --prefix Reader/desktop/reader run build
npm --prefix Reader/desktop/reader test
BOOKSPRESENCE_BUILD_DIR=.build/integrated scripts/build-local.sh
```

Electron host integration additionally requires `npm --prefix Reader/desktop ci`;
see [its README](../Reader/desktop/README.md). Browser tests require Chrome and
loopback access. Tests regenerate synthetic screenshot artifacts; keep those
separate from source changes unless reviewing visuals intentionally.

## Recovery and remaining boundaries

Original worktrees remain intact. `.local/consolidation-2026-09-27` holds their
inventory, the dirty reader binary patch, and hash-checked copies of untracked
reader work. `.local/integration` contains additional integration evidence. These
are local recovery aids, not remote backups.

PR #17 duplicates the teardown fix already merged through #15: commits
`f0cec365` and `f60d257` have stable patch ID
`6d9369867d95448809b3d7be4bee88a629051eb1`. Its code needs no second merge.

Still incomplete product scope: active cross-host archive restoration, Electron
correction/merge parity, Windows hardware/installer acceptance, broader native
accessibility/EPUB fidelity, signing/notarization and mobile work. Consolidating
existing implementations does not imply those future features are complete.
