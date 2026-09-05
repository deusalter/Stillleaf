# Library and rating refinement review

The main task owns source changes and installation. Reviewed actual `LibraryView.swift`, `FinishedBookView.swift`, native Library, Book details, and completion prompt renders.

## Library

Current cards prioritize page count, pace, time, started date and last-read date over cover/title. Finished switches to a different row presentation. Recommended cover-led cards with consistent portrait proportions, serif title, author, and one meaningful recent/finished line. Statistics stay in Book details. Preserve Reading/Finished/All, add clear sorting and shelf counts, keep title/author search. Do not fabricate completion percentage from tracked page totals. Preserve merge-resolved identity and finished semantics. Review multiple books, long titles, absent author/cover, and empty/search states.

## Rating

Current rating uses passive 18 pt stars above a stock tick slider. Recommended 28–32 pt directly interactive fractional stars, stable numeric display, and precise quarter-step keyboard adjustment. Hover is a temporary preview, selection changes the draft, Save persists, Cancel restores, Clear removes rating. Zero remains distinct from no rating.

Suggested motion is a short fractional-fill interpolation plus a modest selection response, without moving the entire sheet or continuously bouncing while dragging. Reduced Motion updates immediately without scale or interpolation. Preserve accessible adjustable control semantics and focus indication.

Fable was cited only as the user's quality reference. Its exact animation was not observed or asserted.

Review endpoints: nil, 0, 0.25, 4.25, 5; pointer outside bounds; keyboard adjustment; focus; save/cancel/clear; fractional fill; reduced motion. Finished cards should show compact saved rating, revealing the editor only on Rate/Edit.

## Discord prominence

Preference switches belong in Settings, not the reading dropdown or persistent sidebar. Per-book sharing/artwork controls should remain accessible in a secondary disclosure. Network/privacy copy remains adjacent to public-cover opt-in.

## Implementation and visual checkpoint

Reviewed new Library and rating source plus `.local/design-refinement/library-light.png`, `finished-prompt-light.png`, `rating-quarter-{light,dark}.png`, `rating-empty-light.png`, and `rating-zero-light.png`.

The native rating styling is materially improved: larger stars, subtle backing surface, fractional amber fill, stable numeric value and compact exact-adjustment controls. Nil and zero render distinctly. Library now uses cover-led cards, shelf counts, search/sort, and an optional Finished timeline. The available Library preview has only one reading card, so it does not yet demonstrate a populated grid.

Source inspection confirms quarter-step pointer/drag/keyboard/accessibility actions and reduced-motion guards. The 234 pt input rail matches five 42 pt hit regions plus four 6 pt gaps; endpoints and quarter-step mapping are consistent by inspection. A 140 ms fractional-fill interpolation and hovered-star scale are implemented, but temporal motion quality has not yet been observed. Requested an app-owned transition sequence/live interaction check from the main owner.

Actionable issues sent to main:

- Clear hover preview when keyboard or accessibility adjustment changes the draft, otherwise displayed value can conceal the adjustment.
- Preserve editor/completion prompt on rating write failure. Existing timeline editors close unconditionally, and `saveRating` clears pending completion after `perform` even if persistence failed.
- Verify visible keyboard focus on plain Library card buttons.

Main owner applied all three source findings. Independently re-read and confirmed hover clearing in keyboard/AX paths, error guards before closing timeline editor/clearing pending completion, and a focus outline on Library cards.

## Final visual review completed

Reviewed `.local/design-refinement-final/library-{light,dark}.png` with an eight-book fixture (six books on the Reading shelf), including long titles and a long author. Grid spacing, shared card heights, two-line titles and author truncation are consistent. The sort menu now uses the theme.

Reviewed `rating-motion-normal-{start,middle,end}.png` and its native render harness. The harness changes the actual rating binding from 0 to 4.25, then samples at 0.01, 0.07 and 0.25 seconds. Intermediate star masks visibly interpolate before reaching the quarter-star endpoint; numeric value remains the selected target, with no layout movement. This establishes native binding-driven fill interpolation. It does not establish continuous frame pacing, live pointer/hover response, or reduced-motion runtime behavior; those remain main-task interaction checks.

Independent source/static/available-transition review is complete. Main owns remaining installed interaction verification and installation. No parity with Fable's unobserved animation is claimed.
