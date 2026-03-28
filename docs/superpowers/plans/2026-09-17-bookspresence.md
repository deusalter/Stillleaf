# BooksPresence Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development with the user's explicit parallel execution and Git authorization. The primary owns shared configuration, integration, commits and pushes.

**Goal:** Deliver a native menu-bar reading tracker with auditable local history and optional Discord presence.

**Architecture:** A pure Swift core persists evidence and corrections in SQLite. A conservative macOS adapter obtains reader identity from Accessibility and a read-only Books catalog. SwiftUI views consume one main-thread application model; Discord runs independently.

**Tech Stack:** Swift 5.8+, SwiftUI, AppKit, SQLite, ServiceManagement, Unix-domain IPC.

**Spec:** `docs/PRODUCT_SPEC.md`; contracts: `docs/INTERFACES.md`.

## Global Constraints

- Never modify Apple Books databases or bypass DRM.
- No screen capture, OCR, book prose, keystrokes, unrelated app titles, or default library rescans.
- Automatic time is inferred reading activity. No title-only identity matches or credit for background/library windows.
- Monotonic timing, bounded checkpoints, no downtime credit; uncertainty excluded until reviewed.
- Local history and covers never enter Git. Synthetic fixtures only.
- No invented API claims, test evidence, commit dates, or attribution footers.

## Work packages and acceptance gates

- [x] Inspect real host, empty repository, Git identity, GitHub authentication, Books bundle, read-only catalog schema, and Accessibility trust.
- [ ] Root: runnable privacy-limited diagnostic and capability table. `swift run books-diagnostic` must distinguish unavailable access from missing optional fields. Probe only actual installed APIs and schema.
- [ ] Sol High: core storage, engine, statistics and tests. Own `Sources/BooksCore/{ReadingStore,TrackingEngine,ReadingStatistics}.swift` and `Tests/BooksCoreTests`. Contracts above are binding. Exercise pause exclusion, DST, midnight, recovery, corrections, goals, overlap rejection and duplicate-safe round trips.
- [ ] Terra High: native views in `Sources/BooksPresence/*View.swift`; follow AppModel contract. Today, History, Library/details, Review, Health, Settings, menu popover and separate privacy controls must be accessible.
- [ ] Root: metadata/cover adapters and integration AppModel. Reject uncertain window identification; preserve IDs, exact artwork, source dates, and exclusions. Add focused synthetic adapter tests.
- [ ] Terra High: optional Discord IPC, singleton, login and packaging. Use official IPC fields, generic configured asset, disabled by default; no upload. Test partial frames, clear, reconnect and pause-adjusted timers. Build an LSUIElement app without initial windows.
- [ ] Root: integrate, run build/tests, inspect UI and process lifecycle, document verified vs untested behavior, package app, add macOS CI.
- [ ] Sol High fresh reviewer: inspect actual code and evidence for data loss, overlap, migration, recovery, privacy and test gaps. Fix concrete findings, rerun affected checks.
- [ ] Root: inspect intended staged contents, factual commit messages, push coherent verified milestones, and confirm remote SHA.

## Evidence ledger

Initial host: macOS 26.0.1 arm64, Books 8.0. Installed CLT Swift 5.8.1 uses swift-frontend symlinks; direct swiftc compiles, use swift-build/swift-test binaries if driver commands fail. AX trust is false in the initial CLI probe. Books running, catalog readable with 100 asset records; asset IDs/path/title/author/progress columns verified. Catalog has no populated ZCOVERURL values. Books.plist exists with actual path and book-info keys. No scripting dictionary or NSAppleScriptEnabled declaration found; sdef unavailable without full Xcode. Raw personal output is never committed.

## Integration decisions

- Primary owns Git and shared files; explicit user authorization supersedes skill permission prompts for private repository creation/commits/pushes. Workers use non-overlapping ownership in this fresh checkout.
- Requested Sol High and Terra High model overrides were accepted by the delegation tool. Primary model/effort is not independently inspectable.
- Local direct compiler builds and separate behavioral harnesses replace unavailable local XCTest execution; genuine XCTest runs in remote macOS CI.
- User reported computer-use access enabled, but tracker AX trust remained false and CUA queries timed out. Continue without screenshot or live reader claims.
- Root/worker review fixes are documented in VERIFICATION.md; no personal probe output enters Git.
