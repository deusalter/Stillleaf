# Dashboard refresh and app themes — design

Branch: `ui/dashboard-refresh` (from `origin/reader/mac`). Status: approved direction, awaiting spec review.

## Intent

Make the Stillleaf dashboard (sidebar, Today, Library, History, Timeline, Reviews, Settings) and the menu-bar popover feel modern and closer to the product website, and replace the single mint palette with a real theme system.

What the user asked for directly:

- Restyle toward Apple Books / Things 3 / Craft: clear hierarchy, generous spacing, bigger covers, fewer boxed cards, restrained motion.
- Match the website's styling.
- Fix History: the heading looks misplaced once the page is scrolled.
- Timeline: look more modern; remove "Edit rating" from the timeline; rating is changed by clicking the book.
- Six or more themes with light/dark variants, an accent-only override, a live picker in Settings, persisted in UserDefaults, applied app-wide including the popover; all screens use tokens; WCAG AA text contrast.
- Native Apple fonts (New York + SF Pro), not bundled website fonts.

Constraints: macOS 13 APIs only; light and dark mode everywhere; respect Reduce Motion; keep every existing action and accessibility label; do not touch `Reader/**`, `EPUBReaderWindow.swift`, `EPUBLibraryController.swift`, `EPUBImportStatusView.swift`, `Sources/**/Reader*.swift`, `EPUB*.swift`, `.github/workflows`; no tracking/storage/AppModel logic changes beyond what the UI needs.

Success: renders for every screen × theme × appearance look coherent; `scripts/check-local.sh` passes including a new contrast gate; UISmoke covers changed views; the problems below are visibly gone.

## Problems being fixed (from the current renders)

1. Everything is a filled box (panel inside panel inside tinted canvas), so nothing reads as primary.
2. Page headings are pinned outside the `ScrollView` (History, Timeline) with no background, so content scrolls under a floating title; header insets vary per screen.
3. Timeline rows are forms (dates / stars / rating buttons stacked) inside an over-wide bordered card with a competing rail.
4. Typography is three voices (SF Rounded titles, serif book titles, rounded numerals) and doesn't match the site's editorial serif + sans.
5. Light canvas, sidebar and surfaces are near-identical mints; accent, ochre and teal compete; `.secondary` is mixed with palette tokens; the palette is `static let` and can't be themed.

## Visual direction

**Canvas.** Near-white canvas (Stillleaf light `#F5F8F5`, as on the website); deep neutral in dark. The sidebar shares the canvas and is separated by a hairline, not a second tint.

**Type.** New York (`design: .serif`) for page titles (34pt), big numerals, year headings and book titles. SF Pro for everything else. Numbers use monospaced digits. Section labels are small uppercase SF, secondary ink, tracked.

**Page header.** One shared `PageHeader(title:subtitle:trailing:)` that lives *inside* each screen's `ScrollView`, so it scrolls away with the content. Every screen uses the same 40pt horizontal inset and a 1000pt max content width, centred.

