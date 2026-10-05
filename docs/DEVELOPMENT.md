# Development

How the repository fits together and how to check a change. For what the app does, see [the product spec](PRODUCT_SPEC.md) and [capabilities](CAPABILITIES.md).

## What lives where

| Path | What it is |
|---|---|
| `Sources/BooksPresence` | The native Mac app (SwiftUI/AppKit). This is the product that gets packaged as `Stillleaf.app`. |
| `Sources/BooksCore`, `Sources/BooksPlatform` | Storage, tracking rules, EPUB import, Apple Books and Discord adapters. Covered by XCTest in `Tests/`. |
| `Reader/desktop/reader` | The shared EPUB renderer. `scripts/build-reader-assets.sh` bundles it into the Mac app. |
| `Reader/packages` | Publication importer and archive packages used by the renderer and the Electron host. |
| `Reader/desktop` | A separate Electron development host with its own SQLite journal. It is not a validated Windows release. |
| `prototypes/windows-journal` | The older Windows journal prototype. Kept isolated as the reference for the `stillleaf-journal-prototype/v1` format that `Reader/desktop/src/journal/migration.cjs` imports. |
| `website` | The marketing site preview. |
| `design` | Design concepts and review renders. |
| `docs/archive` | Finished plans, handoffs and dated reports, kept for history. |

The executable, Application Support folder (`~/Library/Application Support/BooksPresence`) and `BOOKSPRESENCE_*` variables keep the original BooksPresence name. Renaming the data folder needs a migration.

## Build

With full Xcode: `swift build`, `swift test`, `scripts/package-app.sh`.

With Command Line Tools only, SwiftPM cannot run. Use the direct `swiftc` builder instead:

```sh
scripts/build-local.sh            # BOOKSPRESENCE_BUILD_DIR picks the output folder (default .build/local)
scripts/check-local.sh            # build + every smoke suite + native self-checks
scripts/package-app.sh            # writes dist/Stillleaf.app
```

`package-app.sh` replaces `dist/Stillleaf.app` in place. If that copy is your installed app, quit it first.

Run `scripts/install-git-hooks.sh` once per clone. Branch names follow `<area>/<topic>`; `scripts/check-branch-name.sh` checks one.

## Checks

| Area | Command | In CI |
|---|---|---|
| Core and platform logic | `swift test` (needs Xcode) | Yes, `macos.yml` |
| Native smoke suites | `scripts/check-local.sh` | Only the date-field smoke and `--self-test-ui` |
| Shared renderer | `npm --prefix Reader/desktop/reader ci && npm --prefix Reader/desktop/reader test` | Yes, Chrome and WebKit |
| Native EPUB reader | `.build/local/BooksPresence --self-test-epub <book.epub>` | Yes, on a synthetic book |
| Publication and archive packages | `npm --prefix Reader/packages/<name> ci --ignore-scripts && npm --prefix Reader/packages/<name> test` | Yes |
| Electron host unit tests | `npm --prefix Reader/desktop test` | Yes |
| Electron host UI tests | In `Reader/desktop`: `npm ci && npm run build:reader && node --test test/*.test.mjs` | No |
| Windows prototype | `npm --prefix prototypes/windows-journal test` | Yes |
| Website | `npm --prefix website ci && npm --prefix website test && npm --prefix website run build` | Yes |

Most smoke suites only run locally, so run `scripts/check-local.sh` before packaging or merging native changes.

Browser and Electron UI tests write screenshots to `Reader/desktop/reader/artifacts/` and `Reader/desktop/test-output/`. Both are ignored; nothing compares against them.

## Rendering the UI

`BooksPresence --render-ui <folder> --offscreen` renders every dashboard screen, the menu panel and onboarding to PNGs from a disposable synthetic database. `--preview-filter today,library` limits the set and `--all-themes` adds every theme. Glass and system materials do not render offscreen. `scripts/run-native-chrome-preview.sh` captures real windows, but it needs Screen Recording permission.

## Not verified by automated checks

Live Apple Books Accessibility behaviour, live Discord rendering, VoiceOver operation, notarized distribution and Windows hardware.
