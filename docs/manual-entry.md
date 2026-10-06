# Add reading time

The **Add reading time** sheet logs reading that Stillleaf did not observe: a paper book, another reader, or an
audiobook heard elsewhere.

## Book | Audiobook

A glass segmented control at the top switches the form in place.

**Book** collects a book, what was read (**Time**, **Pages** or **Both**), and when.

- **Book search.** One field. Matches from the library (covers, title, author) come first, ranked by title prefix.
  With an empty field, the four most recent library books are offered. Below them, "Not in your library" shows
  results from [Open Library's search API](https://openlibrary.org/dev/docs/api/search) (no key). Requests are
  debounced (350 ms), a newer keystroke cancels the stale request, and results are remembered for the session.
  Offline or failing searches show a short message with "Try again"; typing a title and author by hand always works.
  Only the typed words are sent. The sheet says so. Cover images for results are fetched from
  `covers.openlibrary.org` by cover ID.
- **Outside books** are saved as `openlibrary:<work id>` library books with source "Open Library", their cover and
  `pageCount` when Open Library has them. The ID is deterministic, so adding the same work twice reuses it.
- **Time.** Presets (15 m, 30 m, 45 m, 1 h) or a custom length ("45", "1h 20m", "1:30"), finishing now by default.
  Choose Yesterday or any date instead and the finish moves to 8:00 PM, editable. "I know when I started" swaps the
  length for a start time. A plain-language summary ("30 min · today, 11:19–11:49 PM") shows what will be saved.
  Future times, overlaps with recorded reading, entries over 24 hours and impossible pages are refused with a message.
- **Pages.** A count, or, when the book's page count is known, a from-to range that also saves the reader's place.
  `from–to` means "started on page A, stopped on page B", which is `B − A` pages, the same convention as tracked turns.

**Audiobook** keeps the existing position/total fields and the optional listening session, in the same style.

## Data model

- `BookRecord.pageCount` (optional; absent in older archives).
- `ManualPageAdjustmentEvidence.fromPage/toPage` (optional; both or neither; `pages == toPage - fromPage`).
- Manual entries are `ReadingInterval(mode: .manual)` plus a `manualAddition` event (time) and a
  `manualPageAdjustment` event (pages) dated at the interval end. The page event is allowed on manual intervals as
  well as automatic ones; observed `pageTurn` events still require an automatic interval.
- **Pages without time** use a one-second *page marker*: a manual interval with `duration == 0`. It credits no time,
  is exempt from the no-overlap rule (it carries no time to double-book), and anchors the page event so existing
  page statistics qualify it like any other. Page goals, the book's page totals, history rows and the Atlas read it
  through `PageStatistics`, the same path as tracked pages. Reading pace still uses tracked pages only.
- `ReadingStore.saveManualEntry` saves the book, interval, events and position in one transaction.

No schema version change was needed: every addition is an optional field inside the existing JSON payloads.
