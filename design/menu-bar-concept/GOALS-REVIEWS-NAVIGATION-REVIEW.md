# Goals, written reviews, and navigation review

Reviewed 2026-09-24 against the live implementation checkout at `/Users/abhinavnamboori/Documents/ChatGPT/Apple Books RPC`. This task is read-only for app source; the main implementation task owns fixes, builds, and installation.

## Native goals and editor previews

Inspected light and dark `settings-minutes`, `today-minutes`, `popover-minutes`, and `written-review` images in `.local/design-goals-reviews`.

- Daily Pages/Minutes choice and optional yearly goal have a clear hierarchy. The source retains independent page/minute targets and stages the goal choices with Reading settings Save/Revert.
- Today and the menu bar consistently display the selected minutes goal, with pages secondary. The annual goal is visually separate.
- The written-review editor gives prose adequate space. Privacy, character limit, Clear, Cancel, and Save are legible without clipping.
- Source retains the editor after a save error. However, X and Cancel directly dismiss changed text. Sent the main task a request for draft retention or dirty-only discard protection, including relevant system dismissal paths.
- The six-line review excerpt uses a 400-character threshold for its full-text link. Short multiline text can truncate below that threshold; Edit remains available. Sent as a minor affordance issue.

These are native layout/source observations, not installed-app interaction or persistence-test claims.

## Latest author direction

- Library, Timeline, and Reviews are separate primary destinations.
- Library defaults to all known/configured/imported books and retains useful shelf filters and sorting.
- Timeline is a large vertically scrolling chronology of completed books, with prominent completion dates and visible ratings. No Recent sort control.
- Reviews means personal written book reviews. Tracking diagnostics and uncertain/session correction rows belong in secondary Troubleshooting or contextual correction actions. The Reviews badge must not count uncertain intervals.
- History remains a reading-activity calendar, distinct from completed-book chronology.
- Zero-page session clutter must not leak into personal Reviews or Timeline. This does not authorize deleting source history or suppressing meaningful time-only sessions from correction tools.

## Reference and implementation review

Apple's official [Books for Mac collections guide](https://support.apple.com/en-gb/guide/books/ibks33867842/mac) describes Finished as a timeline, includes automatic and manual completions, and documents viewing/editing completion dates. This verifies the reference's chronology semantics; no exact visual replica is claimed.

The updated timeline source uses 44-point day anchors, 31-point year headings, larger book cards, a calendar in the configured time zone, newest-first completion order, and a separate explicit undated section. Library now defaults to All.

## Final journal preview pass

Inspected `.local/design-journal-final/timeline-dark.png`, `timeline-light.png`, `timeline-compact-dark.png`, `review-dark.png`, and `review-light.png`.

- Separate Library, Timeline, History, and Reviews navigation is visible and coherent. Reviews has no diagnostic badge.
- Timeline dates and covers now have the requested prominence, ratings are visible, and Recent sorting is absent. The compact layout stacks dates above cards without horizontal clipping.
- Personal Reviews shows written text, book identity, updated date, and Read & edit. No session rows or zero-page diagnostics appear. Source retains correction tools under Troubleshooting → Reading records.
- Source now guards changed-draft dismissal through X, Cancel, and Escape, disables interactive dismissal while dirty, and always offers the full-review link. Save errors still keep text in the editor.
- Found a visible date-formatting defect: September displayed as `M09` in both themes and the compact timeline. Reported to main, which added `calendar.locale = .current`; verified that source fix. Subsequently inspected `.local/design-journal-release/timeline-dark.png`: both completion dates correctly display `Sep`. The visual finding is resolved.

No other actionable visual issue found in these supplied screens. This pass does not establish installed-app scrolling, accessibility interaction, system window-close behavior, or data persistence; those remain main-task validation responsibilities.
