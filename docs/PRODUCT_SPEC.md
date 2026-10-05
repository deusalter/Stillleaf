> September 17 product revision: the owner requested that switching apps retain a clearly paused Discord card, expiring 20 minutes after the last page turn or supported reading activity. Credited reading remains foreground-only. This supersedes immediate presence clearing on ordinary background/window transitions below; explicit stop, privacy exclusions, lock/sleep and access failures still clear immediately.

Build BooksPresence, a polished native macOS reading tracker for Apple Books with optional Discord Rich Presence.

This is a personal reading-history application. Its priorities, in order, are trustworthy tracking, durable records, useful statistics, unobtrusive operation, and Discord sharing.

Implement working software. Start by inspecting the actual environment and validating Apple Books integration. Make routine implementation decisions independently.

PRODUCT AND INTERFACE

Use a native Swift/SwiftUI application with AppKit integration where appropriate.

Provide:

* A background tracker that starts at login.
* A menu-bar icon and compact popover.
* A dashboard window opened on demand.
* No permanent Dock icon or automatically opening windows.
* Normal, accessible controls to pause, quit, disable startup, and uninstall.

The popover should show the current cover/title, session duration, today’s reading time, daily goal, and current streak. Include separate controls for pausing tracking and disabling Discord sharing.

Closing the dashboard must leave tracking running. Quitting the application must stop it. Prevent duplicate tracker instances.

Design an attractive interface with strong typography, book covers and clear charts. Glass surfaces over animated ASCII vines give it a colourful identity (see [the glass + vines spec](specs/glass-vines.md)); legibility and calm reading come first, and the vines can be stilled or turned off. Avoid a cluttered gamification dashboard.

VALIDATE APPLE BOOKS ACCESS FIRST

Create a diagnostic that establishes what this Mac’s installed Books version exposes:

* Reading window versus library/store.
* Active book when multiple windows are open.
* Stable book identity, title, author.
* Current page, total pages, location, or progress.
* Existing cover artwork, including custom/imported covers where accessible.

Investigate Accessibility APIs, actual scripting capabilities, and read-only local metadata where necessary. Verify data freshness and identity matching. Do not invent scripting properties, database schemas, or public APIs.

Never modify Apple Books databases or bypass DRM. Avoid screen capture, OCR, and full-library rescans as the default approach.

Produce a capability table showing verified, unavailable, and untested fields. Continue with graceful fallbacks when optional metadata is unavailable.

If this environment cannot inspect my Mac, implement a runnable diagnostic and clearly distinguish locally verified behavior from assumptions.

READING DETECTION

Define and document a small, explicit tracking state machine.

Default automatic eligibility:

* Books is the foreground app.
* A real book-reading window is active.
* The display is awake and the user session is unlocked.
* Tracking is enabled.

Opening the library or leaving Books in the background must not count.

Pause immediately on switching away, locking, sleeping, closing the reading window, or losing required access. A brief interruption may remain part of the same session, but its paused duration must be excluded.

Support a user-started manual reading mode for paper books or deliberate side-by-side reading. Label manual records separately.

Lack of keyboard/mouse input alone must not stop ordinary reading. Page changes provide useful evidence when available, but cannot prove attention.

Continue crediting eligible foreground reading during long static pages. Do not impose an inactivity threshold or require readers to approve recorded time.

Clearly describe all automatic time as inferred reading activity. Do not claim perfect attention detection.

SESSION AND DATA MODEL

Use a durable local database, preferably SQLite, with transactions, migrations, and recoverable backups.

Store enough structured evidence to reconstruct and audit totals:

* Stable book IDs and observed metadata.
* Session and interval IDs.
* Start/end timestamps, timezone context, and durations.
* Tracking-state transitions and pause reasons.
* Observed page/location/progress changes.
* Metadata source, observation time, and confidence.
* Periodic recovery checkpoints.
* Manual records, corrections, exclusions, and goal changes.
* Cover references and provenance.

“Log everything” means all relevant reading events. Do not collect book prose, screenshots, keystrokes, unrelated application titles, or continuous redundant samples.

Use append-only original observations and explicit correction records where practical. Deleting personal data must actually remove it, including documented backup handling.

Use monotonic elapsed time within a running interval and wall-clock timestamps for calendar placement. Never derive trusted elapsed durations solely from wall-clock subtraction.

Persist bounded checkpoints, such as every 15 seconds while tracking, plus state changes. On crash recovery, credit only durably evidenced time and record the recovery without inventing the missing tail. Never count downtime until the next launch.

Prevent overlapping intervals, duplicate event processing, and double counting after restart or import.

