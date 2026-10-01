# Reader selection annotations

Selecting text opens a compact popup at the passage with Gold, Sage and Rose highlights and Add note. Existing highlights open the same popup for recoloring, note editing and removal. The toolbar's Highlights and notes button opens the existing saved-passage panel directly on Notes. The panel uses existing queued locator navigation and return history.

Notes save after 180 ms of idle typing, immediately on color changes, and synchronously before note dismissal, host prepareClose, or exportState. Add note immediately creates the anchored highlight. Done finishes editing; a Save action is unnecessary. Existing storage-budget and collection-limit failures retain the draft and existing guard choices rather than dropping content. Hosts still receive the existing revisioned `state` event and close-time snapshot.

## Persistence and location

Schema version remains 1. Reuse annotation IDs, createdAt, edition identity and the publication-bound locator. Editing an existing annotation keeps its original locator even if a caller passes a different one. New selections capture DOM endpoints plus nearby text context for quote fallback. Saved reading position and annotation locations do not use new displayed page numbers. Existing annotation data is not migrated or rewritten. Locator text is bounded to 16,384 UTF-16 units. Longer selections retain complete DOM endpoints and a bounded quote preview; text/fragment fallbacks are omitted so an invalid endpoint cannot highlight a partial or unrelated passage. New long ranges explicitly set `locations.domRangeIndexing` to `text-nodes`, matching Readium. Unmarked saved endpoints keep their original all-child indexing. Native and desktop persistence retain the optional marker. Paginated decorations receive plain serialized locators, with legacy endpoint conversion only in the renderer representation; the saved locator stays unchanged.

## Shared reader interfaces

- `main.js`: imports and instantiates AnnotationUI; supplies mounted frame/href pairs, annotations and navigator mode. Wires selected text, decoration activation, save/delete, lifecycle reset, note autosave and the saved-passages button. Updates annotation display and the existing Notes panel.
- `continuous.js`: resolves legacy all-child endpoints and explicitly marked text-node endpoints. The annotation UI consumes its exported `locatorRange(doc, locator)`, `entries[].frame`, `entries[].link.href`, and `kind === 'continuous'`. It uses the existing `personal` decoration observer through main.js. No measurement, remeasure, scroll-reporting or page-counting edits.
- `annotation-ui.js`: caches resolved ranges per mounted frame, drops bindings when a frame's document changes or unloads, and coalesces geometry updates with requestAnimationFrame. Selection ranges survive parent popup interaction. Keyboard Tab enters the popup; arrows move among actions; Escape dismisses and returns focus to the chapter. Clearing the native selection prevents iframe keyup from reopening a dismissed popup.
- `index.html` / `reader.css`: compact popup, saved-passages toolbar button, autosave status and external margin layer. No publisher-document nodes are inserted.

Wide continuous layouts place notes outside the reader viewport, alternating left/right and packing collisions within the viewport. Long notes show a short excerpt and open the full editor on activation. When either margin cannot fit 150 px, or notes exceed the available vertical room, a compact note-count control appears in the space above the text and opens the saved list. Resize, delayed-image size changes, scroll, mount/unmount and reflow refresh placement. Selection popup is hidden when its passage leaves the viewport. Themes use existing chrome variables. Transitions honor Reduce Motion. Quotes and notes use textContent.

## Cloud validation

Linux cloud workspace, main baseline `58ee97fb6ddcb37a67a93f9fed926bf570927de3`, Chromium 141.0.7390.37.

- `npm --prefix Reader/desktop/reader run build`: passes.
- New `annotations.test.mjs`: passes selection across text nodes, anchored placement, all highlight colors, stable IDs/locators/creation timestamps, automatic save, safe markup-like text, both margins, narrow fallback outside text, editing/removal, queued jumps after chapter eviction, keyboard focus/arrows/Escape/click-away, theme/font/layout changes, reduced/default motion and reload restoration.
- Updated shared UI regression: passes existing contents/bookmarks/search/appearance/navigation and automatic saves on close/Escape/backdrop/host prepareClose. Retains storage-limit failure and draft-preservation tests.
- Reader suite: 30 of 32 pass. Two failures also reproduce in a separate, unchanged `58ee97f` worktree: continuous parity synthetic touch gesture moves less than its expected 700 px; visible-text exhaustive comparison returns final offset 2196 versus 2197. Neither implementation is changed in this branch.
- Filesystem-backed `reader-state-transfer`, `appearance-state`, and `library-store` suites: 17 of 17 pass, including DOM-range persistence across restart, revision rejection, backup recovery, portable state and retention of annotations on removal.
- Screenshots in `Reader/desktop/reader/artifacts/annotations/` were visually reviewed for light/dark selection, both margins, narrow layouts and saved notes.

## Mac validation gaps

No user's Mac, running app, personal books, OS permissions or installation was accessed. The user must validate the combined native build in WKWebView: real pointer/trackpad selection, keyboard focus across iframes, WebKit CSS Highlight support, IME/VoiceOver, native close/restart persistence and both reading themes. A single annotation covers a selection inside one chapter document; browsers do not supply a native range spanning separate chapter iframes. Host persistence acknowledgments are unchanged; the renderer's autosave status means its state snapshot was emitted, not that a new host write-ack protocol was added.

Merge only after coordinated review with the continuous-scroll/page-counting, History and onboarding branches.
