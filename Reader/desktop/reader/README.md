# Shared reading surface

Browser-only Readium UI. No Node references or privileged bridge. This directory is its own npm package: `npm ci && npm run build` writes `dist/`, which `scripts/build-reader-assets.sh` copies into the Mac build. `npm test` runs the headless interaction coverage in `test/`. Tests use installed Chrome (override `CHROME_PATH`) and generated text, with no user library or visible windows. September 24 local result: Chrome 153.0.8010.53 passed; this is not Windows or native WebKit evidence.

## Host contract

`window.StillleafReader.open({editionId,title,creators,language,languages,readingProgression,readingOrder,resources,state?,locator?,canReturnToLibrary?})` takes immutable resource bytes through the existing resource provider. `resources` entries have exact `href`, media `type`, and `dataBase64`; reading-order entries have `href`, `type`, optional `title`. Language and reading progression enter the Readium manifest; publisher document language, direction and markup survive sanitization. No vertical-writing conformance claim.

Methods: `next()`, `previous()`, `go(locator)`, `restore(locator)`, `bookmark()` (current locator), `addBookmark()` (toggle current saved bookmark), `annotate({locator,quote,note,color,id?})`, `setPreferences(partial)`, `exportState()`, `close()`. `open` rejects known fixed-layout metadata (`fixedLayout`, `layout`, `rendition.layout`) and non-HTML reading-order items with visible explanation. Imported data remains host-owned.

Listen on the top-level window for `stillleaf-reader-event`. Each detail includes `version:1`, `type`, `editionId`. Durable events use `type:'state', state:<full snapshot>`:

```js
{schemaVersion:1, editionId, revision,
 position: locatorOrNull,
 preferences: {theme:'system',fontFamily:'publisher',fontSize:1.2,lineHeight:1.6,measure:65},
 bookmarks:[{id,locator,label,createdAt}],
 annotations:[{id,locator,quote,note,color:'gold',createdAt,updatedAt}]}
```

Revisions increase for mutations/relocations; position events debounce120ms. Closing also emits the current snapshot without changing revision. Hosts must validate identity, sizes, paths and revision before atomic persistence. Hosts should flush current state before reopening the same edition. `exportState` is a close fallback. There is no persistence bridge inside publication frames.

Themes: system/paper/sepia/dark; fonts: publisher/serif/sans. Font size is a multiplier, line height a ratio, measure a preferred character count. Hydration preserves host ranges (.5–3,1–3,20–120); UI sliders intentionally offer a narrower comfortable range. Hydration preserves up to2000 records per collection,4096-character labels,32768-character quotes,65536-character notes, and exact locators for every supplied resource. Unsupported non-linear saved passages remain in state; jumping to one shows an explanation. Unknown stored highlight colors are retained and displayed using the default tint. Oversized collections/text reject visibly, rather than truncate and overwrite. Host validation is still required.

Other events: available, ready (sanitizer warnings), relocated (`cause:'unknown',eligibleForProgress:false`), selection, error, close-request. `canReturnToLibrary:true` enables Back and emits close-request; the host owns closing. Relocation is not evidence of deliberate reading or session progress.

## Implemented interactions and limits

Contents comes from reading order and chapter headings. Bookmarks jump/delete. Selected passages create highlights or notes; notes edit/delete. DOM selection stores exact range endpoints where available for decoration redraw. Appearance changes apply live. Search operates on sanitized chapter blocks, returns the first match per block, and caps at200 results. It is not a full-text indexing service. Escape closes dialogs and restores focus; tab controls support arrow keys. Page movement is not animated. Layout adapts to narrow and wide viewports.

The sanitizer preserves supported local raster/font/CSS assets and publisher semantics, while removing authored scripting and external resources. SVG/MathML and some original styling remain unsupported; the UI announces omissions. Readium frames execute trusted engine scripts; host network/permission/navigation isolation remains mandatory. Browser tests are not security proof for every host.

