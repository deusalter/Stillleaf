# Reader responsiveness and control review

## Changes

- Continuous scrolling keeps a text-geometry index for each laid-out chapter. Scrolling queries intersecting nodes; font, width, and chapter layout changes invalidate the index. Visible text boundaries still use exact range fragments.
- Scroll position bookkeeping is batched at 80 ms while the browser scrolls immediately. Sequential page evidence remains separate. Exporting or closing flushes the current location.
- Native reader notifications have a one-second leading/trailing gate. The latest position is retained immediately. A final position after focus loss or close is persisted through the existing deduplication rules without generating time or page credit. The ordinary tracking timer remains active.
- Rapid appearance changes coalesce into the newest pending layout, retaining cumulative settings and the reading anchor.
- Page-slide snapshots resolve loaded asset dimensions synchronously and retain one paint before display. Their standards mode and final text geometry must continue to match the live reader.
- The page turn is a 320 ms slide (150 ms when more turns are waiting) on `cubic-bezier(.3,.05,.12,1)`: it eases in from rest, so the first frame never jumps, and settles gently. Only `transform` and `opacity` animate; `will-change` is set only while a turn is on screen. The two chapter copies it slides are built once per chapter, in the background, after the page has been still for 350 ms, and reused by every turn, so a turn costs two frames of arming plus the navigation however large the chapter. The stage stays up for 160 ms after a turn so a held key or a quick second press reuses it. The garden is held still from the first frame of a turn until 300 ms after it, so vines never regrow mid-slide. Reduce Motion changes the page at once. Constants live in `SLIDE` (`src/page-slide.js`); `test/page-slide.test.mjs` holds the contract.
- The footer uses consistent book reference pages for both the book position and pages left in the chapter. Each chapter contributes at least one page, otherwise one per 1,024 UTF-16 text units. This is a stable reading reference, not publisher pagination. Screen geometry remains the basis of native page evidence.
- Book-format, audio-speed, book-selection, typography, sliders, focus switch, and shared menu/date controls use consistent styling while retaining keyboard and platform editing behavior.

## Evidence and limits

A headless WebKit fixture with 1,200 paragraphs and 90 scroll steps reduced text range geometry calls from 123,944 to roughly 3,000, and bookkeeping events from 187 to roughly 43. These are operation counts, not a hardware-independent frame-rate guarantee. Cache correctness is compared with an exhaustive visible-text oracle before and after reflow.

A deep single-paragraph reflow reduced bounding-rectangle reads from 19,735 to one, with the same restored locator; the supporting fragment queries remain logarithmic. Eight oracle scenarios cover clipped lines, columns, bidi, and whitespace.

A burst of 21 appearance requests resolves to one final layout and retains the target paragraph. Native gate tests cover burst rate, trailing deadlines, final-position deduplication, focus changes, and absence of additional activity credit.

Synthetic Library metadata aggregation was measured separately: approximately 0.6 ms for 61 books and 3,268 intervals, and 5.5 ms at ten times the intervals. Existing per-book page totals were already cached. No additional Library cache was introduced for this cost.

A paired WebKit page-turn comparison used the same 1,200-paragraph fixture with only the snapshot wait changed. Across six turns per variant, median preparation fell from 158.5 ms to 121 ms, and median complete turn time from 432.5 ms to 392.5 ms. Timing varies by machine and load; the regression gate is unchanged final text geometry.

## Review coverage

Source review and synthetic screenshots cover Library, book details, Today, History at all scales, compact History, Timeline, reviews, Settings, audiobook controls and logging, manual entry, the menu-bar panel, and onboarding. Reader checks cover appearance choices, narrow layouts, light/dark palettes, continuous reading, facing pages, RTL, XHTML anchors, saved positions, and annotation state.

Native screenshot generation supports a mode that does not present windows or activate the application:

```sh
.build/local/BooksPresence --render-ui .local/ui-review --offscreen
```

Use `--preview-filter audio-log,session-editor,history-compact` to select exact fixture names and `--layout-report` to inspect synthetic scroll-view geometry. Static offscreen captures disable entrance animations and use the installed dashboard's hosting-controller hierarchy with an explicit viewport; dedicated motion fixtures remain separate. Fixtures use disposable data and preferences. Headless browser tests and these native captures do not require control of the user's mouse, keyboard, or screen. They do not substitute for every native interaction or long-session test.

Run the renderer suite serially with `npm --prefix Reader/desktop/reader test`. WebKit geometry, appearance, scrolling, and preference regressions also run in macOS CI. Native tracking and persistence logic is covered by `ReaderProgressDeliveryGateTests` and the isolated EPUB smoke check.
