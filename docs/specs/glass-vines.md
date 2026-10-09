# Glass + ASCII vines redesign

Status: design approved in mockups on 2026-10-04; this spec awaits review.
Mockups (open in a browser):

- [`design/glass-vines/garden-and-reader-themes.html`](../../design/glass-vines/garden-and-reader-themes.html): the chosen direction in every theme and reading mode. Its vine goal ring is superseded by the dotted ring; see below.
- [`design/glass-vines/goal-arc.html`](../../design/glass-vines/goal-arc.html): the goal-indicator options. The dotted ring was chosen.
- [`design/glass-vines/directions.html`](../../design/glass-vines/directions.html): the options considered.

## Goal

Give Stillleaf a distinctive identity: glass surfaces floating over animated ASCII vines, colourful in every theme, without costing legibility, battery or reading comfort.

Chosen directions:

- **Dashboard: Garden.** A faint field of drifting ASCII “pollen” fills the whole window, and vines grow up from the bottom behind glass sidebar, cards and controls.
- **Reader: R1 margin garden.** Vines grow only in the empty space around the page, in step with chapter progress. The page itself is always solid paper.

Not goals: changing navigation, data, tracking or the reader engine; adding new screens; gamification.

This supersedes two earlier rules. PRODUCT_SPEC asked for “restrained color”, and the native-macOS plan limited glass to chrome. Both are updated here: colour is welcome, glass is the content surface, and the legibility rules below take over their purpose.

## Design rules

1. **Never behind bare text.** ASCII may sit behind glass (which blurs it into a tint) or in empty space. Text drawn directly on the window, such as page headers, gets an avoid region with one cell of padding.
2. **Grow once, then breathe.** Vines grow for a few seconds when a window opens. Afterwards they only “breathe”: a slow brightness wave moves through them, and leaves cross-fade between two glyphs as it passes. Nothing pops in or out.
3. **Growth means something in the reader.** Margin vines grow with chapter progress and never on a timer. A new chapter starts with bare margins.
4. **The vines can be turned off.** Settings → Appearance → Garden offers **Animated / Still / Off**. Reduce Motion and Low Power Mode force Still. Reduce Transparency and Increased Contrast make glass opaque.
5. **Decorative only.** The ASCII layer is hidden from VoiceOver, never takes clicks or scroll events, and never changes layout.

## Visual language

**Layers, back to front:** window canvas → ASCII layer (pollen field, vines) → glass surfaces → content.

**Glass.** On macOS 26: `glassEffect` / `NSGlassEffectView`. On macOS 13–15: `NSVisualEffectView` (`.underWindowBackground` or `.popover`) with the theme tint at about 55%. When transparency is reduced or contrast increased, use the theme `surface` colour. Glass surfaces are the sidebar, cards and panels, header pills, sheets, the menu bar panel and the reader toolbar and footer. Corner radii come from `ReadingMetrics.Radius`.

**Type.** Unchanged: SF for UI, New York for book and editorial titles, and SF Mono for the ASCII layer and stable numerals.

**Glyphs.**

| Role | Glyphs |
|---|---|
| Stems | `│ ╱ ╲ ─`; second-generation tendrils add `~ ( )` |
| Leaves (side pairs) | `( )`, `{ }`, `6 9`, `@`, `o` |
| Leaf flutter | `(`↔`{`, `)`↔`}`, `6`↔`(`, `9`↔`)`, `@`↔`o` |
| Blooms | `✿ ❀ ✽ * ❁ ✻` |
| Spores | `· ∙ ° ˚` |
| Pollen field | `. · : ˙ ' \` ,` |

**Colour.** Every theme derives its vine palette from its accent, so all 12 variants (6 themes × light/dark) work without hand-picked palettes:

- stems: the accent, plus the accent mixed toward ink and toward the neutral chart colour
- leaves: the accent hue offset by 0, +16, −14, +30 and −28 degrees, with fixed lightness per appearance
- blooms: the theme’s warm chart colour, star gold, and two complementary hues

Graphite gets blue vines, Clay terracotta, Plum violet. The pollen field uses the accent at a maximum alpha of 0.24 (light) or 0.19 (dark).

## Vine engine

One algorithm, implemented twice: Swift for the dashboard, menu panel and sheets, and JavaScript for the reader shell. The mockup script is the reference implementation.

