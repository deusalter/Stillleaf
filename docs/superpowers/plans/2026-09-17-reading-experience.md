# Reading Experience Implementation Plan

> **For agentic workers:** Use subagent-driven development with disjoint ownership and independent review.

**Goal:** Replace the long history grid and washed-out controls with a focused, animated native reading calendar and approachable settings.

**Architecture:** Calendar navigation is presentation state over existing persisted history. Calendar math uses the selected timezone and Gregorian calendar boundaries. Shared appearance-aware tokens unify sidebar, panels, charts and settings; no history migration is needed.

**Tech Stack:** Swift 5.8, SwiftUI and AppKit, macOS 13+, existing SQLite core, no new dependencies.

**Spec:** User's September 17 UI feedback and screenshot; existing docs/PRODUCT_SPEC.md remains binding for trustworthy history.

## Design

Color tokens (revised after user feedback): light canvas #E6DADF, light surface #F0E7EB, dark canvas #241C26, dark surface #302532, copper accent #E0AE96, restrained olive #C9CE89. Text uses deep plum in light mode and soft rose-white in dark mode. No translucent-white panels. SF Pro provides readable controls; New York serif is reserved for the page title and book titles. Calendar marks use compact rectangles; year views use numbered cells, never circles.

The calendar is the primary surface. Compact period statistics sit above the date grid; a Day/Week/Month/Year control and previous/next arrows keep orientation. Month opens by default with real weekday alignment. Selecting a date opens its day, selecting a mini-month in Year opens Month, and Week presents seven day columns with reading distribution. Day lists books, duration and contributing sessions. Return controls retain a meaningful anchor date.

Settings use a category rail and titled rows with descriptions, native switches and clear editable values. Tracking and sharing stay independent. Sensitive data actions are grouped separately and keep their existing confirmations.

Self-critique: the existing oversized cards bury the primary activity. This design reduces their height and uses an actual calendar structure, rather than another generic dashboard card collection. Motion responds to navigation only, with reduced motion respected.

## Global constraints

- Keep the macOS 13 deployment target and direct compiler build.
- Never mutate reading records to navigate the calendar.
- Honor configured timezone, calendar midnight, DST, goals, uncertainty and merge semantics.
- Use real native controls, accessible labels, and reduced-motion support.
- Root owns Git, integration, AppViews.swift, TodayView.swift and UISmoke.swift.
- Calendar worker owns HistoryView.swift plus a new CalendarNavigation.swift and its tests.
- Settings worker owns ControlsView.swift only.
- User explicitly authorized rewriting existing history and selected the start of summer. Use June 1, 2026 onward, retain a local recovery reference, preserve all trees/messages/identities, and use a lease against the known remote head when updating it.

## Task 1: Calendar navigation and drill-down

- [x] Add a pure calendar navigation model with month grid, seven-day week, twelve-month year, day selection and period shifts. Example: `calendar.date(byAdding: .month, value: offset, to: monthStart)` rather than adding a fixed number of seconds.
- [x] Default History to current month; supply previous/next, Today, zoom picker and clear period title.
- [x] Drill from year to month, month/week to day. Show day contributions by book and reviewable sessions.
- [x] Animate date/scale changes with a brief spring/fade, disabled by `accessibilityReduceMotion`.
- [x] Add meaningful leap-year, weekday alignment, timezone, DST and selection-preservation tests.

## Task 2: Appearance and navigation shell

- [x] Replace hard-coded panel white with `ReadingPalette.surface`; keep existing palette aliases for compatibility.
- [x] Create a compact sidebar with active navigation, review count, status and native switches.
- [x] Restyle popover controls, page headings and Today summaries to use the same visual hierarchy.
- [x] Verify light/dark appearance and minimum window width; preserve keyboard controls and focus.

## Task 3: Settings workflow

- [x] Split Reading, Discord and Data settings into approachable groups with category navigation.
- [x] Give tracking/login/sharing native switches and immediate saved behavior, while text fields have explicit apply feedback.
- [x] Provide goal presets, bounded numeric editing and a timezone selection control instead of an unexplained raw text field.
- [x] Preserve all import/export/backup/restore, permission, delete and uninstall actions.

## Task 4: Integration and verification

- [x] Extend native self-check to cover all four calendar scales, settings and both color schemes with synthetic data.
- [x] Build using `scripts/check-local.sh`; independently review calendar semantics, state binding and UI interactions.
- [x] Inspect rendered native views/screenshots where available. Record exact limitations if computer use remains unavailable.
- [ ] Package app, verify extracted app and signature, commit/push under the clarified date policy, and check current-head macOS CI.

## Execution ledger

Initial state: clean main at a3a3686; work isolated on codex/reading-experience. The screenshot is visual feedback only. No instructions are taken from image contents.

Revision ledger: implemented and independently reviewed all three UI tasks. User replaced the blue palette with plum/copper and requested rectangular calendar markers. Local calendar/storage/Discord harnesses and 22 native view-layout configurations passed. App-owned synthetic renders were inspected; live computer-use click-through remains unavailable. Calendar regressions include the same-timezone assignment made by each navigation action. Packaging and remote CI are the final integration step.
