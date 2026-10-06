# Local audiobook playback and logging

Shipped in the native app. This note covers the user flow, supported media and how Library and History use audiobook records.

## User flow

- Library → Audiobook → Import local audio creates a library entry from the filename.
- Book details → Book format → Audiobook supports any existing library book. Import local audio attaches one file to that book.
- Open audio player exposes play/pause, a seek slider, back 15 seconds, forward 30 seconds, volume, and 0.5–2× speed. The Library also exposes the loaded player after closing book details.
- Log listening saves content position / total duration, with an optional actual listening session. The generic Add reading time sheet also links to this flow. Choose an existing library ID instead of creating a duplicate title.
- Current position accepts `2:15:00`, `2:15` (hours:minutes), or `135` (minutes). A total duration of `10:00:00` produces 22.5% progress for that position.
- Position alone never adds elapsed time or pages. For interrupted manual sessions, enter separate sessions excluding breaks.
- Playback position persists on seek, pause, finish, normal termination, and approximately every five seconds. The display updates every second. A crash can lose the last uncheckpointed seconds.
- Playback pauses on system sleep/lock and before history mutations or tracking-setting changes. There is one active audio player. Native reading and external Apple Books tracking are suspended while audio is playing to avoid overlapping credit. Audiobook playback does not publish Discord presence.

## Media scope

Local files only. The chooser accepts MP3, M4A, M4B, AAC, WAV, AIFF/AIF, and CAF. Import verifies that AVAudioPlayer can decode the actual file; an extension alone does not establish support. Protected, corrupt, and unsupported codecs are rejected. There are no stores, accounts, purchasing, streaming services, or DRM workarounds.

One file per book. Embedded chapter navigation, multi-file chapter assembly, remote media keys, and sleep timers are not implemented. Original files remain untouched; app-managed copies live in `Audiobooks/` next to `history.sqlite`. Removing an audio copy moves it to Trash while preserving its journal and position. Reattaching audio with a matching duration restores its saved position; a different duration starts at zero. Duration matching allows 1% or one second of encoding/rounding variance.

History JSON/CSV and SQLite backups preserve metadata, time, and position, **not the audio bytes**. Keep originals separately; after restoring onto another Mac, remove the missing managed-file reference and import that original again. Audio editions cannot be merged through the UI, because content positions and audio files belong to a particular edition. A book can instead receive an audio attachment directly.

## Integration contract for Library and History owners

`BookRecord.format: BookFormat?` is optional; `resolvedFormat` defaults old records to `.text`. `.audiobook` selects content-time presentation. `audioFileName: String?` is a validated basename in managed storage.

`ProgressObservation.audio: AudiobookProgress?` contains `positionSeconds` and `durationSeconds`. Its `fraction` is 0–1; `description` is `H:MM:SS / H:MM:SS`. Format `fraction` with `.percent.precision(.fractionLength(0...1))` for a readable percent. `sessionID: String?` associates a checkpoint with an optional actual session. Page fields must be nil for audio observations.

`AppModel.audiobookProgress(for: bookID)` returns the latest audio position for that exact edition. `AppModel.audiobookProgress(in: ReadingSessionGroup)` returns the latest session-linked position within the group's bounds. Session `creditedSeconds` remains actual elapsed time; never substitute a position delta or content duration. A backdated manual session does not replace a newer position.

`ReadingInterval.audioSessionID: String?` retains the original audio evidence session through splits and reassignment. `AppModel.isListening(_:)` identifies audio intervals even when a split fragment has no checkpoint of its own. Session position lookup checks book identity and interval bounds, so reassignment cannot borrow another book's position.

Native playback intervals use `ReadingMode.listening`. Explicitly entered sessions retain `.manual`. Listening groups preserve their session IDs and remain visible even below the general automatic-noise threshold. Changing a book format does not reclassify its old text-reading intervals; book details keep other reading time separate. No page-turn, page-coverage, or page-pace logic changed. Existing history totals and minute goals include listening time; page goals receive no invented pages.

The SQLite table layout stays at version 1: this repository stores Codable payloads, and additive optional fields decode old rows/archives in place. No destructive migration or history rewrite is needed. Older app versions do not understand the new `listening` enum value; use this or a newer build to read backups containing native listening sessions.

`ReadingStore.saveAudiobook` atomically saves book metadata, a content checkpoint, and an optional independent elapsed interval. Validation rejects nonfinite/negative/out-of-range content positions, mixed page/audio units, and interval overlap. Its interval caches are invalidated on transaction rollback as well as success. Failed player checkpoints retain stable observation/interval IDs and retry before playback resumes; an acknowledged retry cannot double-credit an already committed interval. Normal Quit waits for that checkpoint to save and reports storage errors instead of discarding it.

Cross-cutting files:

- `Sources/BooksCore/Models.swift`, `ReadingStore.swift`, `ReadingSessionGrouping.swift`, and new `AudiobookProgress.swift`.
- `Sources/BooksPlatform/LocalAudiobook.swift`: managed copy/decode validation.
- `Sources/BooksPresence/AppModel.swift`: persistence, native-tracker exclusion, lifecycle and integration helpers.
- `LibraryView.swift`: small import/log entry points, player/book-detail section, audio-aware detail/session labels. The separate Library owner should retain their percent/current-total design using the helpers above.
- `ControlsView.swift`: one audiobook logging entry point. `BooksPresenceApp.swift`: development smoke switch. `UIRender.swift`: only makes the existing native renderer helper internal so the audio demo can reuse it.
- New `AudiobookPlayer.swift`, `AudiobookViews.swift`, and `AudiobookSmoke.swift`. No `HistoryView.swift` or shared theme/motion changes.

## Validation and demo

`scripts/check-local.sh` includes `scripts/audiobook-smoke.swift` and the native audiobook integration test. The latter uses isolated temporary history and a generated silent WAV, mutes playback, renders only synthetic app views, and never launches or changes the installed app:

```sh
.build/local/BooksPresence --self-test-audio .local/audiobook-review
```

Core smoke coverage: legacy decoding, separate content/elapsed units, invalid mixed-unit rollback including caches, position-only saves, sleep gaps, visible listening sessions, and JSON/CSV/SQLite-backup round trips. XCTest equivalents live in `Tests/BooksCoreTests/AudiobookTests.swift` for a full Xcode toolchain.

Native coverage: attaching to an existing library ID, manual session time, muted AVAudioPlayer playback at 2×, seeking while playing and paused, no paused-time credit, session-position association, reopening/resume, active tracking exclusion/toggle boundaries, end-of-file position, write-failure recovery before and after commit, blocked Quit/recovery, split/reassigned session identity, and corrupt-file cleanup. The native fixture verifies WAV playback; other accepted containers remain subject to macOS codec support.

Local SwiftPM/XCTest is unavailable on this host (`xcrun` cannot resolve SDK `PlatformPath`, and XCTest is absent). Direct compiler builds, executable core smoke suites, and native model/view tests are the local validation path. CI XCTest was not run in this worktree.
