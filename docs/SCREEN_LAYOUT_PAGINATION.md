# Whole-book screen pagination

The footer sums measured chapter screens for the current layout. One facing
spread is one screen, including an odd final leaf. It never shows a
“calculating” notice: until every chapter is measured it shows an estimate
(`data-pages="estimate"` on the label, explained only in its tooltip) and
replaces it silently.

`ScreenPaginationIndex` keeps up to sixteen layouts per open book. Keys contain
edition, viewport width/height, actual column fallback, the typography and
layout settings, continuous versus Readium renderer, and a renderer version
(`screen-v2`). Colours and image dimming cannot move a line, so they are not
part of the key: changing theme keeps the counts. Live measurements populate the
index first. Missing chapters are measured three at a time in inert invisible
renderers at the same viewport, with the same resource sanitizer and fonts,
chapters before the reader's place first. Images and fonts settle, then the
extent is read once it holds still across a frame. Work yields between chapters
and pauses for two seconds after reader input (wheel, key, pointer, a page
turn) and during layout changes; the reader's own relayout scrolling does not
count as input. A chapter that cannot settle keeps its estimate; a later live
measurement can complete its count.

### Saved maps

A finished layout is emitted as a `pageMap` event (`{key, counts}`). The Mac and
iOS hosts keep the twelve most recent per book in `ReaderState/PageMaps/<edition>.json`
(`ReaderPageMapStore`), separate from reading state, and pass them back as
`pageMaps` when the book opens, so a reopened book shows its exact count on
first paint and lays out nothing. The file is a disposable cache: malformed,
mismatched or damaged entries are ignored and counted again. A saved map is
trusted until a live chapter measures differently (a WebKit or font change);
then every other chapter is measured again, keeping its saved count meanwhile,
and the corrected map replaces the saved one.

### Estimates and a stable footer

`estimateCounts` fills unmeasured chapters, in order of preference, by scaling
another complete layout of the same book by the chapters measured in both
(keeping each chapter's own shape), or from each chapter's text and
illustration count calibrated on the measured chapters (one-screen chapters do
not calibrate). Before the text index is ready, chapter byte sizes stand in for
text; with no text measured yet (a cover), a geometric screens-per-character
fallback applies. A chapter being measured again, or the live chapter before
its images settle, keeps its latest count.

`StablePageCount` decides what the footer shows. A new layout's count appears
once exact or once its estimate rests on at least 40 measured screens, and at
the latest after 300 ms when a book opens or 900 ms when the footer already
shows a page it can keep; a move by the reader ends that hold. Afterwards a
better count is adopted only together with a move the reader makes, and only
in its direction, so the number never changes on its own and a forward turn
never shows a lower page. On synthetic books the shown estimate is within about
1.5% of the exact count.

WebKit suspends frame handshakes far outside the window, so the transparent
measurement surface sits behind the UI within the window. It has no pointer,
keyboard or accessibility input; its frames remain outside the live reader.

Probes have no annotation decorators, selection callbacks, state callbacks or
reading-evidence listeners. Every annotation/frame query remains scoped to the
live `#reader`. They cannot steal keyboard focus. A changed layout aborts stale
measurements. Each probe owns an independent resource view with cancellable
requests; close aborts its work and bounds renderer teardown even if a frame
handshake never completes. Late continuations cannot access the live owner.
Continuous probes share the live scroll container CSS, including scrollbar
geometry. Content mutations and publication resource completion invalidate
affected measurements. Paginated counts become calculating as fonts or images
start loading, then update after assets settle using the constant-cost extent. Note-only saves retain cached highlight ranges;
highlight styles do not invalidate publication geometry.

Displayed whole-book pages, estimated, exact or saved, are independent of
durable locators and native evidence. Native positions retain chapter-local
screen units and canonical text coverage, and page maps never enter reading
state. Background completion, refinement, resizing, font changes and mode
changes emit no reading turns and rewrite no historical evidence or annotations.
`page-count-progress.test.mjs` reads the same book with a fresh estimate and
with a deliberately wrong saved map and requires identical positions, page
evidence and saved state.

`scripts/measure-page-count.mjs` times the footer for small, typical and large
synthetic books in each mode, across resize, type, spacing and theme changes and
a reopen.

Tests cover unequal chapter counts, odd spreads, cache reuse, stale font/viewport
generations, incomplete resources, both renderer modes, actual two-chapter
Readium totals, narrow facing fallback, continuous measured totals, focus,
closing during a deliberately stalled resource, switching books, asset-start
invalidation and live/probe scrollbar geometry. The native smoke additionally
checks rejected-save close cancellation and autosaved durable close. Synthetic
cloud tests do not replace the user's final test with their own EPUBs on macOS.