## Verification artifacts

`artifacts/reader-paper.png`, `reader-notes.png`, `reader-appearance-dark.png`, and `reader-narrow.png` are generated headlessly from synthetic text. Independent design review remains required before a final polish claim. The test checks navigation, real DOM selection and CSS Highlight range, notes/editing, bookmarks, search, appearance/reset, Escape focus, reopen, narrow overflow, fixed-layout rejection, no remote requests, exact durable hydration bounds and visible rejection of an oversized note. These tests do not establish Windows platform behavior, screen-reader conformance, complex-script pagination, full EPUB fidelity, or production progress accounting.

## Draft-safe host close (review revision)

Before any host closes/destroys a reader, reopens another edition, or flushes an export as part of teardown, call `await window.StillleafReader.prepareClose()`. A result of `false` cancels teardown. A result of `true` means no edited draft remains: the reader either had no dirty note, the user explicitly discarded changes, or Save changes applied the note to state. Hosts must still export/validate/persist that state and handle disk errors. `hasPendingDraft()` reports dirty editor status. `close()` also guards and returns a boolean; `open()` aborts if the previous editor cancels. Library invokes this guard before emitting close-request. Forced process termination cannot be intercepted by this promise.

X, Escape and backdrop all use the same Save changes / Discard changes / Keep editing dialog. Escape on the confirmation means Keep editing. `exportState()` never clears or resolves a draft and intentionally exports only applied annotations; it is not a substitute for `prepareClose()`. There is no host write acknowledgment protocol yet, so note feedback says “Note updated in this reader.” It does not promise durable storage.

The compact Library route remains visible when the host enables it, including narrow windows. Footer counts explicitly say Section; line width explicitly says About N characters. Short-height panels scroll and retain reachable actions. Additional headless artifacts prefixed `stress-` cover equal typography in paper/dark, selected toolbar and saved highlight, a long heading, italics, quotation, list, poetry line breaks, a local PNG/caption, linked footnote, narrow large type, short-height Appearance/note panels and the draft confirmation. The generated PNG is a small color study, not an external cover or publication asset.

## Portable navigation and return history

`open` accepts optional `toc`, `landmarks` and `pageList` arrays of `{href,title?,type?,children?}`. Targets are package-relative resource paths with optional fragments. Contents renders nested lists (up to12 nested levels), falls back to reading order when TOC is absent, and places landmarks/printed-page links in expandable groups. Unsupported local targets remain visible with an explanation when activated; external targets never load. Native importer and host pass these optional metadata fields through.

Saved locators may omit `locations.position`. A separate engine adapter derives the spine ordinal for Readium without mutating the supplied locator, fragment, text, CSS or DOM-range anchors. Initial hydration retains the saved position payload; later real relocation may replace the current position, while saved bookmarks/annotations remain untouched. This ordinal is a spine-section index, not pagination evidence.

Explicit `go`, Contents, search, bookmark and supported internal publication-link jumps retain up to100 previous in-session locations. The compact Return control (or `returnFromJump():Promise<boolean>`) goes back without adding another history entry. History resets on book open, is not persisted and does not claim reading progress. Footnote/fragment links within the reading sequence use this path; non-linear resource navigation remains unsupported and reports that limitation. Headless coverage includes position-free open/go/search/TOC, preserved stored anchors, nested navigation, landmarks/pages, footnote jumps and return.

## Page geometry verification

The reader now has an outer viewport that Readium measures directly:32px top/bottom inset on desktop and22px on compact screens. Its reduced height participates in pagination for every page; no heading translation or clipping is used. The outer width derives an approximate Latin text measure from requested size/measure and gutters, while remaining at most the available width. Publisher typography and non-Latin scripts mean this is an approximation. Low-specificity heading break-after avoidance supplies a default while allowing publisher break rules.

