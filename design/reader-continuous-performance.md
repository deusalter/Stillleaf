# Continuous geometry and full-screen page units

## Result

Continuous measurement now batches dirty chapters instead of measuring every mounted chapter on any body/image notification. Real container reflow still dirties all mounted chapters. Body ResizeObserver deliveries compare dimensions, while body mutations, image load/error and font completion invalidate internal geometry independently of total chapter height. Cache revisions invalidate immediately when dirty and again after height measurement. The iframe-collapse/WebKit extent safety check remains intact.

Caret hit-testing remains the first anchor path. Its fallback uses the shared indexed text candidates and exact visible fragments, avoiding offscreen paragraph-prefix scans. Chromium's grouped-range omission of a wrapped trailing space is corrected with a bounded adjacent-whitespace check. Exact fragment tests cover bidi, graphemes, columns and clipping.

Every newly reported screen is one page in single, facing and continuous modes. Seven leaves are four facing screens; the last partial spread is one screen. Page-layout identity still distinguishes actual columns and reflow. Integration adds exact whole-book layout totals through a bounded background measurement cache; the footer labels chapter-local counts and “Calculating book pages…” until it completes. Fonts, widths, heights and modes recalculate these counts. Canonical book text coordinates and locators are independent of the display. See [SCREEN_LAYOUT_PAGINATION.md](../docs/SCREEN_LAYOUT_PAGINATION.md).

## Native evidence and compatibility

Changing `pageTurn.pages` alone is insufficient: `EPUBReaderWindow.receiveProgress` derives durable coverage from `departure` via `NativeReaderPosition.forwardCoverage`. New positions explicitly carry `pageUnit: "screen"`, `visiblePages: 1`; native conversion validates this and emits one-page `stillleaf-screen-v2` evidence covering the entire departure text interval. No bridge event handler, history storage, `PageTurns.swift`, or range-union algorithm needs alteration. `ReadingCoverage` weights the novel fraction by `pagesRead`, so goals and history receive the same one-screen unit and still deduplicate content across reflow. Legacy payloads keep their old conversion; persisted evidence is never rewritten. Coverage tests exercise one-screen conversion, statistics, partial rereading, encoding and legacy/new overlap.

## Measurements

Cloud Linux, Playwright Chromium 141 and WebKit 26; unchanged main `58ee97fb6ddcb37a67a93f9fed926bf570927de3` versus this change. The fixture mounts four chapters of 1,000 paragraphs each at 1000×800, changes one offscreen chapter, moves text internally without changing chapter height, disables native caret APIs, then scrolls 60 animation frames deep in the chapter. These are instrumented single-run samples; timing reflects this host, fonts and scheduler, and is not a claim about Mac WKWebView or a user's EPUB.

| Measurement | Chromium before | Chromium after | WebKit before | WebKit after |
| --- | ---: | ---: | ---: | ---: |
| Settled idle element/range reads | 0 | 0 | 0 | 0 |
| Changed-chapter element reads | 4,004 | 1,001 | 0* | 2,002 |
| Subsequent same-height mutation element reads | 0 (missed) | 1,001 | 4,004* | 1,001 |
| Deep fallback range bounds reads | 1,859 | 550 | 1,561 | 588 |
| Deep fallback range fragment queries | 11,240 | 1,620 | 11,477 | 1,629 |
| Frame interval median, ms | 16.7 | 16.7 | 16 | 16 |
| Frame interval p95, ms | 23.2 | 17.4 | 39 | 23 |
| Frame interval max, ms | 39.1 | 17.7 | 44 | 24 |

*Baseline WebKit deferred the offscreen body notification into the next phase, where it measured all four chapters. The new path measured only the dirty chapter in two converging passes. Thus the baseline phases cannot be compared individually as synchronous image measurements. Unchanged main also had no idle scans: a perpetual observer loop was not reproduced. The demonstrated issues are broad invalidation on dirty events, same-height cache correctness, and deep fallback work.

Reproduce with `test/continuous-layout-performance.test.mjs`. Run it against a build of unchanged main with `READER_BASELINE=1` (copy only that new test into an isolated main worktree), then against the changed build; repeat with `SCROLL_BROWSER=webkit`. Baseline mode gathers diagnostics before the new regression assertions. The after test additionally checks exact visible content, deep text anchors, delayed-image anchor retention, dirty scope and same-height invalidation.

## Shared-file ownership

The original source commit changed the page-progress import, `updatePosition`, the `contentPosition` payload, `pagesPerTurn` and `layoutKey`. Cloud integration subsequently reconciled annotations in `main.js`, corrected note-only repainting and style-load invalidation, and added whole-book pagination. Original source measurements above remain measurements of the source commit, not the later combined implementation.
