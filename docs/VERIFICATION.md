# Verification report

Date: 2026-09-17. Host: Apple Silicon, macOS 26.0.1, Apple Books 8.0. The source and development bundle target macOS 13+.

The passed local and CI entries below are the previous baseline. That baseline recorded 56 XCTest cases passing on macOS CI. The page evidence/pace, finished-metadata, ratings, automatic public-cover resolver, and latest Discord payload regressions were added afterward and are **pending a fresh local/CI run**; they are not claimed as covered by the prior result.

## Executed locally

| Check | Result |
|---|---|
| Direct full native build (`scripts/build-local.sh`) | Passed with installed Swift 5.8.1 / macOS 13 SDK |
| Core behavioral harness (`scripts/core-smoke.swift`) | Passed: timing, pause exclusion, recovery, correction/deletion, import idempotency/atomicity, backup/restore, DST and goals |
| Discord protocol harness (`scripts/discord-smoke.swift`) | Passed: supported payloads, Unix seconds, image-key filtering, fragmented/multiple frames and clear framing; no real publish |
| Native model/view check (`BooksPresence --self-test-ui`) | Passed: isolated synthetic manual addition, split/delete preservation and Today/History/Library/Review/popover view layout; no screen capture |
| App packaging | Passed; app includes both linked libraries and diagnostic |
| Signature / launch | Ad-hoc `codesign --verify --deep --strict` passed; app process launched |
| Duplicate process | Second packaged launch exited while first kept its file lock |
| Books catalog | Read-only schema checked, exact file-path lookup matched one stable asset |
| Exact local artwork | One existing Books-associated cover resolved, was cached and decoded successfully; temporary personal test artwork was removed |
| Initial display/session state | Awake and unlocked observed; a later natural locked/asleep state and return to awake/unlocked were also observed by the diagnostic |
| Accessibility trust | **Unavailable to the diagnostic/tracker process** in current runs |
| GUI control automation | Computer-use service timed out; no click-through or screenshot result claimed |

Local `swift test` cannot execute because this Command Line Tools installation lacks XCTest and SwiftPM's SDK PlatformPath support. The assertion harness is a separate local check, **not a substitute claim that XCTest ran locally**. The previous macOS CI baseline recorded 56 XCTest cases passing, the release build, development app packaging and artifact upload. It predates the new page/history/rating/public-cover and latest Discord regressions; consult the repository Checks tab for the fresh branch result.

## Important review fixes

Independent review identified and implementation corrected: split/reassignment deletion resurrecting originals or deleting unrelated siblings; wall-clock ordering of corrections/goals/merges/recovery; backward-clock interval overlap; unsafe backup over the live database; zero-minute imported goals; loss of cached covers on transient access failure; incorrect Discord timestamp units and IPC partial-frame handling; app-ID changes and status reporting; reversed pause control; missing daily traceability; and private data-directory permissions. Focused regression checks cover the core cases.

Duplicate-ID checks compare canonical serialized records so fractional timestamp round-off cannot turn an identical retry into a conflict. Regression coverage includes a known non-exact `Date` round trip, repeated event/interval/correction insertion, repeated JSON import, and adjacent submillisecond intervals. The archive keeps its original fractional-millisecond timestamp representation.

Checkpoint insert validation uses an in-memory ordered effective-interval cache, avoiding a full-history decode for each checkpoint. Calendar totals split intervals in one pass. Presentation refreshes at checkpoint cadence while active and on state/day changes while paused. Very large archive presentation/import/restore remains synchronous and has not been stress-tested at multi-million-record scale.

## Calendar and settings revision

The revised UI uses an appearance-aware plum/copper palette, bounded month/week/day/year calendars, rectangular year cells, native switches, and stable Reading/Discord/Data settings tabs. Calendar navigation has eleven new XCTest regressions for leap days, six-week grids, selected dates, DST, timezone changes and cross-year labels. The standalone calendar harness passed locally alongside the existing storage and Discord harnesses.

The native self-check instantiated eleven primary view configurations in both light and dark appearances. App-owned views were also rendered to PNGs with an isolated synthetic database, and the month/day/year/settings layouts were visually inspected. This needs no screen-capture permission and does not touch personal history. The computer-use service remained disconnected; live click-through, animation smoothness and VoiceOver operation are not claimed as verified. Navigation animations respect Reduce Motion, and sidebar keyboard navigation and selected-control semantics were independently reviewed in code.

