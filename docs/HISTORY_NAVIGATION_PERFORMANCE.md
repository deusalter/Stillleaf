# History navigation and presentation

History now uses a native current-scale menu beside the previous/next/Today controls.
The menu's inline Picker supplies the selected checkmark. The existing serif period
title, palette, chart appearance, and responsive title/control layout are retained.
Published content has a 120 ms opacity transition; Reduce Motion disables it.

## Computation

The committed `HistoryPresentation` prepares an immutable `HistoryAtlasSource` on
the existing refresh queue. The AppModel integration consists of a published source
and its assignment after applying a committed archive. Explicit edits retain the
existing synchronous refresh behavior.

`HistoryAtlasCache` computes a period on its actor executor. It retains at most
eight periods from one archive revision. Keys include the archive revision,
timezone, scale, exact half-open period, current civil day, and locale. Revision
replacement clears the cache. Cancellation is checked before calculation and
before insertion. The main-actor controller checks both cancellation and a request
generation before publishing, including day → year → day navigation with identical
first/last keys.

Civil-day boundaries are computed once per period. Intervals use binary search to
find those boundaries; qualified page entries advance chronologically through
them. Clipped time is shared across summaries and session cards. Year rows carry
normalized day/finish positions, removing archive scans and calendar arithmetic
from Canvas drawing. Month detail uses prepared per-day book pages and historical
audio positions. Session manual pages query the globally qualified snapshot rather
than re-sorting and qualifying the entire event archive for each card.

Atlas children use immutable data, including book labels. While the same period's
archive revision refreshes, its previous committed presentation remains mounted to
preserve the selected day/book. Changing scale, period, timezone, civil day, or
locale cannot display that prior period under a new title.

## Cloud measurements

Measured in optimized Swift 6.0.3 on an x86_64 Ubuntu 24.04 cloud host, with 100,000
synthetic intervals, 100,000 page events and 100 books. No private history was used.
The source covers roughly 694 days. Measurements compare the archive-dependent
work in the views on `main@58ee97f` with prepared period computation. The benchmark
preserves the original calendar-bin algorithm independently of its optimized
replacement. Both paths produce matching total/mark checksums.

| Scale | Legacy view computation, median | Cold prepared computation, median | Warm actor cache, median |
| --- | ---: | ---: | ---: |
| Day | 3,136.829 ms | 2.193 ms | 0.082 ms |
| Week | 4.789 ms | 3.639 ms | 0.101 ms |
| Month | 37.197 ms | 6.238 ms | 0.070 ms |
| Year | 459.631 ms | 53.592 ms | 0.062 ms |

Cold/legacy medians use five iterations; warm cache medians use fifty. Preparing
the immutable source took 155.869 ms once for the revision, excluding the existing
general statistics/page-evidence preparation. Cold period work runs off the main
actor. Prepared-data reads rounded below 0.001 ms in this harness.

The Day baseline includes session manual-page qualification, which previously
sorted the entire event collection per card. The Month baseline queries all books
for the selected day's detail, matching the existing detail panel rather than
multiplying that work by every calendar cell.

These are CPU measurements, not native frame times or menu-to-frame latency.
Absolute results vary by hardware and history shape. The fixture contains no
audio observations; historical audio correctness is tested separately. A cancelled
calculation already in progress finishes its synchronous computation before the
post-calculation cancellation check, so rapid input can wait behind that one
discarded request on the cache actor.

Reproduce on a Swift-equipped cloud host with:

```sh
scripts/run-history-atlas-benchmark.sh 100000
```

## Validation and remaining review

All 137 BooksCore tests passed in the cloud Linux harness, including ten new period,
cache, cancellation, deletion, page-only day, DST, merge, audio and split-session
checks. The temporary test manifest exposes the repository's unchanged BooksCore,
CSQLite and BooksCoreTests targets without attempting AppKit targets. Swift syntax
parsing of the changed native files and workflow YAML parsing also passed.

macOS CI is configured to run the existing full build/test suite, the real
History controller smoke with reversed completions and cancellation, the synthetic
benchmark, and offscreen History previews. Previews cover all four scales at 1120
and 700 points in light/dark appearances, plus sparse, empty, review, merged and
dense fixtures. The images are uploaded as `Stillleaf-History-previews` for review.

Native type checking, runtime smoke, menu checkmarks, Reduce Motion behavior and
visual review have not been executed on this Linux host. They remain pending the
cloud macOS CI run and review. Explicit edit refreshes still execute synchronously;
this change targets navigation and routine background refresh presentation.
