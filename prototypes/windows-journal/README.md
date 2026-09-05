# Stillleaf Journal — Windows prototype

A standalone local desktop reading journal. Add books, choose shelves, log dated reading/progress and notes, review/remove mistaken entries, and export JSON. No reader, Discord, account or network service is required for journaling.

This directory is isolated from the Swift Mac app and its release scripts. It deliberately uses its own data directory and archive format. It neither reads nor migrates the Mac database. Prototype archive version 1 is **not** compatible with BooksCore archives.

## Run from source

Prerequisite: Node.js 22.12+ and npm; use a maintained Node release. Dependency installation needs internet access. The application itself is offline.

From this directory, in PowerShell or a terminal:

```sh
npm ci
npm start
```

Local development also runs on macOS. On Windows, target Windows 11 x64 for the first acceptance pass; other Windows versions and ARM64 are untested.

```sh
npm test
npm run test:desktop
npm run package:windows
```

`test:desktop` opens Electron and uses a disposable temporary data folder. It needs an interactive desktop. It does not use your journal. `package:windows` produces `dist/StillleafJournal-win32-x64/StillleafJournal.exe`. Copy **the whole folder** to Windows and run that executable. Node is not required to run the packaged app. A ZIP of that folder is a portable handoff, not an installer or public release. The configured package command was successfully run on this Mac; building on Windows remains another option.

The executable is unsigned. Windows runtime behavior, display scaling, filesystem replacement and security prompts require the Windows acceptance pass below. No installer, updater, launch-at-login or tray integration is included.

## Data and semantics

- Each book has a UUID. Identical titles are separate records; adding a similarly named book never merges its history.
- `position` is the user-entered page bookmark, bounded by total pages when known. Latest reading date wins; the last saved position wins within the same date. Backdated entries do not replace a newer bookmark. Zero represents the start.
- `pagesRead` is an independent, explicitly entered nonnegative integer. It can exceed the book length over repeated readings. Moving forward or backward does not create a page count.
- `minutes` is optional and explicitly entered, from 0 to 1440 per entry. Missing time remains null; it is never estimated from pages or application uptime. There is no timer.
- Reading dates use calendar `YYYY-MM-DD` in the user's local timezone. Invalid and future dates are rejected for new entries. Existing recorded dates are preserved on reopen even if the system clock or timezone moves backward. Recorded timestamps are UTC metadata, not time spent reading.
- Shelves are explicit. Reaching the last page does not change a shelf; marking Finished does not create pages or time.
- Corrections currently remove the mistaken entry, then allow a replacement. Removal recalculates position and totals. There is no permanent correction audit ledger in this prototype.
- All entries are manual. The optional Sumatra research probe writes nothing to the journal.

Storage:

- Windows: `%APPDATA%\StillleafJournalPrototype\journal.json`
- macOS: `~/Library/Application Support/StillleafJournalPrototype/journal.json`
- Tests only: `STILLLEAF_TEST_DATA` overrides the directory.

The single-instance main process validates all changes, flushes a complete temporary JSON file, keeps the previous file as `journal.json.bak`, then replaces the primary file by rename. Memory changes only after the write succeeds. The renderer has no filesystem API, Node access, external navigation or network requests. This is a small-journal snapshot store, not a scalable database or a full power-loss durability guarantee. Data is local plaintext, not encrypted.

If startup reports corruption, it stops without replacing the file. With the app closed, first copy the entire data directory somewhere safe. Recover by replacing `journal.json` with a known-good exported prototype journal or `journal.json.bak`, retaining the original separately. The backup is only the preceding save, not long-term history. Export regularly; there is no import UI or cloud sync.

## Windows acceptance checklist

1. Extract the whole packaged folder to a writable user location and launch `StillleafJournal.exe`. Record Windows version, architecture, display scaling and any launch error. Do not accept this prototype as Windows validated until this succeeds.
2. With readers and Discord closed and internet disconnected, add a book with 200 pages. Log position 80 only. Expect position 80, **0 pages logged**, and no duration.
3. Log position 60, pages read 10, minutes 15 and a Unicode note. Expect position 60, total 10 pages, 15 minutes. Add an older dated position 20; expect current position still 60. Mark Finished; totals must stay unchanged.
4. Close and reopen. Verify book, shelf, notes, history and totals persist. Open a second instance; it should focus the existing window.
5. Reject page 201, negative/fractional page counts and future dates. Remove an erroneous entry and add a correction. Verify recalculated totals survive another restart.
6. Export JSON to a chosen folder. Confirm the file has the book and entries. Canceling export must not claim a saved file. Use keyboard-only navigation and Windows scaling at 100%, 150% and 200%; check dialog focus, scrolling and readable labels.
7. Close the app and back up its data folder. Check recovery on a disposable journal: malformed JSON must stop with an error and preserve the malformed file; restoring the backup should reopen the earlier state.
8. Optional reader experiment: follow `READER_CONNECTION.md` with a **copy** of SumatraPDF settings. No journal or reader files should change.

## Architecture choice

Electron + plain HTML/CSS/JavaScript provides an immediately testable desktop slice on the available Mac and a Windows package from the same sources. No frontend framework, native ABI bridge, Rust build toolchain or extra database addon is needed. The tradeoff is a larger runtime and prototype business logic separate from Swift. This is evidence for the manual workflow, not a decision to replace the Mac app or adopt Electron permanently.

`src/journal.cjs` owns validation and persistence; `main.cjs` owns disk/dialog IPC and lifecycle; the sandboxed preload exposes specific journal operations; `renderer.js` renders text through DOM APIs. `tools/sumatra-probe.cjs` is an independent research utility. The palette follows the live Mac `ReadingPalette` inspected on September 24, 2026.

References: [Electron security guidance](https://www.electronjs.org/docs/latest/tutorial/security), [Electron distribution](https://www.electronjs.org/docs/latest/tutorial/application-distribution). Original project research was read from `docs/EXPANSION_RESEARCH_2026-09-24.md` in the saved checkout; it was not present in this worktree at task start.

See `VERIFICATION.md` for checks actually run and `READER_CONNECTION.md` for the bounded reader feasibility result.