Local geometry checks: Chrome153 default frame687px, first prose line66characters,32px inset before/after page turns, compact22px inset. Offscreen native WK smoke/capture passed: desktop frame687px, narrow520px; paper/dark metrics reported paragraph width484.505px, Georgia computed16px, weight400, line-height25.6px. The native default screenshot first line is66characters. Computed font size alone does not include CSS zoom: Chrome confirmed body zoom1/1.2/1.5 and glyph heights22/26/33px respectively, while computed font size stays16px. Thus the default1.2 multiplier is visibly applied (effective19.2px font). Native scale-loop confirmation is a separate host check. Fresh native artifacts live under the worktree `.build/reader-native-review`.

## Three reading modes and advanced typography (M4)

Appearance now exposes **Continuous**, **Single page**, and **Facing pages** as explicit choices. State maps them to `scroll:true`, `scroll:false,columns:'one'`, and `scroll:false,columns:'two'`. Facing uses two actual Readium columns when the window is at least1100CSSpx wide; below that it uses one while preserving the selected mode. Continuous uses one column. The existing page inset and approximate measure apply to all modes. A small140ms perspective/opacity page-turn transition runs only for explicit paginated turns; reduced motion bypasses it.

Readium2.10.3 scrolls one spine resource at a time. The wrapper adds a deliberate boundary handoff on continued wheel/trackpad scrolling and vertical Arrow/Page keys: downward at the bottom opens the next chapter at its start; upward at the top opens the previous chapter at its end. The engine keeps adjacent resources cached, but this is not a single merged DOM with simultaneously visible chapter boundaries, and touch/mobile boundary behavior has not been claimed. No layout or boundary event is credited as reading activity.

The compact More reading options disclosure exposes text weight (original/400/700), alignment (original/start/justify), hyphenation (original/on/off), letter spacing and word spacing. Optional state additions are `scroll:boolean`, `fontWeight:null|100..1000`, `textAlign:'publisher'|'start'|'justify'`, `hyphens:null|boolean`, `letterSpacing:0..1`, `wordSpacing:0..1`, `columns:'one'|'two'`. Missing legacy fields default to false/null/publisher/null/0/0/one. Spacing units map to Readium **rem** values; the UI shows a percentage of the document root text size (0–100%). Arbitrary valid stored weight values remain visible as Custom. Publisher choices clear prior Readium overrides using explicit null. Italics and authored poetry whitespace remain intact in the regression fixture.

A retained semantic text/selector anchor survives mode and width changes, including a paragraph on the second facing page whose engine spread-start locator is zero. Explicit navigation/reading input updates it; layout recomputation does not count as progress. Reflow may place the retained passage elsewhere within the viewport; it does not promise identical pixel offsets.

Headless checks measure actual CSS effects (700 weight, justified alignment, no hyphens,1.6px letter/3.2px word spacing for .1/.2), publisher reset, two wide columns/one compact column, continuous scroll height exceeding viewport, both chapter-boundary directions, interior location retention, persisted advanced preferences with unchanged bookmarks/annotations, and page animation versus reduced motion. `artifacts/reader-facing.png` and `reader-continuous.png` capture the new modes. Native/Windows engine-host checks remain separate from this Chrome test.

## Gated seamless continuous adapter checkpoint

`open({...input, experimentalContinuous:true})` routes `preferences.scroll:true` through a separate browser-only continuous adapter. The flag is not persisted and is not enabled by production hosts yet. Single/Facing retain Readium. Existing state, dirty-draft guard, byte budget, annotation IDs and host event contracts are unchanged; relocation remains `eligibleForProgress:false`.

The adapter mounts at most eight independent sanitized, script-disabled chapter iframes in one native vertical scroll surface. Eviction retains measured-height placeholders and revokes chapter blob URLs; local CSS/font/image bases stay isolated. Requested and nearby chapters mount lazily. Saved DOM/text/fragment anchors, selection, CSS highlights, note activation, internal links, search/Contents targets and return history use the shared API. Reflow restores semantic anchors. A native caret hit-test fast path avoids scanning all preceding text during scrolling; fallback traversal and glyph probes are bounded.

