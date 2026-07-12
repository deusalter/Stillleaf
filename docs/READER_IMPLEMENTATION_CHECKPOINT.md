# Integrated reader implementation checkpoint

Authority: user authorized full implementation of `STILLLEAF_FULL_READER_PLAN_2026-09-24_01a0d6c6.md`, after the prior queue completed. Main explicitly released the gate at `0e23ba631891e47a6e44da93ea888e548d184bfa`; CI 36097054289 passed 119 XCTest, release/native/package checks. Existing installed 1.5.0 build 17 is preserved.

## Release constraint

LOCAL ONLY until the full combined reader release is ready. No push, installed-app replacement, live-app relaunch, or Accessibility prompts. Isolated synthetic builds/tests/local commits/artifact preparation are authorized. Permission refresh is deferred and not a coding blocker. Never use real user books/history for destructive tests.

## Ownership

- Implementation lead: task 01a0d6c6-addd-75a0-a74e-7908d5857729, branch `codex/integrated-epub-reader`, isolated worktree `stillleaf-integrated-reader/Apple Books RPC`.
- Main tracker queue is complete; preserve its goals, unique-book yearly counts, personal reviews, spacious Timeline, rating motion, and idempotent current-date/time mark-finished behavior.
- Separate optional-date/calendar task will coordinate before integration. Do not compete in its files; default finished time stays actual action time and unknown start stays unknown.
- Monthly/yearly History visual refinement is low-priority backlog, behind reader work.

## Current stage

M0 executable comparison passed in macOS Chromium for both Readium 2.10.3 and epubjs 0.3.93; lead reran both tests. Readium additionally passes an isolated WKWebView custom-scheme harness (native delegate evidence; production policy integration still pending). Readium is the working Mac integration candidate, not a closed cross-platform M0 gate. Native network isolation, resource fidelity and real Windows/a11y remain open. epubjs patched xmldom requires rebuilding engine source; lockfile override alone does not repair its published bundle.

Baseline isolated direct Swift build passed; 7 smoke suites and 54 synthetic native layouts passed. No live app relaunch or real history access. New pure-domain import queue and navigation policy smoke passed after initial missing-type failure. XCTest equivalents added for CI later; not claimed run locally on this Command Line Tools host.

Two bounded delegates own `Reader/experiments/readium` and `Reader/experiments/epubjs` respectively. They may install local experiment dependencies and run synthetic browser tests only. Lead owns other files; date task shared edits are on a separate worktree for early cherry-pick. No concurrent changes to its shared files until integration.

## Additional settled requirements

- Built-in cover: explicit local override, otherwise explicit EPUB cover, otherwise local placeholder. Never online lookup/upload fallback.
- External tracking may look up/cache public covers optionally; preserve local/explicit choices and cancel stale mode requests.
- Library/Timeline/personal Reviews remain separate. Diagnostics/uncertainty are secondary. Empty automatic zero-page fragments do not clutter primary surfaces; preserve meaningful zero-page time/manual evidence.
- EPUB removal offers keeping a usable accessible file versus deleting/trashing the app-managed copy. Never silently delete external originals or history/reviews/annotations. External-only records have no misleading EPUB-delete option. Destructive behavior tested on fixtures only.
- OS Open With, cold/warm launch and batch/single import are Library-first: import all valid files into ONE Library window, never auto-open reader tabs/windows or start sessions. Preserve current explicitly started reader. Coalesce OS events, report partial failure/cancellation without modal spam, register support without changing system defaults. Finder/Explorer final integration checks remain pending combined release.
- Full plan remains authorized beyond initial usable slice. Real Windows/mobile hardware validation remains unverified; continue independent useful work while documenting those gates.

## Milestone ledger

- M0: active; isolated baseline and comparative fixture readers.
- M1–M5: pending (foundation, both desktop readers, journal/annotations, customization/quality, release hardening).
- M6: mobile roadmap/implementation and device gates pending.
- M7: separately selected extension scope, as defined in plan; no store/DRM/cloud claims.

## Latest local work

- Immutable bounded ReaderResourceMap and native scheme handler added; path/type/size/session-isolation smoke passes. Network configuration and navigation guard added, compilation/host integration in progress.
- Engine-independent safe ZIP/publication importer in Reader/packages/publication underway. Native Readium experiment now testing host network enforcement beyond sanitized fixtures.
- Optional calendar commit 1e66d033a37d68a7fec388a0dbe429b8642a7222 ready for early cherry-pick, agent reports optimized build/eight smoke/native UI/light-dark previews passing.
- Separate website task 01a0d700-6a37-7b90-9d61-ced581f4b0a6 owns website/ in its isolated worktree; local only and unverified reader downloads disabled.

## Integration checkpoint (continuing)

