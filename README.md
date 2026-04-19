# BooksPresence

A native macOS menu-bar reading journal for Apple Books, with optional Discord Rich Presence. Reading history stays on this Mac. Automatic time is **inferred reading activity**, not proof of attention.

**Integration status:** this Mac's Books 8.0 catalog is readable. Live Accessibility reader detection is not yet verified: the diagnostic reports that the tracker process lacks access. Automatic tracking fails closed when it cannot uniquely identify the focused reading document. Manual reading works independently. See [capabilities](docs/CAPABILITIES.md) and [verification](docs/VERIFICATION.md).

## Build and run

Requires macOS 13 or later and Swift 5.8 or later. No third-party package dependencies.

With full Xcode selected:

```sh
swift build
swift test
scripts/package-app.sh
open dist/BooksPresence.app
```

With Command Line Tools only (including this host):

```sh
scripts/build-local.sh
scripts/check-local.sh
scripts/package-app.sh
open dist/BooksPresence.app
```

The local builder bypasses SwiftPM using `swiftc`. The check script runs independent assertion executables because this host does not have XCTest. GitHub Actions runs the actual XCTest suites on a full macOS/Xcode runner.

Move the app to `~/Applications` or `/Applications` before configuring permissions and login startup. This is an **ad-hoc signed development build**, not a notarized release. A distribution build requires your own Developer ID and notarization; no signing credentials are stored here.

## First use

1. Click the book icon in the menu bar. No dashboard or Dock icon opens automatically.
2. Open Dashboard → Settings. The daily goal starts at 20 credited minutes, using this Mac's initial timezone.
3. Use Request Accessibility / Open Accessibility Settings and enable **BooksPresence**. macOS may require reopening the app. Granting access to Codex or Terminal does not necessarily grant the packaged tracker access.
4. Open a real reading window in Books. If its focused document cannot be matched exactly to one catalog asset, the Health screen explains why automatic tracking is paused. Use **Start manual reading** for an unsupported reader, paper book, or deliberate side-by-side reading.
5. Check **Launch at login**. The app attempts main-app login registration once on first packaged launch, subject to macOS approval. You can disable it in Settings or System Settings → General → Login Items.

Closing the dashboard leaves tracking running. Quit stops the tracker. A per-user file lock prevents duplicate instances. Pause tracking and Share with Discord are independent controls; each book also has separate tracking and sharing exclusions.

## What counts

Automatic eligibility requires Books foreground, a focused file document matched to one stable Books asset, an awake display, an unlocked user session, permission, and enabled tracking. Library/store, unidentified windows and background Books do not count. Workspace and Accessibility notifications supplement a one-second eligibility poll.

No keyboard/mouse inactivity cutoff stops ordinary reading. After the configurable conservative threshold (20 minutes by default) with no relevant interaction or reliable navigation evidence, subsequent intervals are **uncertain** and excluded. A review badge and grouped spans allow confirmation, trimming or discard without notification spam. Returning does not retroactively confirm uncertain time.

Manual reading is labeled and still pauses for explicit pause, lock and sleep. Added past records and time adjustments are explicit manual evidence; overlapping records are rejected. There is no hidden streak repair.

## History and controls

- Today: credited goal progress, current interval, current/longest streak, manual time.
- History: calendar and day/week/month totals; daily details link to contributing records.
- Library: exact accessible local covers, per-book time, first/last dates, observed progress and timeline.
- Review: confirm/trim/discard uncertainty; adjust, split, reassign, exclude or delete records.
- Health: access failures, known gaps, recovery events and last successful capture. An empty day is distinct from a known outage.
- Settings: goals, calendar timezone, uncertainty threshold, privacy, login, data operations.

Goal changes are effective today and forward. Yesterday's completed streak survives while today is pending. Calendar splitting uses actual local-midnight boundaries, including DST. Unresolved time is excluded and relevant streak uncertainty is flagged. A timezone change explicitly regroups history in the selected calendar timezone; it is audited, and existing goal effective-day strings remain unchanged.

Stable asset IDs preserve history across renamed books and covers. Same-title editions remain separate. Explicit merge decisions group library views; unmerge restores the original identities without rewriting interval book IDs.

## Data, recovery and deletion

Data lives in `~/Library/Application Support/BooksPresence/`:

- `history.sqlite` and SQLite sidecars: original intervals, metadata changes, progress observations, goals, corrections, lifecycle evidence and recovery markers.
- `Covers/`: local image cache. No cover uploads or external cover searches.
- `tracker.lock`: instance-lock inode. Do not delete it while the app is running.

Elapsed time uses monotonic uptime. Wall clocks place intervals on the calendar, with discontinuities/gaps pausing credit. Transactions save checkpoints at a nominal 15 seconds and on state changes. Under the supported sampling cadence (no tick gap over five seconds), the unpersisted tail is **less than 20 seconds**; after a longer gap, the unsupported gap is not credited. A crash keeps only committed evidence and records an unknown uncertain tail without counting downtime. Disk-write failure stops further tracking.

JSON is a versioned complete structured-history archive, with duplicate-safe atomic import. SQLite backup/restore validates before replacing history. CSV includes raw and effective interval tables so corrections remain traceable. Cover references are exported; binary cover images are separate local files, so keep the `Covers/` directory when migrating artwork. Imported paths are not uploaded or fetched from the internet.

Deletion physically removes affected records and dependent private lineage, preserving unrelated split/reassigned intervals. SQLite secure deletion, WAL checkpoint and vacuum remove normal database copies; OS snapshots, SSD wear-leveling and user-made copies are outside application control. Delete-all clears managed local covers and managed backups. **Exports and backups you saved elsewhere must be removed separately.** No automatic remote backups exist.

Uninstall disables login startup, moves the app bundle to Trash and quits. Reading history is preserved; use Delete all data first if you want it removed. No global daemon or privileged helper is installed.

## Diagnostic

```sh
.build/local/books-diagnostic
# Or inside the packaged app:
dist/BooksPresence.app/Contents/MacOS/books-diagnostic
# Explicitly include the focused title/document metadata (keep output private):
.build/local/books-diagnostic --include-metadata
```

The diagnostic reports the actual installed version, trust, foreground/session/display state, window-level document availability and verified catalog columns. It does not read book prose, take screenshots, use OCR, enumerate unrelated app titles or write to Books databases. No scripting properties are assumed.

## Discord

Disabled by default; local tracking needs neither Discord nor internet. Supply your own application ID and optionally upload a generic `books` asset to that Discord application's developer settings. Presence uses the documented native IPC route and supported Playing activity type with a “Reading …” detail. It clears on pause or sharing exclusion, rate-limits and reconnects, and uses credited session elapsed time. See [Discord setup and limitations](docs/DISCORD.md).

Exact local covers stay local. There is no artwork publishing/upload flow in this release. A local path is never sent as a Discord image. Live rendering and reconnect checks require a configured application ID and Discord client; these are separate from synthetic protocol tests.

## Scope

This release observes this Mac only. It does not backfill or claim iPhone/iPad activity. Saved Books progress can be stale and is labeled accordingly; no pages-read differences or words-per-minute claims are made. Page/location collection is omitted until a trustworthy live source is verified. Books' private catalog schema may change: the adapter checks required columns and fails closed.

Source layout: `BooksCore` owns evidence/storage/statistics; `BooksPlatform` owns macOS/Books/Discord adapters; `BooksPresence` owns lifecycle and native views. The binding requirements are preserved in [the product specification](docs/PRODUCT_SPEC.md).
