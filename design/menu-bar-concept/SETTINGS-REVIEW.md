# Settings and diagnostics usability review

Main task owns implementation and installation. This task reviews source and native previews without editing shared SwiftUI files.

## Findings from current native screens

Reviewed `.local/design-seaglass-final/settings-{reading,discord,data}-light.png`, `health-light.png`, and `ControlsView.swift` in the main checkout.

- Data health has equal sidebar prominence to reading activities, even with no issues. Most content duplicates status/permission information already elsewhere.
- Reading settings place tracking, startup, history sync and sync status before the daily page goal. Advanced timing/time-zone controls extend the page; Apply is below the initial viewport.
- Two sets of five goal presets, number fields, steppers and repeated range instructions compete for attention.
- Discord exposes technical setup and artwork fields while sharing is off, together with a persistent Apply/Revert bar even without edits.
- Data gives removal actions substantial default prominence alongside routine export/backup actions.
- Toggles save immediately; fields are staged. Existing Revert resets both Reading and Discord drafts, creating a cross-category loss risk.

## Agreed structure with integration owner

Keep the homepage's visual direction. Keep three compact Settings categories and a sticky category header. Remove Health from the main reading sidebar. Retain diagnostics in a clearly dismissible Troubleshooting sheet under Data & privacy, with contextual access from actionable failures.

Bring daily page goal and startup forward. Move optional time goal, uncertainty threshold and time zone into Advanced reading; show the active time-zone summary without expansion. Reduce duplicate presets/range prose. Show Apply/Revert only when fields are dirty, with saving accessible while scrolling and category-specific reset.

Discord defaults to sharing/status; setup expands when needed and collapses after configuration. Keep public-cover network/privacy explanation next to its opt-in. Data retains export/import/backup and explains merge versus replacement; removal stays accessible in a separate disclosure with existing confirmation behavior.

## Review checks

- Goal and common app preferences visible in the initial Reading viewport.
- No Data health primary navigation item; Troubleshooting remains discoverable and has Done/close.
- Advanced disclosure reveals all existing controls, including time zone and review threshold.
- Dirty state and reset/apply scope do not discard another category's unsaved fields.
- Missing Discord Application ID produces visible setup guidance when sharing is enabled.
- Compact window retains readable labels, reachable controls, and sticky save actions.
- Destructive actions and diagnostics remain available, with no data deletion performed by this redesign.

## Revised default previews reviewed

Reviewed Reading, Sharing, Data & privacy, and compact dropdown in the main checkout's `.local/design-settings-refined/` renders. The initial viewport now puts the page goal first, advanced controls behind a disclosure with time-zone summary, and Discord technical details behind setup. Data health and persistent sharing controls are absent from the primary sidebar. Troubleshooting is discoverable in Data & privacy; removal is collapsed. Default-state visual hierarchy passes review.

Source confirms category-specific Revert, sticky dirty save actions, and missing-ID auto-expansion. Review also flagged whitespace normalization after saving Discord fields so a successful save does not leave the form falsely dirty; main owner accepted that fix.

Remaining implementation-owner verification: expanded/dirty controls, unconfigured Sharing, Troubleshooting sheet interactions, and installation. Native Export menu styling remains a minor visual inconsistency.

## Additional dropdown refinement

The user liked the arc but found other text too large and switches misplaced. Revised native popup preserves the arc, reduces empty-state title, hides zero-valued idle session metrics, removes preferences, and retains explicit Settings navigation, compact manual action and quiet Quit overflow. Idle native render passes visual review. Live active-book/manual-state behavior remains the main task's responsibility.
