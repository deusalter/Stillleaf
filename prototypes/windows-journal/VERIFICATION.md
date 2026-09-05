# Verification record — September 24, 2026

Host: macOS 26.0.1 arm64; Node 22.18.0; Electron 44.4.5; Playwright 1.63.0.

Passed locally:

- `npm install`: dependencies installed and lockfile written; npm reported 0 known vulnerabilities at install time.
- `npm test`: 10 tests covering independent position/count/time, rereading and backwards position, date ordering, persistent Unicode history and shelves, previous-state backup, validation/no disk mutation on invalid input, duplicate titles, entry removal, corrupt/unknown-version preservation, failed-write state consistency, clock rollback on reopen, and bounded Sumatra fixture parsing.
- `npm run test:desktop`: actual Electron UI with sandbox/preload/main-process IPC and temporary filesystem data. Added a book, saved position-only and explicit count/time entries, changed shelf, rejected an invalid IPC entry, exported JSON, closed/relaunched, verified restored data and removed an entry. No observed renderer page errors; no horizontal overflow at 800px viewport. Native save dialog selection was stubbed to a temporary path; actual dialog operation remains a manual check.
- `npm run package:windows`: generated `dist/StillleafJournal-win32-x64` successfully on Mac. `file` identifies its executable as PE32+ GUI x86-64 for Windows. This verifies packaging, not Windows execution.
- Rendered screenshot inspected at `test-output/journal.png`; sea-glass palette follows current Mac reference. Screenshot uses disposable test data, not a seeded user journal.
- `git diff --check`: no whitespace errors.

Still requires Windows:

Executable launch, native save-dialog behavior, restart/rename/backup behavior on Windows filesystems, second-instance focus, keyboard accessibility with a screen reader, DPI scaling, security prompts, recovery workflow and real SumatraPDF settings/version behavior. Follow the checklist in README.md.

No Mac Swift sources or existing release workflows were changed. No Windows installer/signature, live reader connection, Discord transport, archive interchange with BooksCore or public download site was implemented.
