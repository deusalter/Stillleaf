# Stillleaf menu-bar concept

Concept only; no application source files changed. Sample data, not a capture of the user's reading activity.

## Reference

The current homepage is the uncommitted sea-glass design in `/Users/abhinavnamboori/Documents/ChatGPT/Apple Books RPC`, confirmed with its owning task and `today-light.png` preview. This worktree initially contained an older rose/plum palette; the finished concept uses the newer homepage. The dropdown is `PopoverView` hosted by a borderless `StatusMenuPanel`, anchored below the macOS menu-bar icon.

## Layout and typography

350 pt width, 20 pt outer insets, 22 pt continuous outer corners. Header provides brand and a labeled Dashboard action. Current book follows with a 62 × 88 cover and 23 pt serif title. Supporting text is 11–12 pt system sans. Native implementation should use SF Rounded for goal numbers (34 pt), metric values (21 pt), and goal heading (15 pt). Browser fonts are an approximation.

One 18 pt-radius surface combines today's page count, dotted progress arc, goal, and credited time. The arc is a simplified miniature of the homepage's larger motif. Session pages and streak are separate below; amber streak color matches the homepage. Two switches remain visually quiet, then manual reading and Quit finish the panel. Dashboard, switches, manual reading, and Quit all map to existing actions. Mockup buttons only show preview feedback.

## Exact homepage tokens

| Token | Light | Dark |
|---|---|---|
| Paper | #DFECE7 | #132422 |
| Surface | #F0F7F3 | #1C302D |
| Ink | #183D33 | #E7F3EA |
| Accent | #087D65 | #70DAB2 |
| Secondary text | #526F64 | #ADC5B8 |
| Amber | #885A27 | #E4B779 |

## Behavior required for implementation

- Preserve the real snapshot phase: reading or paused with its reason. Keep inferred-activity wording; do not imply verified comprehension.
- No current book: show “Ready when you are” and the existing placeholder; retain today's metrics. Never label a previous book as actively reading.
- Manual session: primary action becomes “Stop manual reading.” Starting uses the existing sheet. Keep manual time labels when applicable.
- Accessibility or Discord setup needed: insert the existing actionable setup notice above the footer. Let panel height grow within screen limits; scroll the body if needed while keeping actions available.
- Discord switch controls preference only. It must not imply current publication. Preserve reader-open gating.
- Clamp arc fill to 100% while keeping actual page total. Show “Goal reached” at the target and the surplus beyond it. If no goal exists, show pages today without a progress fraction or arc fill.
- Preserve provisional/pending streak explanations through accessible help or a compact conditional label. Long titles wrap to two lines; full title remains accessible.
- Native switches, keyboard focus, accessible control names, and Escape/outside-click dismissal remain. No animation changes proposed; another task owns motion.

## Artifacts and review

`index.html` is a standalone preview with light/dark panels. `stillleaf-dropdown-concept.png` is its full-page export. Browser review checked hierarchy, colors, readable titles, and control placement. This is a visual proposal, not native integration or behavioral validation.