Review corrected an inclusive calendar end boundary, labels using the wrong timezone, preferred-day loss after February or timezone changes, low-contrast year cells, a misleading privacy footer, settings selection semantics, and failed login registration leaving the switch in the requested rather than actual state. Local builds and scoped independent review passed; the repository Actions result records the pushed revision's XCTest outcome.

## Bounds and recovery semantics

Within supported operation, ticks are no more than five seconds apart. Checkpoints occur at 15 seconds of accumulated time, so a crash's uncommitted tail is less than 20 seconds under that cadence. A tick gap exceeding five seconds is an outage; that gap is not credited. A persisted start/checkpoint without a closing marker produces a recovery event with an **unknown** tail duration, never estimated downtime.

If the wall clock moves backward behind previously recorded time, tracking holds with a clock-discontinuity reason until placement can resume without overlap. This may leave a visible gap; it does not invent trusted wall-clock durations or stop with a database-overlap error.

## Checks still requiring user/device interaction

- Grant BooksPresence its own Accessibility permission, then verify an EPUB and PDF reading window, Books library/store, two simultaneous book windows, window closure/minimization, foreground switching and permission revocation. The AXDocument-based rule is deliberately conservative and may leave some Books reader implementations unsupported.
- Active-reading lock, sleep, wake and fast-user-switch transitions end to end. Diagnostic state changes alone do not prove correct timing at every real transition.
- Live page-observation coverage across supported Books 8.0 English layouts, including small forward movement, one/two chapter-container states, stable shared reader-host bounds and window/layout changes. Saved catalog progress remains explicitly unreliable.
- Visual screenshot, accessibility/VoiceOver and click-through review after the computer-use service is available. Native view layout checks do not establish visual polish on every display.
- Login after an actual logout/reboot, persistence of permission with a Developer ID-signed install, and uninstall from an installed app location.
- Discord READY/publish/render/clear/reconnect with the user's own valid application ID and developer asset. No account token, self-bot or modified client is used.

No iPhone/iPad backfill, artwork upload, or live Discord rendering result is claimed. Automatic public-cover lookup is opt-in and metadata-only; the pending checks below cover its new resolver path. The app is a development build, not notarized.

## Data-handling notes

Only synthetic fixtures are committed. Personal catalog paths/titles/artwork and diagnostic output stay outside Git. After relaunch, `stat` verified support-directory mode 0700 and database/WAL/SHM modes 0600; the cover cache directory was 0700. User-selected exports/backups are private files but remain at their chosen destinations; app deletion cannot remove external copies, filesystem snapshots or SSD remnants. Artwork references are archived; copying the local cache is necessary when migrating image bytes to another Mac.

## Repository and execution

