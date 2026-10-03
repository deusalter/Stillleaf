# Reading position, coverage and time

## Native EPUB reader

`EPUBReaderWindow` accepts renderer events only from its authenticated
main-frame shell and current edition. Increasing event sequence numbers reject
replays, and events older than three seconds are discarded.
`NativeReaderPosition` validates each chapter against the imported spine.
`position` events update `ProgressObservation` directly; AppModel's periodic tick
also reads the latest position. Native position never enters `PageTurnTracker`.

`ProgressObservation.source == "stillleaf-epub-location"` is reliable **chapter
position**. Its `location` is `Chapter N of M · Page X of Y`. Its `page` and
`totalPages` are nil: screen pages are only measured for the current chapter.
`fraction` is the trailing visible text offset (or chapter end on its last screen)
divided by actual text length
across the entire reading order. The denominator counts UTF-16 text units in
sanitized chapter bodies, excluding scripts/styles; chapters are weighted by
content length, never equally. This is a content position, not coverage read.
It is not a percentage of illustrations or typographic area.

The native host enables `contentProgress`. After the reader opens, it indexes
chapter markup sequentially with a yield between chapters, without fetching
referenced images, styles or fonts. Counts are cached by immutable edition hash
(up to 16 indexes per renderer lifetime), survive font/layout changes, and are
recomputed for new editions or new renderer processes. Loaded chapter bytes are
released after counting; no rendered DOM for the whole book is retained. Until
all chapters succeed, or for text-free books, fraction stays nil. The completed
index triggers a new position event. Consumers can show whole-book fraction
alongside explicitly chapter-local page X of Y; they must not label these as
whole-book screen pages. Reflow changes screen pages and position
labels, not the edition's text coordinates. Saved EPUB locators remain the
reopening source of truth; this change does not rewrite reader-state files.

A successful forward turn supplies its departure screen's UTF-16 text interval
within the sanitized chapter. The bridge delivers this directly to AppModel;
it does not reconstruct native turns by polling a synthetic counter. Eligible
turns get supporting time checkpoints and `pageTurn` audit events with optional
`content: {resource, lower, upper}`. Scroll mode uses the existing deliberate
full-screen movement gate. Jumps, restores, reflow, backward movement, and
image-only screens without a text interval do not add native content coverage.
Text coordinates describe traversal, not attention or comprehension.

## Coverage and rereading

`PageStatistics` rebuilds a range union per resolved book, tracking session and
coordinate system from surviving effective history. The same range cannot add
coverage twice within that session, even across brief pauses, repeated events,
query date boundaries, or reopening the history database. Display-group queries
pass all effective intervals for deduplication and use `within:` only to select
reported events afterward. The short-group visibility filter likewise resolves
coverage once across all groups before selecting rows. A separately started
session permits rereading; no lifetime maximum is used. The existing engine
resumes pauses up to 120 seconds, and starts a new session after longer pauses,
explicit stops, book changes, clock discontinuities or process restart. Restart
therefore intentionally establishes a new rereading scope, not a durable active
session continuation.

Native content ranges survive layout changes. A partly revisited screen adds
only the uncovered proportion of its screen-page count; fractional credits carry
within the chapter/session and are rounded down only when reporting whole pages.
For example: range 0–100 adds one; 0–50 after reflow adds zero; 50–150 adds half;
100–200 adds another half. The visible count becomes two, not four. These remain
screen-page equivalents, not publisher pages or fixed word-count units.

External Apple Books samples still need the bounded `PageTurnTracker` inference.
Its events retain the observed page range, layout signature, and (when known)
total. Learning a previously hidden total or hiding it again does not reset
coverage. 10→11→10→11 covers one page, while 9→12 after 10→11 adds two. Large jumps,
layout/total changes and long sample gaps rebaseline without backfilling.
External accessibility observations cannot map content across different layouts;
coverage is consequently scoped to layout/total, and cross-layout overlap is
unknown. New native and external events cannot race for the active source:
AppModel prioritizes the focused native reader and invalidates in-flight external
captures. Native/external page coordinates are not claimed to be interchangeable.

Time stays in `ReadingInterval.duration` / creditedSeconds. Native relocation is
not activity evidence in TrackingEngine. Existing foreground, pause, lock and sleep
rules remain responsible for time; elapsed time is never calculated from pages.
Manual page adjustments remain explicit corrections, separate from deduplication.

## Compatibility

No SQL migration, destructive rewrite or library/history deletion is required.
`PageTurnEvidence.content` and `totalPages` are additive optional Codable fields;
old events decode unchanged. Old external events with sufficient coordinates
are deduplicated when totals are recomputed, so inflated historical totals may
fall. Old synthetic native evidence cannot be converted into real text ranges:
it retains its old layout-scoped coordinates and is never fabricated/backfilled.
JSON exports retain the new fields. Existing CSV page columns remain raw event
evidence, not deduplicated totals, and omit content ranges; use JSON for lossless
history transfer. Older applications can ignore optional fields but will not
apply these coverage semantics and can overcount totals. Use the corrected
version for analysis; do not round-trip new content evidence through old builds.

Audiobook integration is independent: no BookRecord or ProgressObservation schema
changes here. Optional audio positions and listening creditedSeconds can be added
by the audiobook branch without conflating text screen pages and audio seconds.


## Native full-screen unit (renderer screen v2)

New renderer position/departure payloads explicitly carry `pageUnit: "screen"` and `visiblePages: 1`. A full facing spread, single-page screen, or continuous viewport is one reading unit. The native bridge's `NativeReaderPosition.forwardCoverage` produces one raw page with `layoutSignature: "stillleaf-screen-v2"`; its text interval covers all visible columns. Coverage-derived history/goals still award only the novel fraction of that one screen. Layout toggles generate no turns and do not modify audit records. Legacy positions without the marker and durable events preserve their previous interpretation. Text-range union remains shared across layouts and across the unit transition, preventing reread credit merely from a toggle.

The renderer footer now uses measured chapter-local screen geometry, explicitly labeled with the chapter number. Screen totals recalculate on reflow; a whole-book screen denominator is not available without measuring every chapter and is not approximated from text counts or unloaded placeholders. Book content fraction and canonical locators are independent of this display.
