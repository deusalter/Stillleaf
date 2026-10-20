# Pre-launch performance pass (October 2026)

Branch `perf/launch-idle-and-memory`. This pass builds on [History navigation performance](HISTORY_NAVIGATION_PERFORMANCE.md), [Responsiveness and controls](RESPONSIVENESS_AND_CONTROLS.md) and the October lag fixes (#49–#52). Every change was measured before and after, and changes that did not measurably help were not kept. All numbers come from synthetic data: no personal books, Books library or reading history were read.

## Results

| Area | Before | After | Method |
|---|---:|---:|---|
| Menu bar idle, CPU | 105.1 ms/min | 10.5 ms/min | `--measure-idle 90`, median of 3 side-by-side runs |
| Menu bar idle, instructions retired | 478 M/min | 25 M/min | same |
| Menu bar idle, interrupt wakeups | 79/min | 32/min | same |
| Menu bar idle, model publishes (each re-renders the hidden menu panel) | 2/min | 0/min | same |
| Manual reading session, CPU (instructions) | 678 ms/min (5.83 G) | 670 ms/min (5.60 G) | same; the poll rightly stays at 1 s, and the gain is the skipped catalog re-reads |
| JSON import / backup restore, 6,000 intervals + 12,000 events | 13,829 ms | 554 ms | `importJSON`, median of 3 |
| Same, 2,000 intervals | 1,638 ms | 175 ms | same |
| Same, 20,000 intervals | (quadratic, not run) | 1,815 ms | same |
| Web views alive after 10 reader open/close cycles | 9 | 1 (released moments later) | `--measure-reader`, 24-chapter book |
| Process footprint after the 10th close | 64.8 MB | 48.0 MB | same |
| Footprint growth per book opened, cycles 5 to 10 | about 2.1 MB | about 0.1 MB | same |
| Renderer entry chunk | 705.7 KB (gzip 203.3 KB) | 585.7 KB (gzip 170.2 KB) | `vite build` |
| Renderer script load and run, WebKit | median 74.5 ms, p25 66 ms | median 68.5 ms, p25 53 ms | `measure-reader-lag.mjs scenario=boot`, 50 fresh pages each, interleaved |
| Launch: tracker ready on the heavy history | 534 ms | 320 ms (see note) | `--measure-launch`, median of 6, interleaved, load average 4 |
| Launch: hidden menu panel built | 86 ms | 86 ms | same |
| Launch: first background history refresh | 175 ms | 177 ms | same |

For reference, the installed app idling in the menu bar on a real history (68 books) used 285 ms CPU, 1.09 G instructions and 106 wakeups per minute (read-only `proc_pid_rusage` counters over 60 s, before this branch).

The Mac was heavily loaded by parallel builds throughout (load average 30 to 120 on 8 cores), so wall-clock figures are noisy. Instruction and wakeup counts and object counts are not affected by load; compare those first. Before and after runs were interleaved or run side by side so they shared the same load.

## What changed

**Eligibility poll (idle).** The tracker woke every second even when nothing could be read. It now polls every second only while something could be credited or watched: manual reading, a focused Stillleaf reader, Apple Books in front (with or without access), audio playing, an open session, or a Stillleaf window or the menu panel on screen. Otherwise it polls every 30 seconds, which is the Apple Books history sync interval. Leaving that relaxed state needs an app activation, reader focus, wake, unlock or day change, and each of those already ticks immediately. Both timers carry a 10% tolerance so macOS can coalesce wakeups. A day-change observer keeps Today's midnight rollover prompt. Input sampled at an app switch is limited to the second before the switch, as the one-second poll saw it. `--measure-idle` fails if the menu bar poll does not relax.

**Apple Books catalog sync.** Every 30 s the tracker re-read the Books catalog and every finished book, staged covers, and re-sorted the whole journal's events on the main thread, only to find nothing new. Every 60 s it re-checked store purchases the same way. `BooksCatalog.changeStamp()` records the size and modification time of the catalog database and its WAL; reading the catalog touches only `-shm`. The periodic sync and purchase check skip while the stamp is unchanged, and do a full re-read every 10 minutes regardless. The stamp is computed on the history queue and kept only after a read succeeds, so a failed or discarded read retries on the next poll. Explicit **Sync now** and settings changes always re-read.

**Import and restore were quadratic.** Archive validation checked each page event against a freshly concatenated array of every interval. It now indexes interval ends by book and session once. Accept and reject behaviour is unchanged; a new XCTest pins the rules.

**Reader web views leaked.** A closed reader released its controller, toolbar and panels, but WebKit kept its `WKWebView`, page, user content controller and scheme handler alive. Every book opened and closed in a session leaked one. Closing now clears the navigation delegate and removes the page's user scripts and content rule list, as well as its message handler. Clearing the delegate alone still leaked one view per cycle. The view stays in its window, so a closing full-screen window still draws. The EPUB smoke now opens and closes four readers and fails if more than one is left alive. AppKit sometimes holds the most recently closed window for a moment; a leak keeps one per reader.

**Renderer bundle.** `resources.js` imported all of `css-tree` to rewrite publisher CSS. That also bundled the CSS validator (its lexer and roughly 80 KB of property-syntax data) and source-map support, none of which the rewrite calls. It now imports the parser, walker and generator entries. A differential run of the full and lean entries over 97 stylesheets (434 KB: ReadiumCSS, bundled fonts and test fixtures) produced identical output. `test/bundle-size.test.mjs` sets a 650 KB budget for the entry chunk.

## Measured and left alone

- **Reading cost.** A manual session costs about 0.8 s CPU per minute on the heavy history. About 220 ms of that is the background history refresh every 15 s that keeps Today's totals live, and about 50 ms is the hidden menu panel updating. Making the refresh incremental is the next step. Rebuilding the panel on open would add latency to opening it.
- **SQLite.** Everyday writes are appends and upserts (`ON CONFLICT DO UPDATE`), so foreign-key cascades never run. Only deleting a book scans `events`, `progress`, `intervals` and `merges`. On a synthetic 6,000-interval, 11,000-event database the delete takes about 20 ms; indexes on the child keys bring it to 4 ms but add a B-tree write to every page-turn append. Deletes are rare and user-initiated, so no indexes were added. Plans: `DELETE FROM events WHERE book_id = ?` → `SCAN events`; deleting a book → `SCAN merges ×2, SCAN progress, SCAN intervals`.
- **Reader while still.** With the Animated garden, ambient growth draws at about 27 frames per second in headless WebKit. Still and Off modes exist and Reduce Motion and Low Power already apply, so this is left as designed.
- **Covers.** These are already decoded off the main thread at 320 px and cached.
- **Launch.** No launch work was targeted, and no launch gain is claimed. The whole tracker-ready difference above is one `SMAppService.mainApp.status` query (`LoginService.enabled` in `AppModel.init`). In samples it blocked the main thread for about 180 ms in the before build and did not appear (under 1 ms) in the after build, with identical code and with both binaries in the same folder, so the daemon's reply time is what varies. Reading that status off the main thread at launch is the obvious next step. Footprint after launch is unchanged at about 130 MB.

## Reproduce

Every probe runs in background mode (no activation, windows parked) and uses disposable data:

```sh
scripts/build-local.sh
.build/local/BooksPresence --measure-idle 90          # STILLLEAF_IDLE_SCENARIOS=menu,manual
.build/local/BooksPresence --measure-launch           # run several times, compare medians
python3 scripts/reader-review-fixture.py /tmp/book.epub --chapters 24
.build/local/BooksPresence --measure-reader /tmp/book.epub 10   # STILLLEAF_PROBE_HOLD=120 keeps it up for leaks/heap
node scripts/measure-reader-lag.mjs scenario=boot engine=webkit reps=10 dist=<renderer dist>
```

`--measure-idle` seeds 70 books, 6,000 intervals and about 11,000 events and a synthetic 80-book Books catalog. It hosts the menu panel hidden, as the app does at launch, and reports CPU time, retired instructions, interrupt wakeups and model publishes per minute from `proc_pid_rusage`.

## Not verified here

- Live App Nap behaviour of the packaged login item, and the 30 s poll with real Apple Books switching (it needs Accessibility and the user's Books). After installing, check the poll with `top -pid <pid> -stats pid,cpu,idlew` while Stillleaf sits in the menu bar.
- The XCTest additions (`BooksHistoryTests`, `PageTurnTests`) need the full Xcode runner. Their local mirrors (books smoke, an ad-hoc import-rules check against both libraries) passed.