BOOK IDENTITY AND PROGRESS

Preserve history when a book is renamed or its cover changes. Avoid merging different editions merely because their titles match. Provide a reversible manual merge/unmerge workflow if identity is ambiguous.

Store observed page numbers separately from inferred progress.

Handle:

* Backward navigation and rereading.
* Large jumps and table-of-contents navigation.
* Changes to font size, window size, and pagination.
* PDFs versus reflowable EPUBs.
* Missing or stale progress.

Do not calculate “pages read” as end page minus start page. Only offer page-based statistics when their assumptions are defensible; label estimates and omit unreliable metrics.

Do not claim words-per-minute without an actual reliable word-count source.

STREAKS AND GOALS

Default the daily goal to 20 credited minutes, configurable during setup.

A streak day qualifies when credited reading reaches that day’s goal. Show:

* Today’s progress.
* Current and longest goal streaks.
* A reading calendar.
* Days with any reading, distinct from goal-completion days.

Before today ends, preserve a streak completed through yesterday and show today as pending.

Use an explicit configurable calendar timezone, initially the Mac’s timezone. Split intervals across local midnight correctly and handle daylight-saving changes.

Persist goal changes with effective dates. By default, changing the goal affects today and future days without silently rewriting past qualification rules.

Recompute affected totals and streaks correctly after session corrections.

Keep manual additions visibly identified. Allow transparent correction of missed tracking without hidden “streak repair.”

DASHBOARD

Provide:

* Today: goal, credited time, current session, streak.
* History: calendar and daily/weekly/monthly totals.
* Library: covers, per-book time, first/last read dates, progress when reliable.
* Book detail: session timeline and observed progress history.
* Reading sessions: optional edits to adjust start/end, split, reassign, exclude or delete.
* Reviews: private written book reviews and optional ratings.
* Data health: permission failures, tracking gaps, last successful capture.
* Settings and export.

Make every total traceable to its contributing sessions. Distinguish “zero reading recorded” from a known tracking outage.

Support CSV export of useful tables, versioned JSON export/import of complete reading history, and database backup/restore. Test round-trip preservation and duplicate-safe imports.

Keep diagnostic logs bounded; retain reading history until the user deletes it.

COVERS

Prefer the exact artwork already associated with the book in Apple Books, including custom covers when retrievable.

Cache accessible artwork locally and refresh when it changes. For accessible unprotected EPUBs, investigate embedded cover extraction as a fallback. Also allow a manual image override.

Do not silently replace a custom cover with a different edition’s artwork. Do not perform external cover searches without an explicit setting.

Local dashboard artwork and Discord artwork are separate delivery paths. Verify the current Discord mechanism and selected integration’s support.

A local filesystem image path is not a complete Discord image-sharing solution. Use verified supported assets or remotely accessible artwork where appropriate. If custom cover publishing needs an upload, offer an explicit opt-in flow explaining where the image goes and how it can be removed.

If no supported cover-sharing route is available, keep the exact cover locally and use a generic Discord asset.

DISCORD

Tracking must work fully offline and without Discord running.

Publish only explicitly enabled current activity:

* Title.
* Author where available.
* Reliable page/progress information.
* Active elapsed session time.
* Cover where supported.

Use actual supported activity fields and types. Verify that the selected SDK or IPC route works on this macOS version. Do not assume all Discord integration methods have identical capabilities.

Do not use a user token, self-bot, or modified client. Document any application-ID and artwork setup.

Reconnect gracefully, rate-limit updates, clear presence when reading stops, and exclude pauses from the displayed elapsed timer.

Sharing controls must be independent of local logging. Provide per-book sharing exclusions and separate per-book tracking exclusions. Historical statistics remain local unless explicitly exported.

SCOPE AND VERIFICATION

The first release tracks reading observed on this Mac. Do not imply automatic iPhone/iPad coverage or historical backfill unless an actual data source is verified. Provide labeled manual/imported records instead.

Build in this order:

1. Books capability diagnostic.
2. Durable tracker and session-state model.
3. Menu-bar controls.
4. Dashboard, corrections, goals, streaks, export/restore.
5. Exact local covers and Discord integration.
6. Packaging, login startup, and operational verification.

Write meaningful tests for timing, midnight/DST boundaries, goal changes, corrections, crash recovery, overlapping sessions, and export/import. Verify foreground switching, reading-window detection, permission loss, sleep/wake, and Discord reconnection on a real Mac where available.

Deliver the source, runnable build where possible, concise setup instructions, and an honest verification report. Document remaining limitations and measured or bounded potential data loss. Never label untested integration behavior as working.
