# Stillleaf desktop reader — local integration slice

This is a separate Electron development host. It preserves the Mac app and earlier Windows manual-journal prototype and uses a distinct data directory. It is not the complete reader release or a claim of Apple Books parity.

## Run locally

From this directory:

```sh
npm --prefix ../packages/publication ci --ignore-scripts
npm ci
npm run build:reader
npm test
npm run test:desktop
npm start
```

Electron is pinned to **44.4.5**, Readium to **2.10.3**. The publication importer is consumed directly from the neighboring source package while that package develops; production packaging must bundle that package/dependencies and register EPUB file associations. `npm start` requires a desktop session. Test launch always sets `STILLLEAF_TEST_DATA` to a new temporary directory and keeps every BrowserWindow hidden. It never reads the installed app or previous prototype's journal.

Normal development data lives in `appData/StillleafReaderDevelopment/library`; do not point `STILLLEAF_TEST_DATA` at user data. No account or online service is used.

## Implemented behavior

- One single-instance host and one Library. Cold argv, early/warm `open-file`, `second-instance` argv, picker and file drop all enter the shared `ImportCoordinator`.
- Import never opens a reader or credits a reading session. The queue presents per-file outcomes, a summary and cancellation of remaining queued files. In-flight import reports its actual transaction result.
- Library rebuilds from committed managed publication receipts after restart; corrupt receipts produce secondary warnings and remain untouched.
- Embedded raster EPUB covers display directly, with a local title placeholder when unavailable. No online lookup or artwork upload exists. SVG covers are not decoded by this slice.
- Explicit Read opens a separate sandboxed, context-isolated window with Node disabled and **no preload or privileged bridge**.
- Reader uses the reusable browser-only bundle below. Reflowable HTML chapters, local raster images/fonts/CSS, next/previous, durable locations, bookmarks, range highlights/notes, search, contents, and appearance settings work. Explicit single-page, facing-page, and chapter-scroll modes preserve state; chapter-scroll currently hands off at chapter boundaries rather than displaying adjacent chapters together. Original author scripts and active content are removed; unsupported styling/assets generate a readable warning.
- Electron's standard/secure `stillleaf-app://reader` protocol serves only the exact built asset map. `file://` is unsuitable for Readium here because its messaging encounters a null target origin.
- Host session denies nonlocal requests, permissions, popups and webview attachment; frame navigation permits only the shell and internal blob frames. Library IPC accepts only that exact window's trusted main frame and Library URL.

## Shared browser bundle

`npm run build:reader` writes `reader/dist`. It has no Node or Electron imports, and can be served by the native Mac custom-scheme handler.

```js
await window.StillleafReader.open({
  editionId: 'host-owned-edition-id',
  title: 'A book', creators: ['Author'], language: 'en',
  readingOrder: [{href: 'EPUB/chapter.xhtml', type: 'application/xhtml+xml'}],
  resources: [{href: 'EPUB/chapter.xhtml', type: 'application/xhtml+xml', dataBase64: '...'}],
  locator: undefined // optional serialized Readium Locator
});
window.StillleafReader.next();
window.StillleafReader.previous();
await window.StillleafReader.go(serializedLocator);
await window.StillleafReader.setPreferences({fontSize: 1.3, lineHeight: 1.6});
const bookmark = window.StillleafReader.bookmark();
await window.StillleafReader.restore(bookmark);
await window.StillleafReader.close();
```

DOM `CustomEvent('stillleaf-reader-event')` details expose `available`, `ready` (with warnings), `relocated`, `selection`, and `error`. Events carry editionId where applicable. Relocations have `cause: 'unknown'` and `eligibleForProgress: false` deliberately: reader events do not authenticate reading activity or credit time/pages. The separate trusted main-process timing adapter observes ready/focused reader windows and system idle/lock/power signals, storing counted and uncertain intervals atomically. Native host code must normalize/validate events rather than promote them directly to progress.

Resources are exact map entries, not arbitrary URLs. Publisher XHTML is sanitized in the browser; supported local assets receive generated blob URLs. CSS is parsed with css-tree, URL references are resolved only within the publication, and unsupported syntax/styles produce warnings rather than silently granting external access. Safe HTML structure, emphasis and simple publisher CSS remain. SVG/MathML, scripted content, embedded interactive media, CSS image-set/unsupported raw syntax and non-HTML spine entries are not fully supported. This policy requires broader adversarial/fidelity review before release.

## Evidence

Executed locally on **macOS**, Electron **44.4.5**:

- `npm test`: shared coordinator scenarios plus receipt persistence/corruption/path-boundary checks pass.
- `npm run test:desktop`: generated EPUB cold import, duplicate warm event, embedded PNG, one Library/no auto reader, explicit reading, retained local publisher CSS, page turn/bookmark API, absent reader Node/preload, hostile script suppression, persisted restart and invalid second-instance import all pass.
- Independent no-CSP browser network probe: unprotected session reaches the loopback witness; the production default-session filter blocks it. Exactly one positive-control request and zero protected requests were observed.
- All synthetic Electron windows remained hidden.
- `npm audit`: zero reported vulnerabilities at verification.

OS events are exercised through actual host listeners; no OS file-association installation was performed. No real Windows machine was used. The native WK proof lives separately under `../experiments/readium/native`.

## Remaining work before release

Windows hardware/accessibility/performance verification; installer/signing/file associations; packaged importer/runtime delivery; native menu/keyboard acceptance; seamless cross-chapter scrolling; full journal correction/merge/archive parity and migration UI; complete supported-EPUB fidelity and malicious-resource corpus; local cover overrides; mobile work. Library, completion-only Timeline, written personal Reviews, goals, manual records, automatic timing, durable reader state and per-edition state transfer are integrated locally. Independent screenshot review accepted the current reader/journal layouts; actual platform acceptance remains open. The prior journal is intentionally untouched. This slice must not be advertised as the finished reader.