Private repository: [deusalter/BooksPresence](https://github.com/deusalter/BooksPresence), branch `main`. The existing HTTPS OAuth credential lacked `workflow` scope; the existing, authenticated SSH credential successfully pushed source and Actions without requesting broader token permissions. Commit messages use the configured user identity, with no attribution trailers. At the owner's later request, historical commit timestamps are reassigned across June–September 2026; they do not establish when implementation or verification occurred. A local recovery reference preserves the original history.

Requested Sol High and Terra High worker overrides were accepted by the delegation tool. Primary model/reasoning configuration was not independently exposed. Independent code review ended with no open critical or important findings after fixes; live integrations remain subject to the checks listed above.

## Live detection and setup repair (2026-09-17)

The original live failure had two independent setup blockers: the packaged tracker recorded `permissionLost`, and Discord sharing was enabled without an Application ID. After access was granted to the diagnostic, the Books 8.0 EPUB window still exposed no AXDocument. A live metadata-only probe established its structural reader markers; the new bounded fallback matched one unique local catalog asset and rejected the open Library window. No book titles, paths, asset IDs, artwork or diagnostic output from this investigation are committed.

New regressions cover version/window-state/structure guards, exact title identity, renamed assets, duplicate editions, absent assets and invalid paths. The local core, Discord, calendar and Books harnesses plus native UI/model checks passed. Discord socket tests cover acknowledgement before “shared,” stale error nonces and SIGPIPE protection. A user-configured local Discord handshake returned READY; this alone does not prove activity rendering. The final live GUI-process grant and interval/publication checks are separate from that diagnostic result.

The app now includes a native icon, actionable missing-permission/Application-ID states, optional artwork with an empty default, and retained connection results. The popover no longer explicitly activates the app, and its hosting controller follows preferred content size for setup notices. A background transition no longer incorrectly records restored capture access. An explicit `--status-report` diagnostic records state from the actual GUI process to a single private overwritten file; it is off on normal launches.

An earlier [macOS CI run for 2b51128](https://github.com/deusalter/BooksPresence/actions/runs/35301139924) passed 45 XCTest cases, the release build, native UI/model check and signed development packaging; it predates the current additions. macOS TCC logs showed Accessibility grants resolving to an archived test bundle with a different ad-hoc code requirement. Those generated test bundles were unregistered and preserved with a non-app backup suffix. The actual running GUI process still reported denied access at this checkpoint; saved automatic intervals and a live activity acknowledgement remain pending a grant for the current bundle. No further code-signature changes are planned for this build.

## Paused presence and reader-structure repair (2026-09-17)

The correctly registered GUI bundle subsequently reported Accessibility granted, saved automatic foreground intervals and received a matching Discord activity acknowledgement. This resolves the permission blocker recorded above. A metadata-only role probe found one or two WebAreas at the same verified reader ancestry, so the previous one-area rule intermittently rejected a valid reader. At that checkpoint they were incorrectly described as proof of a two-page spread. Later position and geometry evidence established that they are chapter containers, including offscreen containers, and do not prove how many pages are visible. The classifier accepts one or two matching chapter containers and rejects mixed, incomplete or larger structures. A separate footer at SceneWindow → four groups → static text supplies an ephemeral exact-format page-change token without reading AXValue or web contents.

The owner changed the product requirement: ordinary app switching retains a Paused Discord card for 20 minutes since the last supported page observation or reading interaction; credited automatic time still stops immediately. Paused payloads omit timestamps. Controlled-time regressions cover expiry boundaries, unchanged polling after expiry, page renewal, missing page samples, fallback interaction, privacy stops, book changes and clock rollback. Synthetic socket checks exercise immediate paused/resumed payloads and acknowledgement ordering. The menu now uses a nonactivating NSPanel and explains pause reasons; durations under one minute display seconds.

The local direct build, core/Discord/calendar/Books harnesses and all 22 native light/dark view layouts passed before the additions described below. This host still lacks XCTest; fresh full XCTest and packaged live verification are pending.

## New regression coverage pending execution

The repository now contains new tests for forward page evidence, daily/session and per-book credited automatic pace, explicit Apple Books completion metadata, quiet initial import, deletion suppression, quarter-step ratings, strict public cover URL validation, exact/ambiguous Apple metadata matching, page-mode Discord payloads, and updated socket behavior. They use synthetic data or a local synthetic IPC socket; they do not publish to Discord, upload an image, or read a personal book file.

A metadata-only Apple Search probe returned one exact e-book result for the user-authorized live lookup and its artwork URL passed the validator. It did not download the image or use local book content. This is a narrow integration probe, not a claim that the fresh resolver XCTest suite, full app build, packaged app, or Discord rendering has passed.

### Stillleaf 1.3 local integration checks

The app is now presented as Stillleaf; the existing bundle identifier and support directory remain unchanged. The current local direct-compiler checks pass across core storage/statistics, Discord payloads, calendar boundaries, catalog fixtures, history-import deduplication/corrections/deletion, quarter-star ratings, and native light/dark view layouts. An actual `PublicCoverResolver` invocation matched one authorized live Apple title/author query and returned a validated public HTTPS image link without downloading the image.

Synthetic native previews were rendered and reviewed for library alignment, book details, settings, finish prompts, and grouped day history. Reading-session presentation joins same-book automatic fragments separated by less than 20 minutes while summing only stored reading durations. Explicit user splits remain barriers. New unit-test CI and the packaged app's own Accessibility/Discord behavior are separate checks; local CLI trust is not proof of GUI app permission.

## Page undercount repair (2026-09-18)

A read-only aggregate audit found that a fresh foreground session saved credited time but retained only isolated one-page transitions. Accepted events shared one layout signature, so the durable records alone could not explain the rejected intermediate samples. A bounded live metadata trace then showed a fixed reader window whose descendant WebAreas alternated between one wide chapter container and two narrower chapter containers during normal navigation. Their positions could be far offscreen. This disproves the earlier assumption that WebArea count represented visible pages or that child WebArea geometry was stable pagination identity. No book title, path, asset identifier or prose from the investigation is committed.

The repair uses one outer reader host shared by every verified chapter container and the unique footer, together with the window bounds, as the stable geometry signature. It ignores descendant WebArea count, size and position for layout identity and gives the Books 8.0 adapter a conservative one-page capacity. A changed known footer total still establishes a new baseline; same-window reflow with an omitted or unchanged total remains indistinguishable. Generic tracker bounds use capacity present at both endpoint samples so a transient expansion cannot widen an accepted jump.

Regression updates cover alternating one/two chapter-container samples, conservative transition capacity, missing footer totals, changed totals, resized bounds and invalid geometry. The local core, Discord, calendar, Books and manual-page checks pass, alongside all 28 native light/dark view layouts and model checks. The geometry replay counts all five observed advances, and a fresh read-only live capture replay counts four of four advances with a stable host signature. The UI self-check also uses a nonoverlapping manual fixture so its result no longer depends on the time of day. XCTest CI, packaging and a live foreground run of the repaired GUI build remain separate checks; CLI capture trust does not establish GUI permission.

The 1.3.4 macOS CI run [35380540949](https://github.com/deusalter/BooksPresence/actions/runs/35380540949) passed 103 XCTest cases, release build, native self-check and development packaging. The normal LaunchServices GUI process then received its renewed Accessibility grant, saved every observed forward footer change in a longer reading check, and received Discord activity acknowledgements. Backward navigation was observed separately and was not credited as forward movement. The existing manual page adjustment remained unchanged.

That live check also exposed an occasional one-checkpoint delay in displayed totals. A synthetic store reproduction shows why: fractional-millisecond JSON date decoding can round a page event slightly beyond the original interval end retained in memory, even though the persisted event and interval boundaries agree. The cache repair canonicalizes stored interval timestamps rather than widening the statistics boundary predicate. This preserves correction/deletion semantics and requires no rewrite of existing history.

## Discord reader-window lifetime (2026-09-21)

The presence policy now requires an explicit open-reader signal in addition to recent activity. A successful foreground capture supplies an ephemeral reference to that exact Books process and AX window. Before publication, the app checks that the same window is still listed by Books and retains its verified title/document metadata; this check reads no prose and does not require Books to stay foreground. Window-close observations, application termination notifications and the one-second poll clear stale activity. A new reader observation is required after the signal disappears.

Regressions cover closing while paused, quitting while reading, manual mode with no reader, reopening without fresh evidence, and the preserved 20-minute tab-away grace period. The local core, Discord, calendar, Books and manual-page smoke checks and all 28 native light/dark layouts pass. A live close/reopen cycle and the final packaged GUI permission are separate from these synthetic checks.

## Idle CPU and interface responsiveness (2026-09-24)

Profiling the installed 1.3.6 app while Books was closed showed approximately 100% of one CPU core in use, with a 41.7 MB physical footprint (58.8 MB peak). The main thread was mostly asleep; Discord's continuously resumed, level-triggered write source was repeatedly dispatching an empty output queue. A synthetic socket regression reproduced 361,819 write wakeups in 250 ms. The repaired writer suspends when drained, resumes for new output, balances suspension on shutdown, and preserves partially written frames under backpressure. The same idle test reports zero wakeups. The test also covers ping/pong, a large response through a small send buffer, and clearing activity.

Reader-window liveness and observer refresh work now run on coalesced utility queues. Results from an obsolete reader reference cannot publish another book's activity. View-facing page totals, pace and session grouping are cached until history refreshes; deletion checks compare these caches with source evidence and ensure removed data does not survive in them. Unchanged Apple Books history imports no longer rewrite every saved book and refresh the dashboard. Cover views load 320-pixel thumbnails off the UI thread, deduplicate concurrent requests and use an evictable cache with a 12 MB cost budget. Local packaging now enables Swift release optimization.

The local core, Discord, Books, calendar, manual-page and native model/layout suites passed. Synthetic light/dark previews were reviewed for the library and Today layouts. Buttons respect control size, library cards provide short hover feedback, the sidebar animates its selection, and calendar animations are scoped to the changing panel. Motion effects respect Reduce Motion. These checks do not establish a live Books reading session or Discord client rendering for the new package; those require the installed GUI's permission and current reader evidence.

## Direct navigation and shorter motion (2026-09-24)

Following feedback that the 1.3.7 transitions felt slow, 1.3.8 makes dashboard section and library shelf changes immediate. The sidebar no longer slides its selection between rows. Calendar navigation uses a 100 ms incoming-only opacity transition, scoped to the calendar content; the toolbar and panel no longer animate their geometry or scale an outgoing calendar. Button presses use a 60 ms ease-out instead of a spring, hover feedback is 80 ms, and library cards no longer lift on hover. Completion and rating feedback use short ease-outs. Reduce Motion remains respected. These are motion and layout changes, with no change to reading evidence or Discord behavior.

## Navigation stalls under a larger history (2026-09-24)

The 1.3.8 motion changes did not address the user's click-before-transition pause. A new `--benchmark-ui` developer command creates isolated synthetic history (60 books, 2,000 intervals and 2,000 page events), replaces the destination in a native hosting window, and times synchronous construction, layout and display. It excludes fixture preparation and animation waits and never opens the user's database. This measures destination work, not end-to-end input latency or compositor frame rate.

Before the fix, three passes measured month layout at 371–554 ms, year at 1,178–1,214 ms and Settings at 240–290 ms. A sampling profile showed repeated `HistoryView.pageTurns` calls spending most of their time in `PageStatistics.qualified`: each page event scanned the entire effective interval history. Qualification now builds a book/session index and uses binary search with prefix maximum ends. This retains start-exclusive/end-inclusive boundaries, overlapping-input membership, book merges, exclusions and manual corrections. Differential regression coverage compares indexed results with the original linear membership predicate, including a long session, gaps and boundaries.

Calendar summaries now select civil-day keys once per view evaluation and reuse constant-time daily page lookups. Settings no longer constructs hundreds of native time-zone picker items on entry: a searchable popover creates a lazy list when opened. It still edits the draft and requires Apply reading changes to persist the chosen zone.

On the same host and fixture, final three-pass destination timings were month 24–48 ms, year 36–41 ms, week 28–29 ms, day 18–24 ms and Settings 75–104 ms. Library and Today were approximately unchanged. Timing is informational rather than a hardware-dependent CI assertion. The core, Discord, calendar, Books and manual-page smoke suites, differential interval checks and 28 native light/dark model/layout checks passed. These synthetic measurements do not establish a live click trace, sustained frame rate, or an active Books/Discord session.

## Sea-glass interface and coordinated dropdown (2026-09-24)

Stillleaf 1.4.0 uses coordinated light mint and dark green surfaces, rounded interface typography, and serif book titles. Today has a bounded animated page-goal arc, secondary time/streak metrics, a weekly strip, and the current or explicitly labeled last-read book. The menu panel uses the same smaller arc, actual snapshot state, manual-time and pending-review qualifiers, aligned switches, and fixed header/actions around a scrollable body. A scroll cue appears when content exceeds the available height. The native panel's clipping radius matches the SwiftUI surface.

History, Library/book details, Settings, Review, Data health, manual-entry and correction dialogs share controls and spacing. Selection, hover, press and incoming-screen motion are scoped locally; navigation does not retain or interpolate an outgoing screen. Reduce Motion suppresses these effects, including completion-badge scaling. Review creates rows lazily and exposes additional records in batches of 30. Reading evidence, historical corrections and Discord reader-window policy are unchanged.

The optimized packaged build passed the model/correction/deletion checks and all 40 native light/dark layouts. App-owned synthetic previews covered Today empty/partial/over-goal states, compact layouts, all calendar scales/settings categories, library/details, Review, Data health, entry dialogs, and the menu. The isolated manual-menu fixture uses tracking disabled: it verifies manual action/time controls, not an active capture session. Native desktop screenshots returned blank and live Stillleaf accessibility inspection timed out, so these checks do not establish actual menu scrolling, keyboard interaction, live frame pacing or reading capture in the installed app.

On the same 60-book / 2,000-interval / 2,000-event fixture, three final packaged destination-layout passes measured month 25–44 ms, year 42–52 ms, week 29–36 ms, day 21–32 ms, Today 74–96 ms, Settings 91–133 ms and Review 34–39 ms. Library measured 128 ms on its first pass and 57–61 ms thereafter; Data health measured 44–55 ms. Review before lazy rows measured 116–151 ms. These are synchronous construction/layout/display measurements, not end-to-end clicks or FPS. Today and Settings perform more layout than 1.3.9; this pass does not claim a blanket speedup.

The local ad-hoc package passed deep signature verification. As with previous rebuilt packages, the installed GUI requires a renewed macOS Accessibility registration. Permission, live Books observation, Discord client rendering and fresh GitHub CI are independent of the native layout checks above.


## Reading-focused refinement (1.4.1, 2026-09-24)

The menu retains the daily arc but uses smaller book/status typography, hides idle session metrics, and moves preference switches to Settings. The sidebar no longer promotes Data health or sharing controls. Settings starts with the page goal and everyday reading controls; advanced timing/timezone options collapse, Sharing is optional, and Data & privacy contains import/export, Apple Books history, recovery and a secondary Troubleshooting sheet. Reading and Sharing drafts have separate Save/Revert behavior; successful Sharing saves normalize trimmed connection fields.

Library now has a cover grid, Reading/Finished/All shelves, title/author search, stable sorting and an optional finished timeline. Book details include an optional rating editor and collapsed cover/sharing details. The new star control supports pointer preview, drag selection, keyboard and accessibility quarter-step adjustments, explicit zero, and clearing a rating. Drafts persist only on Save; failed writes retain the completion prompt/editor. Native start/middle/end frames of a 0-to-4.25 change show intermediate fractional fills. These frames exercise binding-driven animation, not live pointer latency; Reduce Motion branches were source-reviewed, not toggled in the user's system preferences.

History hides completed automatic visits shorter than two minutes when they contain no qualified page evidence. Manual/imported, active, corrected, longer time-only and page-bearing visits remain. This is a display filter: raw intervals, page events, totals and exports are unchanged. Event indexing and cached visibility avoid rescanning the journal on every render. Six local smoke suites passed, including the large fragmented-history replay and cache invalidation. The integrated UI suite passed correction/deletion/rating checks and 44 native light/dark layouts. Final synthetic previews covered an eight-book library, zero/quarter/unset ratings, all Settings categories, Troubleshooting and compact History. Keeping the History heading outside its scroll area fixed the previously clipped compact preview.

The 60-book / 2,000-interval / 2,000-event benchmark measured synchronous destination layout over three passes: month 21–39 ms, year 36–41 ms, week 23–26 ms, day 15–20 ms, Library 31–89 ms, Today 39–63 ms, Settings 35–55 ms, Review 19–24 ms and Troubleshooting 28–36 ms. These are local construction/layout/display measurements, not end-to-end clicks, sustained FPS or live reading verification.


## Personal journal and flexible goals (1.5.0, 2026-09-24)

Daily goals support pages or minutes with independently remembered targets and dated unit changes. Calendar goal indicators and streaks use the unit effective on each day. Optional yearly goals count unique canonical books with confirmed finish dates in the selected Gregorian calendar year/time zone; unknown and future dates do not count. Merged-book and corrected-date cases are covered. Goal and timezone evidence is saved atomically; login registration is a separate action.

Library defaults to all saved books. Timeline has its own destination with prominent local finish dates, book cards and ratings; Reviews contains only private written reviews. Tracking records remain available through Settings → Data & privacy → Troubleshooting → Reading records. Review drafts support save/cancel, dirty-dismiss protection, confirmation before clearing existing prose, and JSON/CSV/backup persistence. Review text/date lookups are cached per journal refresh, preserving archive-order tie handling.

Library and book details can mark an unfinished book finished immediately. This records the actual current date and time, updates the yearly count once, and offers optional quarter-star rating and written review. The completion badge claims the saved completion-event ID once, and later Apple Books sync does not replay a manually recorded finish. No pages or time are inferred from marking finished. Library removal explicitly confirms destructive journal deletion, including history/rating/review and managed backups; original Apple Books files and separately saved exports remain. No live user book was deleted or marked finished for testing.

Seven core/platform smoke suites passed after the goal/review safety changes. The final app model/layout suite additionally checks current-time manual completion, duplicate calls, later Apple Books sync, unchanged reading evidence, yearly count, optional feedback and one-time celebration. Native previews cover light/dark and compact Timeline/Reviews, pages/minutes goals, written editor, and completion/rating motion. Final Timeline previews show localized “Sep” labels. Normal completion start/middle/end frames differ; Reduce Motion frames remain identical. These synthetic frames verify binding-driven transitions, not live pointer latency or sustained frame pacing.

The final optimized app passed all model checks and 54 native light/dark layouts. On the isolated fixture with 60 books, 2,000 intervals, 2,000 page events, 60 completions and 60 written reviews, three synchronous layout passes measured Reviews 29–34 ms (before caching: 101–114 ms), Timeline 23–24 ms, Library 43–97 ms, Today 45–65 ms, Settings 42–66 ms, month 26–45 ms and year 41–47 ms. These are synthetic layout/display timings, not end-to-end input or FPS measurements.