- Calendar integrated as a85a967; combined optimized build + ten portable smoke suites + 58 synthetic native light/dark layouts passed before subsequent reader wiring.
- Website integrated as 2e21817; user explicitly likes original design. Website task owns a positioning/scroll-motion follow-up, preserve visuals and unavailable-download gates.
- Native safe ZIP importer and asset-removal services implemented with fixture tests. Adversarial native review found managed-original integrity, superscript device aliases, and XML root validation gaps; fixes landed locally and tested. Cross-platform Node importer 38 tests, audit zero.
- Mac AppModel owns EPUBLibraryController (serial imports/recovery, one Library, journal registration without sessions), Library import/status/read/remove UI, AppDelegate cold/warm Open With handler and alternate EPUB document registration. Full combined verification of latest wiring still pending.
- EPUBReaderWindow loads the shared bundle with production resource/network policy and main-frame/session-token bridge. Actual offscreen native import/render/location-save/chapter-restore test passed. Correctness fix: wait for renderer available handshake, and return non-null value from WebKit async evaluateJavaScript (CLT overlay traps for JS undefined). No installed app launched.
- Native reading source branch now precedes Apple Books Accessibility gate; source arbitration/activity evidence still needs focused verification. No reflow page credits are implemented.
- Electron host import/read/restart + publisher CSS + bridge isolation + network positive control tests pass hidden on macOS. Real Windows unverified.
- Full state schema integration underway: schemaVersion1/editionId/revision/position/preferences/bookmarks/annotations, stored outside managed assets. Native validation being aligned to JS contract by mac_publication_import agent; root owns native bridge hookup.
- Renderer refinement agent owns Reader/desktop/reader plus reader-ui.test.mjs. Windows persistence/removal agent owns desktop/src and host tests. Native state agent owns ReaderStateValidation/ReaderStateStore and state tests. Root owns other Swift/app/build/docs.
- Shared reader product appearance remains under active refinement, not approved. Independent design task supplied explicit typography/themes/controls/selection/a11y acceptance guidance; real integrated screenshots/interaction review pending. All future synthetic windows hidden or offscreen after user reported distracting crude harness previews.
- Local Swift resource/script build helper and package copy wiring added; use BOOKSPRESENCE_SKIP_READER_BUILD=1 for native iterations against a known copied bundle while renderer agent edits source. Do not race shared bundle builds.

## Durable state and independent review checkpoint

- Website follow-up integrated as 475fbf2; website owner now extending scroll showcase, download availability remains gated.
- Native import/removal/state smoke suites pass, including unsafe archives, managed-only removal, backup recovery, stale-state refusal and strict domRange validation. Optional languages/readingProgression metadata is backward compatible and passed through to renderer.
- Combined native bundle build succeeded. Actual offscreen EPUB app smoke passed Library-first duplicate import with no sessions, scoped rendering, authenticated state persistence, immediate close saving a 65,536-character note and bookmark, then exact-length restoration. This is synthetic evidence, not live activity/device acceptance.
- Shared renderer headless suite preserves 2,000 bookmarks and maximum-length stored labels/notes/quotes, rejects oversized restore payloads without rewriting them, and retains non-linear locators. Non-linear navigation remains unsupported.
- Electron host delegate passed 16 store/host tests, 38 publication tests and hidden Electron/macOS import/read/reopen/restart/remove/network integration. Actual Windows execution remains unverified.
- Independent designer reviewed four rendered screenshots: visual direction credible; final acceptance withheld. Actionable fixes underway: unsaved note draft protection, narrow Library route, clearly labeled section counter, richer typography/stress corpus and host durable-save feedback. Native and Electron close paths now being wired to shared async prepareClose guard; this newer close change needs verification.
- Next bounded delegates: shared reader review fixes; native portable per-edition state transfer (not full archive); Windows SQLite journal foundation (not full parity). Root owns host integration, close tests and source arbitration. All work remains isolated/local; no pushes, installed-app replacement, live relaunch or visible test windows.

## Verified combined host checkpoint

- Optimized native build passed after async draft guard and Library state-transfer actions were wired.
- All 14 Swift portable smoke suites passed; local check script now includes reader/date/import/removal/transfer suites. 58 synthetic light/dark native layouts also passed. No real history read or live diagnostic requested.
- Actual offscreen native app test passed Library-first import, exact long-note persistence, native close -> Keep editing cancellation, then Save changes -> durable close. Hidden Electron test also passed book-switch cancellation with draft retained.
- Independent designer accepted the seven stress screenshots at renderer level. A further annotation-limit save exception was fixed/tested in shared renderer; host integration needs the freshly rebuilt assets copied before claiming that exact bundle.
- Reading-state export/import Library actions close and flush reader, block same-edition read/removal during transfer, and show an explicit replacement preview. This is per-edition JSON transfer only; no whole-library merge or cloud sync claim.
- Continuing navigation fidelity (real TOC/landmarks/page-list metadata, sparse locator restore/history), Windows SQLite journal foundation and website showcase. Actual Windows/mobile/accessibility/fullscreen release gates remain open.

## Native geometry and integration review

