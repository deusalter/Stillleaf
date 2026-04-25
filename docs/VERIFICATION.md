# Verification report

Date: 2026-09-17. Host: Apple Silicon, macOS 26.0.1, Apple Books 8.0. The source and development bundle target macOS 13+.

## Executed locally

| Check | Result |
|---|---|
| Direct full native build (`scripts/build-local.sh`) | Passed with installed Swift 5.8.1 / macOS 13 SDK |
| Core behavioral harness (`scripts/core-smoke.swift`) | Passed: timing, pause exclusion, uncertainty, recovery, correction/deletion, import idempotency/atomicity, backup/restore, DST and goals |
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

Local `swift test` cannot execute because this Command Line Tools installation lacks XCTest and SwiftPM's SDK PlatformPath support. The assertion harness is a separate local check, **not a substitute claim that XCTest ran locally**. The [macOS CI run for 3173557](https://github.com/deusalter/BooksPresence/actions/runs/35288060693) passed all 28 XCTest cases, the release build, development app packaging and artifact upload. Subsequent commits run the same checks; consult the repository Checks tab for the final branch result.

## Important review fixes

Independent review identified and implementation corrected: split/reassignment deletion resurrecting originals or deleting unrelated siblings; wall-clock ordering of corrections/goals/merges/recovery; backward-clock interval overlap; unsafe backup over the live database; zero-minute imported goals; loss of cached covers on transient access failure; incorrect Discord timestamp units and IPC partial-frame handling; app-ID changes and status reporting; reversed pause control; missing daily traceability; and private data-directory permissions. Focused regression checks cover the core cases.

Duplicate-ID checks compare canonical serialized records so fractional timestamp round-off cannot turn an identical retry into a conflict. Regression coverage includes a known non-exact `Date` round trip, repeated event/interval/correction insertion, repeated JSON import, and adjacent submillisecond intervals. The archive keeps its original fractional-millisecond timestamp representation.

Checkpoint insert validation uses an in-memory ordered effective-interval cache, avoiding a full-history decode for each checkpoint. Calendar totals split intervals in one pass. Presentation refreshes at checkpoint cadence while active and on state/day changes while paused. Very large archive presentation/import/restore remains synchronous and has not been stress-tested at multi-million-record scale.

## Bounds and recovery semantics

Within supported operation, ticks are no more than five seconds apart. Checkpoints occur at 15 seconds of accumulated time, so a crash's uncommitted tail is less than 20 seconds under that cadence. A tick gap exceeding five seconds is an outage; that gap is not credited. A persisted start/checkpoint without a closing marker produces a recovery event with an **unknown** tail duration, never estimated downtime. Uncertain time is separate and excluded until reviewed.

If the wall clock moves backward behind previously recorded time, tracking holds with a clock-discontinuity reason until placement can resume without overlap. This may leave a visible gap; it does not invent trusted wall-clock durations or stop with a database-overlap error.

## Checks still requiring user/device interaction

- Grant BooksPresence its own Accessibility permission, then verify an EPUB and PDF reading window, Books library/store, two simultaneous book windows, window closure/minimization, foreground switching and permission revocation. The AXDocument-based rule is deliberately conservative and may leave some Books reader implementations unsupported.
- Active-reading lock, sleep, wake and fast-user-switch transitions end to end. Diagnostic state changes alone do not prove correct timing at every real transition.
- Live current page/location/pagination freshness. This release omits these metrics until verified; saved catalog progress is explicitly unreliable.
- Visual screenshot, accessibility/VoiceOver and click-through review after the computer-use service is available. Native view layout checks do not establish visual polish on every display.
- Login after an actual logout/reboot, persistence of permission with a Developer ID-signed install, and uninstall from an installed app location.
- Discord READY/publish/render/clear/reconnect with the user's own valid application ID and developer asset. No account token, self-bot or modified client is used.

No iPhone/iPad backfill, external artwork lookup, artwork upload, or live Discord custom-cover route is claimed. The app is a development build, not notarized.

## Data-handling notes

Only synthetic fixtures are committed. Personal catalog paths/titles/artwork and diagnostic output stay outside Git. After relaunch, `stat` verified support-directory mode 0700 and database/WAL/SHM modes 0600; the cover cache directory was 0700. User-selected exports/backups are private files but remain at their chosen destinations; app deletion cannot remove external copies, filesystem snapshots or SSD remnants. Artwork references are archived; copying the local cache is necessary when migrating image bytes to another Mac.

## Repository and execution

Private repository: [deusalter/BooksPresence](https://github.com/deusalter/BooksPresence), branch `main`. The existing HTTPS OAuth credential lacked `workflow` scope; the existing, authenticated SSH credential successfully pushed source and Actions without requesting broader token permissions. Commit messages use the configured user identity and real timestamps, with no attribution trailers.

Requested Sol High and Terra High worker overrides were accepted by the delegation tool. Primary model/reasoning configuration was not independently exposed. Independent code review ended with no open critical or important findings after fixes; live integrations remain subject to the checks listed above.