- **Grid.** Monospaced cells (13 pt type; the cell is the measured glyph width × 1.22 line height). Cells are addressed by column and row.
- **Tips.** A wandering tip keeps a heading with damped random drift, an optional bias direction and an optional curl. Each step moves exactly one cell along the dominant axis, so stems never leave gaps. The stem glyph comes from the true heading in points. A path follower walks a precomputed path (arc, line, card edge) with an optional sideways wobble.
- **Sprouting.** Each step may add a leaf beside the stem (about 24%) or a branch (about 6%, up to three generations, shorter life). A dying tip may open a bloom and release spores that drift upward.
- **Determinism.** Each window is seeded from its kind plus the calendar day, so the garden looks the same for a whole day and differs from day to day. Growth is replayable, so a new budget re-runs the same garden instantly. Existing cells stay, new ones fade in one after another, removed ones fade out.
- **Budgets and masks.** A scene stops growing at its cell budget (dashboard about 2,400 cells; reader margins about 1,500). Placement is refused inside avoid regions and outside allowed regions.
- **Animation.**

  | Effect | Behaviour |
  |---|---|
  | Cell fade-in | 0.7 s |
  | Growing tip | a soft dot gliding between cells |
  | Breathing | alpha × (0.84 + 0.16 · sin(0.9 t + phase + 0.11x − 0.17y)) |
  | Leaf flutter | cross-fades when the wave crosses 0.88 |
  | Bloom | brightens briefly as it opens |

- **Frame pacing.** Growth runs at the display rate, capped at 60 fps. Breathing runs at 20 fps. Animation stops entirely when the window is hidden, occluded or minimised, or when Still/Off is selected.

## Dashboard: Garden

- **Every dashboard screen** gets the Garden background: the pollen field plus vines rising from the bottom edge (about nine roots, plus one each from the top-right and left edges). Avoid regions cover page headers and any other text drawn straight on the canvas.
- **Content containers become glass:** cards, `readingPanel()`, `AtlasPanel` and the sidebar. Charts and calendars keep their crisp rendering on glass panels.
- **Progress readouts stay data, not foliage.** The daily-goal indicator keeps today’s dotted ring unchanged: two rows of dots along a 260° arc with a smooth leading edge (`ReadingProgress.swift`). Its precise geometry contrasts with the organic garden, and that contrast is the point. The dashboard’s other progress readouts match it so they read as one family:
  - the book progress bar on Today and on Library cards becomes a row of dots with the same smooth leading edge
  - the menu bar panel’s goal indicator uses the same dots
- **Today.** Glass cards over the garden. The goal card keeps the dotted ring, and Last read uses the dotted progress row.
- **Library.** The grid sits on the garden, cards are glass, and progress uses the dotted row.
- **Menu bar panel.** A small piece of the dashboard, floating over the desktop.
  - *Shell:* clear glass, not frosted material. The theme canvas is laid thinly over the desktop (34% light, 40% dark) with a faint accent wash, a soft top highlight and a crisp rim. Before macOS 26 a light system blur is mixed in at 35%. Reduce Transparency and Increased Contrast make it the opaque canvas.
  - *Card:* the header, the book row, the goal ring, the streak and session block, and the actions share one glass card (`glassSurface`), grouped by spacing, so no text is ever drawn on the shell or the vines. Over the desktop the card is denser than on the dashboard (80% light, 92% dark) and blurs what is behind it, so text holds on any wallpaper. `PanelGlass` holds these numbers and `scripts/theme-contrast-smoke.swift` checks every theme against black, white, mid-grey and saturated desktops at WCAG AA.
  - *Garden:* a trellis along the top and bottom edges with four corner vines, and a vine up each side (`MenuPanelGarden`). Vines grow only in the gutters around the card and show softly blurred where the card overlaps them. It follows Animated, Still and Off like every garden. Growth, breathing and redraws stop while the panel is hidden.
  - Goal progress keeps the dotted ring.
- **Empty states.** A hand-drawn seedling (stem, leaves, bloom) is revealed in growth order, holds, then regrows.
- **Finishing a book.** About 12 vines burst outward from the completion badge with alternating curl, flower and release spores.
- **Onboarding.** The garden grows a little more with each step, so the final step shows it complete. This replaces the current 30 fps backdrop.

## Reader: R1 margin garden

The garden lives in the window space outside the page. The page’s own inset (`--page-inset`, `pageGutter`) belongs to the page and never holds vines.

| Mode | Vines |
|---|---|
| Single page | Full garden in both outer margins. |
| Facing pages | Narrower garden in the outer margins, plus a **spine vine** climbing the column gap. It is the chapter progress. |
| Facing, small window | Margins under the minimum stay empty; the spine and footer vines remain. |
| Continuous scroll | Single-page layout; the garden stays fixed while the text moves. |
| Fullscreen | Same rules; wider margins simply hold more garden. |