`npm run build:reader && node --test test/reader-ui.test.mjs` passes in headless Chrome153. The additional twelve-chapter fixture proves boundary co-visibility, real wheel and touch-source scroll, frame eviction/remount, highlight/note persistence, typography, narrow reflow, mode handoff, internal-link return, rapid appearance changes and oversized-section recovery. `artifacts/reader-continuous-boundary.png` is the headless boundary capture. These are Chrome results; native WK and Electron custom-scheme proofs are separate required checks before enabling the adapter.

Current explicit limits: 8MiB source per continuous chapter,250000CSSpx chapter height,8millionCSSpx estimated/measured book height. Oversized sections show an explanation and can be read with a paginated mode; a failed jump retains the prior saved locator. Adjacent prefetch failures do not prevent a valid current chapter from opening. Placeholder heights are estimates until visited, so scrollbar extent can adjust as chapters mount; this is not a page count. Book resources remain subject to the existing256MiB publication budget. Very large/complex layout, vertical writing, cross-document selection, full assistive-technology traversal of evicted content and physical-device momentum remain unverified. The gate must remain until independent host, locator/security and long-book behavior review approves enablement.

Review hardening: frame bookkeeping is a WeakSet, with explicit unload deletion; a CDP forced-GC regression confirms sampled evicted windows are collectible after repeated jumps. This is bounded evidence, not a universal heap-size guarantee. Quote fallback now requires supplied before/after context to match and never substitutes a whole selector as a highlight. Injected appearance/highlight styles use element references, preserving colliding publisher IDs. Rendered body/descendant rectangles determine chapter height in CSS pixels; WebKit's already-zoomed scrollHeight is never multiplied again. Layout traversal rejects sections above20000elements.

An initial continuous mount failure restores a working paginated mode and retains personal state, with an explicit notice. Missing CSS Custom Highlight support triggers that fallback; on such older engines saved notes remain available in the Notes list/state, but visual decorations are unavailable in either navigator. The host minimum-version/fidelity review must account for that limitation. Regression covers missing API, oversized initial layout, preserved annotation payloads and no unhandled page errors.

## Appearance

`src/appearance.js` is the single table of page themes, typefaces and margins. Its ids are saved in reader state and whitelisted by the native validator (`ReaderStateValidation`), which has an XCTest that fails if the two lists drift; ids are never renamed once shipped.

- Themes: System (Stillleaf by day, Dark at night), Original, Stillleaf, Warm, Calm, Focus, Quiet, Dark and Night. The reader bar and panels take the page's colours. Night keeps contrast low and dims illustrations.
- Typefaces: Original (publisher), New York, San Francisco, Athelas, Charter, Georgia, Iowan, Palatino, Seravek and Times New Roman. Only faces installed on the computer are offered, detected by measuring text against the generic fallbacks; a saved choice stays visible even where it is missing.
- Margins: Narrow, Normal and Wide set the page gutter and the inset above and below the page. Page width follows the chosen line length measured in the chosen typeface.

`test/appearance.test.mjs` checks each theme's colours inside the book frame, the typeface list, margins, keyboard selection and persistence across reopen.

## Page evidence

The renderer reports `pageLayout` (a key per layout, and pages per turn: 1, or 2 for facing pages) and `pageTurn` (direction, pages, layout). Only deliberate sequential movement is a turn: paginated next/previous that actually moved, or one full screen of net scrolling in scroll mode. Contents, search, links, bookmarks, restores, reflow, resizes and multi-screen scrubbing never are. The Mac host keeps its own counter and samples it with the same bounded page-turn tracker used for Apple Books, so goals and streaks treat both sources alike. `test/page-evidence.test.mjs` covers these cases.
