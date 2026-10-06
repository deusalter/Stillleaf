# Optional reading dates — local integration handoff

Baseline: `0e23ba631891e47a6e44da93ea888e548d184bfa` (Stillleaf 1.5 / build 17).
Branch: `codex/optional-completion-calendar`.
Integration owner: integrated EPUB reader task. No push, installed-app replacement,
normal app launch, permission changes, or real-data tests are authorized by this patch.

## Behavior

- `markFinished` is unchanged: the actual click records the finish instant immediately,
  without requiring dates, a rating, or a review. Repeated completion stays idempotent.
- The existing completion prompt offers “Reading dates · optional”; the timeline also
  offers date correction. The editor says the book is already read and provides an
  explicit Skip action. Closing/escaping/skipping discards date drafts only.
- Starts are optional and never inferred from sessions or editor-open time. Existing
  explicitly recorded starts initialize the draft. Old JSON without `startedAt` decodes
  with nil. No migration or backfill is performed.
- Save validates both dates, then appends manual completion evidence. Unchanged saves
  are no-ops. Corrections do not change the pending celebration event or create reading
  intervals/pages. Save errors keep the draft/editor open and preserve saved evidence.
- Validation uses the store's existing 1900–2200 date bounds, rejects dates later than
  the save instant, and requires start <= finish when both exist. Unknown finish dates
  remain unknown. Clearing a finish date keeps the completion but excludes it from
  dated timeline groups/year totals. It appears in the undated timeline group.
- Calendar selections preserve the existing wall-clock time through Calendar arithmetic;
  choosing the same day preserves the exact recorded instant, including fractions.
  A previously unknown date starts at local midnight. Today's selected time cannot
  exceed now. Time can also be explicitly edited. The app's configured timezone is used.
- Custom calendar surface uses the existing palette and short entrance animation;
  reduced motion disables its transitions/animations. Day buttons expose full dates
  and selected state, support focus/arrow navigation, and use Space to choose. Escape
  closes a focused calendar; the editor's Skip/Escape path never saves.
- CSV adds a trailing `started_at` column; existing column positions are unchanged.
  JSON/SQLite evidence includes the optional field, retaining export/restore semantics.

## APIs and touched integration points

`ReadingCompletionDates(startedAt:finishedAt:)` is a plain draft/validation value.
`ReadingDatesEditor(title:dates:timezoneID:save:)` accepts a durable-save closure returning
nil on success or a user-visible error string on failure. `initiallyExpanded` is a render
fixture option. `ReadingDateCalendar` does not access AppModel or the store.

`AppModel.saveReadingDates(_:for:)` resolves merged IDs and requires a currently finished
book. `BookCompletionEvidence` and `FinishedBookEntry` add optional `startedAt`.
`BookHistory` projects the chosen evidence's start alongside its finish.
`ReadingStore` validates the optional start and exports it. `FinishedBookView` contains
both presentation hooks. UISmoke/UIRender add only synthetic checks and previews.

## Verification and remaining limits

- Direct compiler build succeeds on the local CLT toolchain.
- Portable date smoke passes: range/order/unknown dates, DST wall time, exact same-day
  instant, old JSON decoding, store rejection, JSON restore, and CSV preservation.
- Existing core, discord, calendar, books, manual-pages, session-history, and goals
  smoke suites pass.
- Native `--self-test-ui` passes with isolated temporary history/defaults, including
  real SQLite-triggered write failure/retry, no-op saves, no duplicate celebration,
  no invented activity, and unknown-finish yearly totals.
- Synthetic light/dark native preview files are generated under
  `.build/calendar-previews/reading-{calendar,dates,dates-expanded}-{light,dark}.png`.
- Four XCTest cases are included for the reader lead's eventual full CI run. XCTest
  was NOT run locally: SwiftPM fails with the CLT PlatformPath error and the CLT SDK
  does not include the XCTest module. Equivalent portable checks ran instead.
- Native renders check layout, not interactive keyboard/VoiceOver behavior or measured
  animation pacing. Interactive assistive-technology and system reduced-motion checks
  remain for combined release verification. No claim of Apple Books parity is made.

Reproduction after `bash scripts/build-local.sh`:

```sh
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -I .build/local -I Sources/CSQLite -L .build/local -lBooksCore \
  scripts/reading-dates-smoke.swift -o .build/local/reading-dates-smoke \
  -Xlinker -rpath -Xlinker @executable_path
.build/local/reading-dates-smoke
.build/local/BooksPresence --self-test-ui
.build/local/BooksPresence --render-ui .build/calendar-previews
```