- **Minimum margin:** 7 cells (about 56 pt). A narrower margin stays empty rather than holding a cramped vine.
- **Spine vine.** The column gap is twice `pageGutter`: 88 pt at Normal, 48 pt at Narrow, 144 pt at Wide. The spine vine is confined to the gap minus one cell on each side. Facing pages render as one iframe on one paper background, so the spine draws on a thin overlay above the iframe, limited to the gap. The margin garden draws on a canvas behind the reading viewport.
- **The page is a card on a backdrop.** While the garden is on and there are at least 16 px of window on both sides of the page, the reading viewport is drawn as a raised card (paper colour, 10 px radius, soft shadow) on a backdrop derived from the theme: the paper pulled 7% toward the ink in light themes, 42% toward black in dark ones (Night and Midnight, which are already near black, are lifted slightly toward the ink instead). The card is a pseudo-element of the viewport, grown by `--card-y` (the page inset minus 12 px) above and below, so text, pagination, annotations, search highlights and page-slide snapshots keep their geometry. Facing pages are one card with a soft fold in the gap; continuous scroll is a card column. Below that room, or with Vines Off, the page is edge to edge on the plain paper as before.
- **Density.** Margin vines use the mockup's seeds and tip specs (life 56, 50 tips). A chapter starts at about the mockup's 18% (270 cells, or 40% of a small garden) and fills out to the full garden by its last page; growth is deterministic, so a smaller budget is exactly the start of a larger one. Vines keep two cells from the card and one from bars and the footer pill.
- **Palette and depth.** Stems, leaves and blooms come from the theme accent as in the mockup (greens and teals around the accent hue; a warm bloom plus two hues across the wheel), nudged to 3:1 on the backdrop. Branches recede (generation 1 at 82%, deeper at 60% opacity), every cell carries a fixed shimmer, and blooms are 25% fainter on dark pages.
- **Footer progress.** The footer is a pill the width of the card, holding "Page X of Y", a thin vine growing along a dotted track to the chapter progress, the pages left, and the percentage. The pill and its vine exist while the garden does and follow Focus reading: the footer, and so the vine, is hidden and regrown when it returns. The spine vine in facing pages carries the same progress, with its own dotted track.
- **Adjustable margins.** The existing controls (Margins presets, Side margins, Page width) define where the garden can grow. Changing any of them re-runs the garden for the new geometry: vines in lost space fade out, new space fills in. The Vines setting (**Off / Margins**, default Margins) sits next to those sliders in the Appearance panel.

### Living garden (reader margins)

An Animated margin garden keeps moving once it has grown in, as in the "Living garden" direction of `design/dynamic-motion`. Still, Off and Reduce Motion show none of it.

- **Shoots.** A new shoot grows off an existing stem every 30 to 60 s (the first after about 3 s), one cell every 1.5 s, up to three at once. They sit beside the reading-driven garden and never replace it: margins still fill with reading progress, and live shoots are only an extra layer of about 120 cells.
- **Recycling.** Past that budget the oldest settled shoot withers from its tip back to its stem over about 20 s and lets go of a few spores, so the density stays the same all day. A live cell yields at once if the settled garden grows over it, and a shoot whose stem is gone withers.
- **Wind.** Slow bands cross the margins about every 10 s. Leaves lean and flutter to their alternate glyph, blooms nudge, stems stay put.
- **Petals and fireflies.** A bloom sheds a petal about every 18 s (at most three in the air). In dark themes four fireflies, two in each margin, blink on 3 to 6 s cycles. Particles fade out in the two cells around the page card and the bars, so nothing moves beside the text.
- **Cost.** The model (`src/living.js`) is pure state. The loop in `garden.js` runs at most 15 frames a second and only after the garden has settled. A frame repaints only the cells whose wind pose or opacity changed and the places particles were and are now, through a clip of whole-pixel rectangles; it never redraws the whole canvas. Measured in headless Chromium and WebKit: about 1 ms per frame, under 1% of the canvas repainted per frame.
- **Pausing.** The loop stops while scrolling or turning a page (the same hold that freezes the garden), while `document.hidden`, and in Still, Off and Reduce Motion. Its clock ignores gaps over 100 ms, so a hidden window never catches up in a burst. Switching to Still or Off clears shoots and particles.
- **Testing.** `test/living.test.mjs` runs the model headless (growth, recycling, wind, petals, fireflies, long gaps). `test/garden-living.test.mjs` runs the garden in Chromium and WebKit: frame cap, frame cost, dirty area, pausing and each mode. Set `window.__stillleafGardenPace` (with `__stillleafGardenDebug`) to compress every interval, like the mockup's Fast preview.