- Foundation committed locally as10934de. No remote or installed-app changes.
- Independent native WK screenshot review accepts corrected page-top/bottom insets (32 CSS px desktop/22 compact), roughly66-character default measure, and narrow layout. Headings get low-specificity break avoidance without replacing publisher text. Native metrics confirm fontSize1/1.2/1.5 uses body zoom1/1.2/1.5 over Georgia16px, so default effective size19.2px; no forced weight change.
- Native review found merged editions losing actions, manual external cover requests during built-in reading, and Quit allowing new readers during a pending draft decision. Canonical merge lookup/edition chooser, pre-manual cover cancellation/lookup gate, and a termination barrier added. Offscreen smoke passes merged-EPUB reachability without session credit, concurrent-open denial during Quit, canceled Quit unlocking, and Save draft persistence. Immediate focus cancellation callback added afterward, pending next combined compile.
- Node publication parity now55tests and adds EPUB3/NCX/guide navigation/reading progression; old receipts remain supported.
- Windows journal foundation and initial shell passed27 Node tests plus11 embedded-Electron SQLite tests/expanded hidden flow. Independent review requires completion-only Timeline, written-review-only Reviews, quarter-star controls and calmer cover-led hierarchy; worker is refining these before acceptance. Screenshots are macOS Electron artifacts, never claimed Windows execution.
- Advanced optional reader preference contract/control work underway across native and Node validators, transfer, shared renderer. Root holding native bundle until stable integration.

## Three modes, timing, and journal integration

- Website final continuous showcase integrated locally as4dc02a7. No push/deployment; downloads remain gated.
- Explicit single-page/facing/chapter-scroll and advanced weight/alignment/hyphenation/letter/word controls pass combined hidden shared UI, Electron host and curated journal tests (3suites17.86seconds, macOS). Facing falls back to one column narrowly without changing preference; semantic anchor, notes/bookmarks and reduced-motion behavior verified in Chromium. Cross-chapter co-visibility remains missing: installed Readium displays one spine document. Isolated continuous adapter prototype underway; do not claim seamless scrolling yet.
- Optimized native combined build and actual offscreen synthetic EPUB smoke pass with current modes bundle, canonical edition lookup, Library return callback, external cover focus cancellation and Quit barrier. Native mode-specific assertions are being added.
- Journal schema2 uses validated pre-migration backup and atomic interval/event batches. Host samples ready/focused visible reader and system idle/lock/power signals; layout/locator events never credit pages. Counted time contributes to civil-day goals, uncertain time remains separately visible. Display-only sleep and actual Windows power behavior remain unverified.
- Review caught ISO persisted watermark versus numeric timing-clock mismatch. Host converts once at boundary; restart regression proves prior saved time is not credited again. All34 journal tests pass in Electron embedded Node onmacOS, including schema2 migration/recovery and timing.
- Independent screenshot review accepts facing/continuous reader, final prominent Timeline dates, Goals/Manual forms and counted/uncertain Records without blocking visual findings. This is artifact acceptance only; actual Windows/native chrome/fullscreen/AX and mobile remain open. Nonblocking Goals inactive-value clarity suggestion remains.
- Windows completion-date UI is next bounded parity task. Full archive, correction/merge/reread workflows, publisher-fidelity cases, production packaging and mobile remain incomplete. Release hold unchanged: local isolated work only; installed app and original checkout untouched.

## Durable host commits and publication fidelity

- Local commits:2ff628b three modes/preferences; c948439 journal persistence; f1a5f6e idle quantization fix; da11a1f native host;27a2ef8 desktop host/completion dates;36f0132,c3465ea,f0c5c35 standard IDPF font import. No remote actions.
- Native mode assertions passed actual WK: wide1280 CSS2, narrow520 CSS1 retaining facing preference, continuous readium-scroll-on with scrollable geometry, finalsingle CSS1.65536-character note, bookmark, full preferences and chapter survive switches/reopen. Metrics under.build/native-mode-review; no real history sampled.
- Desktop completion editor handles optional dates, explicit clearing, exact unchanged timestamp retention, local-clock DST changes, stale editor rejection and failed-save draft retention.4timezone tests plus hidden editor/host/curated flows pass; independent date screenshot review finds no blocking issues. Combined desktop/journal CJS tests58pass.
- IDPF font support changes only extracted font resources after ZIP checks; source/managed original EPUB and edition hash unchanged. Native importer smoke and77Node publication tests pass including hardcoded independentSHA1 vector, XML whitespace, short/1040 boundary/long fonts, stream splits and unsafe/ambiguous/nonfont rejection. Other encryption methods remain unsupported. Font rendering across every host is not established by byte tests. Shared resource MIME addition application/font-sfnt requested from renderer owner.
- Isolated seamless continuous proof passes headless Chrome: simultaneous adjacent chapter text, native outer wheel/touch-source traversal, independent CSS/IDs, exact glyph-offset restore onresize, no remote/authoredscript execution. Production adapter work active with bounded mounting and full reader feature parity required before acceptance. Current stable native copied bundle still uses chapter boundary handoff.
