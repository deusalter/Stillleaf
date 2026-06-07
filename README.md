# Stillleaf

A native macOS menu-bar reading journal for Apple Books, with optional Discord Rich Presence. Reading history stays on this Mac. Automatic time is **inferred reading activity**, not proof of attention.

**Integration status:** the diagnostic has matched a live local EPUB in Books 8.0 and rejected its Library window. This reader omits `AXDocument`, so a version-scoped structural inference supplements exact document-path matching. Automatic tracking still requires Accessibility access for the packaged app itself and pauses for unsupported or ambiguous windows. Manual reading works independently. See [capabilities](docs/CAPABILITIES.md) and [verification](docs/VERIFICATION.md).

## Build and run

Requires macOS 13 or later and Swift 5.8 or later. No third-party package dependencies.

With full Xcode selected:

```sh
swift build
swift test
scripts/package-app.sh
open dist/Stillleaf.app
```

With Command Line Tools only (including this host):

```sh
scripts/build-local.sh
scripts/check-local.sh
scripts/package-app.sh
open dist/Stillleaf.app
```

The local builder bypasses SwiftPM using `swiftc`. The check script runs independent assertion executables because this host does not have XCTest. GitHub Actions runs the actual XCTest suites on a full macOS/Xcode runner.

Move the app to `~/Applications` or `/Applications` before configuring permissions and login startup. This is an **ad-hoc signed development build**, not a notarized release. Rebuilding or replacing it may require re-enabling its Accessibility entry and reopening the app. A distribution build requires your own Developer ID and notarization; no signing credentials are stored here.

## First use

1. Click the book icon in the menu bar. No dashboard or Dock icon opens automatically.
2. Open Dashboard → Settings. The daily goal starts at 20 observed pages, using this Mac's initial timezone.
3. Use Request Accessibility / Open Accessibility Settings and enable **Stillleaf**. macOS may require reopening the app. Granting access to Codex or Terminal does not necessarily grant the packaged tracker access.
4. Open a real reading window in Books. If its focused document cannot be matched exactly to one catalog asset, the Health screen explains why automatic tracking is paused. Use **Start manual reading** for an unsupported reader, paper book, or deliberate side-by-side reading.
5. Check **Launch at login**. The app attempts main-app login registration once on first packaged launch, subject to macOS approval. You can disable it in Settings or System Settings → General → Login Items.

Closing the dashboard leaves tracking running. Quit stops the tracker. A per-user file lock prevents duplicate instances. Pause tracking and Share with Discord are independent controls; each book also has separate tracking and sharing exclusions.

## What counts

Automatic eligibility requires Books foreground, a focused reader matched to one stable Books asset, an awake display, an unlocked user session, permission, and enabled tracking. Library/store, unidentified windows and background Books do not count. Workspace and Accessibility notifications supplement a one-second eligibility poll. Books 8.0 EPUB windows without a document path use a bounded structural check, followed by one exact unique catalog-title match. Duplicate titles, library navigation, minimized/modal windows and incomplete scans are rejected. History continues to use stable asset IDs.

After the configurable conservative threshold (20 minutes by default) without reading activity, subsequent intervals are **uncertain** and excluded. In the observed English Books 8.0 EPUB footer layout, small forward page movement with stable reader bounds provides activity evidence; moving the pointer does not renew it. The capture does not read words or prose, measure gaze, or prove attention. Readers without that metadata use foreground reading interaction as a fallback. A review badge and grouped spans allow confirmation, trimming or discard without notification spam. Returning does not retroactively confirm uncertain time.

Page totals count bounded forward movement between nearby samples: several turns can be captured together, with an elapsed-time bound and a hard cap of eight pages per sample. A briefly missing footer does not discard the baseline; a gap longer than five seconds, tracking pause, book/session change, changed reader size, or changed known page total does. Hiding the displayed total alone does not reset counting. A small navigation jump can resemble fast reading, so this is observed movement rather than proof that every page was read. Existing omitted pages are not reconstructed from endpoint differences. An explicit manual page correction can be attached to a recorded session: it changes page totals and goals, is labeled in the journal, and does not alter automatic pace or recorded time.

Manual reading is labeled and still pauses for explicit pause, lock and sleep. Added past records and time adjustments are explicit manual evidence; overlapping records are rejected. There is no hidden streak repair.

## History and controls

- Today: credited time and page goals, current interval, current/longest streak, session pages and credited automatic-session pace.
- History: a month calendar by default, with animated Day / Week / Month / Year views. Move between periods, return to Today, open a month from the year, or select a date to see books and contributing sessions. Navigation respects the selected timezone and macOS Reduce Motion.
- Library: exact accessible local covers, per-book time, verified page evidence, credited automatic pace, first/last dates and timeline.
- Review: confirm/trim/discard uncertainty; adjust, split, reassign, exclude or delete records. Optional ratings use quarter-star steps.
- Finished: optional Apple Books completion metadata uses its explicit finished flag and saved date. It does not create historical time or pages; imports already present at initial sync stay quiet.
- Health: access failures, known gaps, recovery events and last successful capture. An empty day is distinct from a known outage.
- Settings: Reading / Discord / Data categories, native tracking and sharing switches, goal presets, time-zone search, and clearly applied settings changes. Discord can be configured before sharing is enabled.

Goal changes are effective today and forward. Yesterday's completed streak survives while today is pending. Calendar splitting uses actual local-midnight boundaries, including DST. Unresolved time is excluded and relevant streak uncertainty is flagged. A timezone change explicitly regroups history in the selected calendar timezone; it is audited, and existing goal effective-day strings remain unchanged.