### Scrolling and input

The garden must never interfere with reading.

- The garden canvas and the spine overlay use `pointer-events: none`. They take no clicks, wheel or trackpad events, text selection or focus. They have no layout effect: no element size or position depends on them.
- Wheel and trackpad input over the margins keeps doing what it does today. In continuous mode it scrolls the book, and in paginated mode the existing page-turn gesture handling is unchanged.
- During active scrolling the garden freezes in place. It resumes 300 ms after the last scroll event, so scrolling keeps the compositor to itself.
- Progress-driven growth during scrolling is applied only when scrolling stops, as one regrow step. The garden never grows or reflows mid-scroll.
- The garden is a fixed layer. It does not scroll with the text, and the text column clips at its own edges, so text never passes under a vine.

## Native architecture

New files under `Sources/BooksPresence/Vines/`:

| File | Responsibility |
|---|---|
| `VineField.swift` | Pure model: grid, tips, growth step, masks, budgets, seeded RNG. No SwiftUI, so it can be unit tested. |
| `VinePalette.swift` | Derives the vine palette from `ThemeColors`. |
| `VineCanvas.swift` | SwiftUI `Canvas` + `TimelineView` renderer. Glyphs are pre-resolved once per character and palette slot, then drawn with per-cell opacity. Frame pacing and pausing follow the engine rules. |
| `GardenBackground.swift` | Pollen field + vines for a window. Collects avoid regions from a `.vineAvoid()` modifier (anchor preference). |
| `VineSeedling.swift`, `VineBurst.swift` | Path-follower components for empty states and the completion burst. |
| `DottedProgress.swift` | The dotted progress row, sharing dot size, spacing and smooth leading edge with the existing ring. |
| `GlassSurface.swift` | One modifier choosing glass, vibrancy or opaque surface as described above. Replaces the ad hoc glass in `ReadingButtonStyle` and `NativeChrome`. |

`build-local.sh` gains the `Vines/` folder.

Reader: `Reader/desktop/reader/src/vines.js` ports the engine, and `garden.js` owns geometry: it reads `readingMargins()` and `effectiveColumns()`, the viewport rect, scroll state and chapter progress. Both are bundled by `build-reader-assets.sh`. The native app passes the theme accent and the Garden setting through the existing preferences bridge.

## Testing

- **Engine unit tests** (BooksPresence test target, or a smoke in `check-local.sh`):
  - the same seed gives the same cells
  - no cell lands in an avoid region
  - growth under a larger budget starts with the cells of the smaller one
  - stepping never leaves gaps
- **Palette:** `theme-contrast-smoke` checks every vine colour against canvas and paper in all 12 variants (target 3:1 for decorative glyphs). Glass text keeps the existing 4.5:1 check.
- **Renders:** `--render-ui` gains `--vine-time <seconds>` so offscreen renders are deterministic. Before/after review uses the same pixel-diff approach as the structure work.
- **Reader** (Chrome and WebKit Playwright):
  - in every mode, no vine cell intersects the page or column rects
  - wheel events over the margins still scroll in continuous mode
  - the garden freezes during scroll
  - changing margins or page width regrows without layout shift
- **Performance:** measure dashboard idle CPU after growth with the existing native benchmark harness. Target under 2% on Apple silicon at 20 fps breathing, and 0% when hidden or set to Still.

## Delivery phases

Each phase is one PR, on top of the structure work in #16 and #17.

1. Engine, palette, `GlassSurface`, Garden background on Today, the dotted progress row, and the Garden setting.
2. The other dashboard screens, menu bar panel and sheets.
3. Reader margin garden: every mode, the spine vine, the scrolling rules and live response to margin changes.
4. Onboarding, empty states and the completion burst.

## Risks

- **Older Macs.** Glyph drawing cost on Intel Macs: pre-resolved glyphs and the 20 fps breathing cap are the mitigations, and Still is the fallback.
- **Glass before macOS 26.** It looks flatter on macOS 13–15. Vibrancy plus tint is the accepted approximation.
- **Busy History screen.** Charts sit on glass panels. If the field competes, History lowers the pollen alpha by half.