**Surfaces.** At most one surface level. Sections are separated by whitespace and hairline dividers. Stat rows are plain number + label, not cards. A surface card is reserved for the one primary block on a screen (e.g. Today's goal).

**Accent discipline.** One accent per theme for progress, selection and primary buttons. The warning colour is reserved for warnings (the streak moves from ochre to the accent).

**Motion.** Keep `readingEntrance()` and existing hover fades. Every new animation is gated on `accessibilityReduceMotion`.

### Per screen

- **Sidebar:** leaf mark + "Stillleaf" in New York; plain rows with an accent-tinted selection pill; tracking status as a single quiet line at the bottom (no boxed card). Keyboard navigation, focus ring and identifiers unchanged.
- **Today:** goal ring and stats in the one surface card; "This week" and the reading year as open sections under hairlines; "Last read" with a larger cover.
- **Library:** segmented filter and search on one line; covers about 180pt wide with a soft shadow and no tile behind them; title in New York, author and status below; the overflow menu gets a larger hit target.
- **History:** stats as one quiet row; the calendar toolbar and scale picker on one line; calendar cells without fills (number only when empty, page count and an accent bar when read; today outlined); a readable legend. The Day view keeps sessions and books but drops the nested card.
- **Timeline:** grouped by year with a New York year heading and hairline. A row is date column (`Sep 24` / `Thu`), 72×108 cover, title, author, read-only stars. The whole row is a button with a hover highlight that opens `BookDetailView` (`.book` sheet). The "Edit reading dates" and "Rate / Edit rating" buttons leave the row. Undated entries keep their own section.
- **Book details:** rating is edited here (existing `BookRatingSection`). "Edit reading dates" moves into the hero next to "Finished <date>" for finished books, presenting the existing `ReadingDatesEditor`.
- **Reviews, Settings, Data health:** shared header and section primitives; settings groups become labelled sections with hairline rows instead of stacked cards.
- **Popover:** a single surface; book, ring and stats laid out side by side; setup notices as one inline row each; footer actions unchanged.

## Theme architecture (option A)

`Sources/BooksPresence/Theme.swift` (new):

```swift
struct ThemeColors { canvas, surface, elevated, ink, secondaryInk, accent, onAccent,
                     border, track, warning, chart: [UInt32] /* 3 */ }   // sRGB hex
struct ReadingTheme: Identifiable { id: String; name: String; light: ThemeColors; dark: ThemeColors }
struct AccentPreset: Identifiable { id: String; name: String; light: UInt32; dark: UInt32; onLight: UInt32; onDark: UInt32 }

@MainActor final class ThemeStore: ObservableObject {
    static let shared: ThemeStore
    @Published var themeID: String      // UserDefaults "appearanceTheme", default "stillleaf"
    @Published var accentID: String?    // UserDefaults "appearanceAccent", nil = theme default
    var theme: ReadingTheme
    func resolved(dark: Bool) -> ThemeColors   // theme variant with any accent override applied
}
```

`ReadingPalette` keeps its existing token names so call sites stay valid. Each token becomes a static dynamic `NSColor` whose provider reads `ThemeStore.shared.resolved(dark:)` at draw time. The legacy names map onto the new tokens:

| Legacy | New token |
| --- | --- |
| `paper` | canvas |
| `surface` | surface |
| `elevated`, `parchment` | elevated |
| `sidebar` | canvas |
| `ink` | ink |
| `fadedInk` | secondaryInk |
| `moss`, `accentEnd` | accent |
| `onAccent` | onAccent |
| `ochre` | warning |
| `border` | border |
| `progressTrack` | track |

New `chart(0...2)` tokens are added for History and the calendar legend.

The store is read on the main actor. The provider closure runs during drawing on the main thread, and a thread-safe snapshot (`ThemeStore.current`, updated on change) avoids actor hops.

**Redraw.** `DashboardView`, `PopoverView` and sheet roots observe `ThemeStore.shared` and apply `.id(store.renderKey)` so dynamic colours are re-resolved on change. The popover's `NSHostingView` gets the same observer via its root view.

**Themes.** Stillleaf (refined mint), Graphite (neutral grey, blue accent), Ocean (cool blue), Clay (warm sand, terracotta), Plum (muted violet), Forest (deep green, brass warning). Each has light and dark variants.

**Accent override.** "Theme default" plus 8 presets (Leaf, Teal, Blue, Indigo, Violet, Rose, Terracotta, Amber). Each has light/dark tones and an on-accent colour, all pre-checked for contrast against every theme's canvas and surface. A free colour wheel is out of scope because arbitrary colours can't guarantee AA.

**Picker.** Settings → Reading → a new "Appearance" section. It shows a grid of theme swatch cards (a mini canvas with an ink line, secondary line and accent pill, rendered in the current appearance), the selected card outlined in the accent, then a row of accent circles. Selection applies live and persists immediately. VoiceOver labels are "Theme: Ocean, selected" and "Accent: Rose".

**Hard-coded colours.** `.foregroundStyle(.secondary)` and literal `Color.*` in the dashboard/popover files are replaced by tokens. Opacity derivatives of tokens are allowed. Reader/EPUB files are untouched.

## Verification

- `scripts/theme-contrast-smoke.swift` (new, added to `check-local.sh`) compiles `Theme.swift` alone. For every theme × appearance × accent (including the default) it asserts WCAG contrast of at least 4.5:1 for ink and secondaryInk on canvas and surface, onAccent on accent, and warning on canvas, and at least 3:1 for accent on canvas and surface (UI components).
- `--render-ui <dir>` keeps its current output. `--render-ui <dir> --all-themes` additionally writes `<dir>/themes/<theme>/<screen>-<light|dark>.png` for the dashboard screens and the popover.
- UISmoke: update checks for the Timeline row (button that presents book details; no rating buttons), the header-in-scroll layout, and the Appearance picker (selecting a theme updates `ThemeStore` and UserDefaults). Existing accessibility identifiers are preserved.
- Build with `scripts/build-local.sh` and run `scripts/check-local.sh` before each push.

## Delivery order (small commits)

1. Theme model, store and `ReadingPalette` bridge, with the Stillleaf values tuned to today's look (no visual change), plus the contrast smoke.
2. Shared layout primitives: `PageHeader` inside the scroll, section label, hairline, content width.
3. Today and Library restyle. **Checkpoint:** send before/after renders and wait for the user's go-ahead.
4. History, Timeline (+ Book details dates), Reviews, Settings, Data health, sidebar, popover.
5. Appearance picker and the remaining themes.
6. `--all-themes` renders, UISmoke updates, final render pass.

## Out of scope

Bundled fonts, custom colour-wheel accents, changes to reader windows, and tracking or storage behaviour.
