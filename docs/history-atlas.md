# History: Reading atlas

The four native History scales share credited elapsed time and the existing page-statistics model:

- **Day:** time-of-day lanes per linked book, with session cards and interval correction controls. Adjacent display intervals form continuous visual spans; totals and reviews retain original evidence.
- **Week:** stacked credited minutes by book. Page totals are shown separately.
- **Month:** each ring partitions a day's credited time among books. Rings do not represent goals. Selecting a date shows details and a link to Day.
- **Year:** marks show actual recorded days; faint spans connect the first and latest session. Diamonds require explicit completion records. Month headings and day marks navigate to their corresponding scales.

`HistoryAtlas` clips time using half-open periods and apportions corrected durations by elapsed overlap. Calendar midnights handle daylight-saving changes. Excluded intervals remain reviewable but contribute no chart time; uncertain intervals stay separate from credit.

Pages use `AppModel` accessors backed by complete effective history and `PageStatistics`. They are never derived by summing raw page-turn events or passing a narrowed evidence set. Linked books use canonical display identities. Historical audio positions match original edition and session evidence within the selected interval/day, rather than a book's current position.

The local Atlas palette adapts to light and dark appearances without changing shared themes or icons. Native labels and buttons expose chart summaries and navigation to accessibility clients. Layouts adapt to narrower windows; Year retains a horizontally scrollable timeline when necessary. The views add no motion.

## Reproduce previews and checks

Build with `BOOKSPRESENCE_SKIP_READER_BUILD=1 scripts/build-local.sh`. The built executable accepts `--render-ui <output-directory> --history-atlas` to render isolated synthetic fixtures for all scales and both appearances, plus compact, dense, sparse, empty, uncertain, and linked-book cases. Preview stores are temporary and tracking is disabled.

Run the app's `--self-test-ui` for native layout and model correction checks. `scripts/history-atlas-smoke.swift` provides direct-compiler checks for corrected time, daylight-saving boundaries, linked identity, exclusions, and historical audio. Equivalent XCTest coverage is in `HistoryAtlasTests.swift`. Existing progress-coverage, calendar, session-history, manual-pages, and audiobook smoke checks cover the model paths consumed by the views.

The only shared preview entry-point change is the `--history-atlas` dispatch in `UIRender.swift`.
