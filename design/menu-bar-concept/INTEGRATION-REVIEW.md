# Coordinated integration review

The main “Build BooksPresence tracker” task (01a0b198-8af7-74e1-b400-090758709933) explicitly accepted ownership of all SwiftUI integration. This concept task performs read-only source and visual review. The animation task retains motion ownership through shared components.

## Source reviewed

Main checkout: `/Users/abhinavnamboori/Documents/ChatGPT/Apple Books RPC`.

- `PopoverView` now uses the sea-glass design, enlarged serif book title, compact daily goal surface, distinct session/streak metrics, real reading state, and existing app actions.
- `MenuReadingGoal` preserves actual totals, clamps visual progress, omits the arc when no goal exists, includes manual time and uncertain-time notices, and exposes accessible progress text.
- `DottedReadingArc` now scales fixed dot diameters and row spacing for the smaller panel while preserving homepage dimensions.
- Shared `ReadingButtonStyle`, `ReadingPalette.onAccent`, and reduced-motion handling remain authoritative over the HTML approximation.
- Panel and native clipping agree on 22 pt corners. The body scrolls within a capped height while header/footer remain available.

Accepted visual differences from the concept: two-row compact arc, native button sizes, activity state within the book row, actual session time, and “Daily reading” copy. None changes the intended hierarchy or requires a user decision.

Flagged for main owner: the provisional-streak explanation should remain available when uncertain time and provisional streak coexist. `else if` currently favors the uncertain-time label. A separate help explanation or independent label can resolve this without extra visual clutter.

## Native render review completed

Reviewed `popover-light.png`, `popover-dark.png`, `popover-manual-light.png`, and `popover-setup-dark.png` in the main checkout's `.local/design-seaglass/` directory. Standard light/dark layouts visually match the homepage. Titles, compact double-dot arc, actual over-goal totals, manual time qualifier, and controls render without clipping in these standard previews.

The main owner confirmed provisional streak information now also appears independently in Goal streak help.

Two review findings were acknowledged by the integration owner:

- At a 500 pt panel height, setup actions are below the initial fold. Main owner is adding a visible scroll cue and will verify installed scrolling with the pinned footer.
- The manual fixture uses `startTracking: false`, leaving `ready` false. Calling `startManual` sets the manual book but its tick returns early, so the rendered snapshot remains “Session stopped.” It demonstrates Stop/manual-time controls only, not a coherent active-reading state. Main owner will not present it as active-capture validation.

The concept is now implemented in the main task's source and native renders. This task's handoff and visual/source review are complete. Final build, packaging, installed menu interaction, and live manual-session verification remain owned by the main task. These renders do not establish installed-app behavior, package readiness, or runtime performance.