Stable asset IDs preserve history across renamed books and covers. Same-title editions remain separate. Explicit merge decisions group library views; unmerge restores the original identities without rewriting interval book IDs.

## Data, recovery and deletion

Stillleaf keeps the existing `com.bookspresence.app` identifier and `~/Library/Application Support/BooksPresence/` storage location so upgrades preserve permissions, settings, and history. Data lives in that folder:

- `history.sqlite` and SQLite sidecars: original intervals, metadata changes, progress observations, goals, corrections, lifecycle evidence and recovery markers.
- `Covers/`: local image cache. Local covers are never uploaded. Optional automatic public-cover lookup is off by default and uses Apple metadata only; it does not upload or read local images.
- `tracker.lock`: instance-lock inode. Do not delete it while the app is running.

Elapsed time uses monotonic uptime. Wall clocks place intervals on the calendar, with discontinuities/gaps pausing credit. Transactions save checkpoints at a nominal 15 seconds and on state changes. Under the supported sampling cadence (no tick gap over five seconds), the unpersisted tail is **less than 20 seconds**; after a longer gap, the unsupported gap is not credited. A crash keeps only committed evidence and records an unknown uncertain tail without counting downtime. Disk-write failure stops further tracking.

JSON is a versioned complete structured-history archive, with duplicate-safe atomic import. SQLite backup/restore validates before replacing history. CSV includes raw and effective interval tables so corrections remain traceable. Cover references are exported; binary cover images are separate local files, so keep the `Covers/` directory when migrating artwork. Imported paths are not uploaded or fetched from the internet.

Deletion physically removes affected records and dependent private lineage, preserving unrelated split/reassigned intervals. Deleting a book also suppresses it from later automatic Apple Books completion imports. SQLite secure deletion, WAL checkpoint and vacuum remove normal database copies; OS snapshots, SSD wear-leveling and user-made copies are outside application control. Delete-all clears managed local covers and managed backups, turns off automatic Apple Books history sync, and clears its import state. **Exports and backups you saved elsewhere must be removed separately.** No automatic remote backups exist.

Uninstall disables login startup, moves the app bundle to Trash and quits. Reading history is preserved; use Delete all data first if you want it removed. No global daemon or privileged helper is installed.

## Diagnostic

```sh
.build/local/books-diagnostic
# Or inside the packaged app:
dist/Stillleaf.app/Contents/MacOS/books-diagnostic
# Explicitly include the focused title/document metadata (keep output private):
.build/local/books-diagnostic --include-metadata
```

The diagnostic reports the actual installed version, trust, foreground/session/display state, window-level document availability and verified catalog columns. Opt-in metadata also reports reader-structure eligibility; it never reads book text or web content. A CLI helper can have different macOS permissions from the GUI app. For explicit local troubleshooting, launch the packaged app with `--status-report /path/to/status.json`; it overwrites one private report containing tracking/Discord state, without titles, asset IDs or credentials. Normal launches write no report. It does not read book prose, take screenshots, use OCR, enumerate unrelated app titles or write to Books databases. No scripting properties are assumed.

## Discord

Disabled by default; local tracking needs neither Discord nor internet. Supply your own application ID and optionally configure a stable generic asset in that Discord application's developer settings. Presence uses the documented native IPC route and a client-controlled Playing activity; the app name is configured in the Discord Developer Portal. In page mode it shows the title, author, current layout-specific page and total when available, and pages for the current session; it has no elapsed timestamp. Switching apps pauses credited time and keeps the card visible with “Paused”; its running timer is removed. The card expires 20 minutes after the last page observation or supported reading activity. Explicitly disabling tracking/sharing, exclusions, lock/sleep, permission/capture failures and quitting clear it immediately. Activity updates are rate-limited, with prompt pause/resume changes. See [Discord setup and limitations](docs/DISCORD.md).

Exact local covers stay local. With explicit opt-in, the app can search Apple’s public metadata for one unique exact title-and-author e-book result and send its validated public HTTPS artwork URL to Discord; it never uploads or reads a local image for that feature. Invalid, missing or ambiguous results fall back to the configured generic asset. A local path is never sent as a Discord image. Live rendering and reconnect checks require a configured application ID and Discord client; these are separate from synthetic protocol tests.

## Scope

This release observes this Mac only. It does not backfill or claim iPhone/iPad activity. Saved Books progress can be stale and is labeled accordingly. Verified small forward page observations support page goals and credited automatic-session pace; they do not establish total pagination, words read, reading speed, gaze or attention. The observed Books 8.0 footer is limited to the supported English reader layout and is never used as a Discord percentage. Books' private catalog schema may change: the adapter checks required columns and fails closed.

Source layout: `BooksCore` owns evidence/storage/statistics; `BooksPlatform` owns macOS/Books/Discord adapters; `BooksPresence` owns lifecycle and native views. The binding requirements are preserved in [the product specification](docs/PRODUCT_SPEC.md).

## UI development

`scripts/check-local.sh` checks calendar navigation and lays out all four calendar views, all settings categories, and the other primary views in both appearances. To render native previews with synthetic reading data, run:

```sh
.build/local/BooksPresence --render-ui .local/ui-previews
```

This renders app-owned views to PNGs; it does not capture your screen, open your personal history, or start tracking. Generated previews are ignored by Git.
