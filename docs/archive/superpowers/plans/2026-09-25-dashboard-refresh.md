# Dashboard Refresh and App Themes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the Stillleaf dashboard and popover toward the website's calm editorial look, and replace the fixed mint palette with six switchable, contrast-checked themes plus accent presets.

**Architecture:** `Theme.swift` holds pure-Foundation theme data and WCAG maths. `ThemeStore.swift` persists the selection and publishes a revision number. `ReadingPalette` tokens become computed dynamic `NSColor`s that are rebuilt per revision. Views re-render by re-keying render-only subtrees with `.id(revision)`, never a view that owns draft `@State`. Shared layout primitives (`PageHeader`, `ReadingSection`, `Hairline`, `.readingPage()`) give every screen the same header-inside-scroll layout.

**Tech Stack:** Swift 5.8, SwiftUI + AppKit, macOS 13 APIs, no third-party dependencies, direct `swiftc` build (`scripts/build-local.sh`).

**Spec:** `docs/superpowers/specs/2026-09-25-dashboard-refresh-design.md`

## Global Constraints

- macOS 13 APIs only; Swift 5.8; no new dependencies; no bundled fonts (New York via `design: .serif`, SF Pro via system font).
- Light and dark for everything; respect `accessibilityReduceMotion`; keep every existing action, accessibility label and `accessibilityIdentifier`.
- Hands off: `Reader/**`, `EPUBReaderWindow.swift`, `EPUBLibraryController.swift`, `EPUBImportStatusView.swift`, `Sources/**/Reader*.swift`, `EPUB*.swift`, `.github/workflows`. No tracking/storage/AppModel logic changes.
- Text contrast ≥ 4.5:1 and UI/graphic contrast ≥ 3:1 for every theme × appearance × accent.
- UserDefaults keys: `appearanceTheme` (default `"stillleaf"`), `appearanceAccent` (absent = theme default).
- Push only to `origin/ui/dashboard-refresh`; no PR.

## Review Focus

1. Changing theme while Settings has unsaved goal drafts must keep the drafts. SettingsView state is never re-keyed; UISmoke asserts the category survives a theme change.
2. An unknown or removed theme/accent id in UserDefaults must fall back to Stillleaf / theme default without crashing. UISmoke writes `"bogus"` and checks the fallback.
3. The popover (a separate `NSHostingController`) must follow the theme. `PopoverView` observes the store, and UISmoke lays out the popover after switching.
4. Timeline rows with no finish date, no author or no cover must still open Book details and read well. The row keeps the undated branch, and UISmoke lays out the timeline with an undated entry already seeded by the date-clearing check.
5. Keyboard and VoiceOver users must still reach rating and date editing. The timeline row is a focusable `Button` with label and hint, and Book details holds "Edit reading dates".

## File Map

| File | Responsibility |
| --- | --- |
| `Sources/BooksPresence/Theme.swift` (new) | `ThemeColors`, `ReadingTheme`, `AccentPreset`, catalogue, `ThemeContrast` WCAG checks. Foundation only. |
| `Sources/BooksPresence/ThemeStore.swift` (new) | `ThemeStore` (persist, publish `revision`), per-revision colour cache, `ReadingPalette` bridge. |
| `Sources/BooksPresence/ReadingLayout.swift` (new) | `PageHeader`, `ReadingSection`, `Hairline`, `.readingPage()`, `StatLine`. |
| `Sources/BooksPresence/AppearancePicker.swift` (new) | Theme swatch grid + accent row. |
| `scripts/theme-contrast-smoke.swift` (new) | Standalone contrast gate compiled with `Theme.swift`. |
| `scripts/check-local.sh` | Run the contrast smoke. |
| `AppViews.swift` | Remove old `ReadingPalette`; sidebar, popover and dashboard restyle; theme re-keying. |
| `TodayView.swift`, `LibraryView.swift`, `HistoryView.swift`, `FinishedBookView.swift`, `PersonalReviewsView.swift`, `ControlsView.swift`, `ReadingProgress.swift`, `ReadingGoalsView.swift`, `ReadingButtonStyle.swift`, `ReadingControls.swift`, other dashboard files | Tokens and layout. |
| `UIRender.swift` | `--all-themes`. |
| `UISmoke.swift` | Theme, timeline and picker checks. |

---

### Task 1: Theme model, store, palette bridge, contrast gate (no visual change)

**Files:** Create `Theme.swift`, `ThemeStore.swift`, `scripts/theme-contrast-smoke.swift`. Modify `AppViews.swift:438-460` (delete the old `enum ReadingPalette`) and `scripts/check-local.sh`.

**Interfaces — Produces:**
- `struct ThemeColors { canvas, surface, elevated, ink, secondaryInk, accent, onAccent, border, track, warning: UInt32; chart: [UInt32] }`
- `struct ReadingTheme: Identifiable { id, name: String; light, dark: ThemeColors; static let all: [ReadingTheme]; static func named(_ id: String?) -> ReadingTheme }`
- `struct AccentPreset: Identifiable { id, name; light, dark, onLight, onDark: UInt32; static let all; static func named(_:) -> AccentPreset? }`
- `ReadingTheme.colors(dark: Bool, accent: AccentPreset?) -> ThemeColors`
- `enum ThemeContrast { static func ratio(_ a: UInt32, _ b: UInt32) -> Double; static func failures() -> [String] }`
- `@MainActor final class ThemeStore: ObservableObject { static let shared; @Published private(set) var revision: Int; var themeID: String; var accentID: String?; func select(theme: String); func select(accent: String?); func reload(from: UserDefaults) }`
- `ReadingPalette` static vars: `canvas, paper, sidebar, surface, elevated, parchment, ink, secondaryInk, fadedInk, accent, moss, accentEnd, onAccent, warning, ochre, border, progressTrack; static func chart(_ i: Int) -> Color`

- [ ] **Step 1: Write the failing contrast smoke.** Create `scripts/theme-contrast-smoke.swift`:

```swift
import Foundation

@main
struct ThemeContrastSmoke {
    static func main() {
        guard ReadingTheme.all.count >= 6, ReadingTheme.named("bogus").id == "stillleaf",
              AccentPreset.named("bogus") == nil else {
            print("theme-contrast-smoke: catalogue or fallback failed"); exit(1)
        }
        guard abs(ThemeContrast.ratio(0x000000, 0xFFFFFF) - 21) < 0.01 else {
            print("theme-contrast-smoke: WCAG ratio maths wrong"); exit(1)
        }
        let failures = ThemeContrast.failures()
        failures.forEach { print("theme-contrast-smoke: FAIL \($0)") }
        guard failures.isEmpty else { exit(1) }
        print("theme-contrast-smoke: \(ReadingTheme.all.count) themes × 2 appearances × \(AccentPreset.all.count + 1) accents pass WCAG AA")
    }
}
```

- [ ] **Step 2: Run it; it fails to compile** (`ReadingTheme` undefined).

Run:

```bash
xcrun swiftc -parse-as-library -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$(uname -m)-apple-macosx13.0" Sources/BooksPresence/Theme.swift \
  scripts/theme-contrast-smoke.swift -o .build/local/theme-contrast-smoke
```

Expected: error, no such file / cannot find type.

- [ ] **Step 3: Implement `Theme.swift`.** Add the structs above, plus WCAG relative luminance: `c/255`, then `≤0.03928 ? c/12.92 : ((c+0.055)/1.055)^2.4`, then `L = 0.2126R + 0.7152G + 0.0722B`, `ratio = (L1+0.05)/(L2+0.05)`.

  `failures()` iterates every theme × {light, dark} × {nil + every accent} and checks:
  - ink on canvas and surface ≥ 4.5
  - secondaryInk on canvas and surface ≥ 4.5
  - onAccent on accent ≥ 4.5
  - warning on canvas ≥ 4.5
  - accent on canvas and surface ≥ 3
  - each chart colour on surface ≥ 3

  The catalogue:
  - **Stillleaf light** matches today's app exactly. canvas `DFECE7`, surface `F0F7F3`, elevated `D1E6DD`, ink `183D33`, secondaryInk `526F64`, accent `087D65`, onAccent `FFFFFF`, border `B5CFC2`, track `C7DED3`, warning `885A27`, chart `[087D65, 885A27, 7C948A]`.
  - **Stillleaf dark:** `132422`, `1C302D`, `28423B`, `E7F3EA`, `ADC5B8`, `70DAB2`, `10392B`, `39544A`, `304B40`, `E4B779`, chart `[70DAB2, E4B779, 7F978C]`.
  - Graphite, Ocean, Clay, Plum, Forest and the eight accents (Leaf, Teal, Blue, Indigo, Violet, Rose, Terracotta, Amber) use the values tuned in Task 5. Task 1 ships them too, and they must pass the gate.

- [ ] **Step 4: Implement `ThemeStore.swift`.**
  - `ThemeStore` reads and writes the two keys and bumps `revision`.
  - A lock-protected `static var resolvedCache: (revision: Int, light: ThemeColors, dark: ThemeColors)` is read by the `NSColor(name:dynamicProvider:)` closures, which can run off the main thread.
  - `ReadingPalette` tokens are `static var` computed from a per-revision `[KeyPath: Color]` cache, so each revision gets new `Color` instances. Legacy names alias the new tokens (see the spec table).

- [ ] **Step 5: Delete the old `enum ReadingPalette` in `AppViews.swift`.** Add the smoke to `check-local.sh` before the suites loop:

```bash
"$SWIFTC" -parse-as-library -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx13.0" Sources/BooksPresence/Theme.swift scripts/theme-contrast-smoke.swift -o "$OUT/theme-contrast-smoke"
"$OUT/theme-contrast-smoke"
```

- [ ] **Step 6: Run the smoke, then `scripts/build-local.sh` and `--render-ui`.** Expected: the smoke passes. Stillleaf renders are pixel-identical to `scratchpad/before` (compare with `cmp` on `today-light.png`, `library-dark.png`).
- [ ] **Step 7: Commit** "Introduce theme model, store and contrast gate behind the existing palette".

### Task 2: Shared layout primitives and header-inside-scroll

**Files:** Create `ReadingLayout.swift`. Modify `TodayView.swift:289-306` (replace `PageHeading` and `readingPanel()` implementations while keeping the names as thin wrappers for untouched sheets).

**Interfaces — Produces:**

```swift
struct PageHeader<Trailing: View>: View { init(_ title: String, subtitle: String?, @ViewBuilder trailing: () -> Trailing) }
extension PageHeader where Trailing == EmptyView { init(_ title: String, subtitle: String?) }
struct ReadingSection<Content: View, Accessory: View>: View { init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) }
struct Hairline: View   // 1px ReadingPalette.border
struct StatLine: View { init(value: String, label: String) }  // New York 26pt numeral + small label
extension View { func readingPage(maxWidth: CGFloat = 1000) -> some View }   // 40pt h-inset, 34pt top, centred
enum ReadingType { static let pageTitle, sectionLabel, bookTitle(size:), numeral(size:) }
```

`PageHeader` title is `.system(size: 34, weight: .regular, design: .serif)`, with the subtitle in `.callout` secondaryInk. `ReadingSection` shows an uppercase 11pt tracked label plus accessory on one line, then a `Hairline`, then the content.

- [ ] **Step 1:** Implement `ReadingLayout.swift` exactly as above; `PageHeading` forwards to `PageHeader`; `readingPanel()` becomes surface + 16pt continuous radius.
- [ ] **Step 2:** Build. Expected: success.
- [ ] **Step 3:** Commit "Add shared page header, section and stat primitives".

### Task 3: Today + Library restyle, theme redraw wiring → CHECKPOINT

**Files:** `AppViews.swift` (DashboardView, DashboardSidebar, `.id(revision)` keying), `TodayView.swift`, `ReadingProgress.swift` (DailyReadingOverview colours only), `ReadingGoalsView.swift`, `LibraryView.swift` (LibraryView body + BookLibraryCard), `BookCoverView` sizes.

- [ ] **Step 1: Redraw wiring.**
  - `DashboardView` gets `@ObservedObject private var theme = ThemeStore.shared`.
  - The sidebar gets `.id(theme.revision)`.
  - The detail `Group` keeps `.id(section)` for `.settings` and uses `.id("\(section.rawValue)-\(theme.revision)")` for the others.
  - `SettingsView` observes the store and applies `.id(theme.revision)` to its inner content `VStack` only, so its draft `@State` survives.
  - `PopoverView` observes the store and applies `.id(theme.revision)` to its root `VStack`.
- [ ] **Step 1b: Refine Stillleaf toward the website.**
  - Light: canvas `F5F8F5`, surface `E9F1ED`, elevated `DCE9E2`, ink `183D33`, secondaryInk `4B6A5E`, accent `176650`, border `D0DED6`, track `D5E4DC`, warning `8A5A1F`.
  - Dark: canvas `111A18`, surface `18251F`, elevated `22332D`, ink `E6F1EB`, secondaryInk `A3BAAF`, accent `6FD4AE`, onAccent `0E2E23`, border `2A3B35`, track `24352F`, warning `E2B574`.
  - Re-run the contrast smoke.
- [ ] **Step 2: Sidebar.**
  - Canvas background with a trailing `Hairline` (vertical).
  - Wordmark "Stillleaf" in New York 20pt with the leaf glyph in the accent. The tagline stays.
  - Rows are 13pt; the selected row gets `accent.opacity(0.12)` fill and ink text, the others secondaryInk. Rows are 8pt vertical padding.
  - Tracking status becomes a single 11pt line with a dot at the bottom, with no boxed card.
  - Keep `focusable`, `onMoveCommand`, labels and identifiers.
- [ ] **Step 3: Today.**
  - Layout: `ScrollView { VStack(spacing: 36) { PageHeader("Today", subtitle: <weekday, month day>) { tracking capsule }; DailyReadingOverview (the one surface card); ReadingSection("This year") { AnnualReadingGoalView content, no card }; ReadingSection("Last read" / "Your current read", accessory: Book details button) { cover .hero (140×210), New York 28pt title … }; FinishedBookPrompt; journal actions row } .readingPage() }`.
  - Streak colour becomes the accent.
- [ ] **Step 4: Library.**
  - The header trailing holds the Import/Add buttons.
  - One control row: segmented shelf (fixed width 360), a flexible spacer, search (240) and the sort menu (plain, no surface).
  - Grid is adaptive 168–210, spacing 28/36.
  - `BookLibraryCard` has no tile. The cover is `.shelfLarge` (168×252) with `shadow(black 0.18, r 10, y 6)` and a 3% hover lift (none under Reduce Motion), plus a hover surface behind the text only.
  - Title is New York 16pt, author and status caption secondaryInk, star rating in `warning`.
  - The overflow menu hit target becomes 32×28.
- [ ] **Step 5:** Build and render into `scratchpad/after-1`. Compare `today-*`, `library-*`, `today-compact-*` and `popover-*` against `before`.
- [ ] **Step 6:** Commit "Restyle Today, Library and sidebar around shared page layout".
- [ ] **Step 7: CHECKPOINT:** send the user the before/after Today and Library renders (light + dark) and wait for the go-ahead.

### Task 4: History, Timeline (+ Book details dates), Reviews, Settings, Health, popover

- [ ] **History (`HistoryView.swift`):**
  - `PageHeader` moves inside the `ScrollView` (fixes the pinned header).
  - Metrics become an `HStack` of `StatLine` separated by vertical hairlines, with no cards.
  - The toolbar is one row: ‹ › title, then segmented scale (fixed 320), then Today.
  - Month cells lose their fill. Days with reading show the number, the page label and a 3pt accent/chart bar. Today gets an accent 1.5pt outline, future days secondaryInk at 0.45.
  - The legend uses `chart(0...2)` + secondaryInk at caption size.
  - The Day detail drops the inner "Books" card for a `ReadingSection`.
  - Replace `.secondary` with secondaryInk.
- [ ] **Timeline (`FinishedBookView.swift`):**
  - `ReadingTimelineView` becomes `ScrollView { PageHeader(... trailing: search 260) ; FinishedBookTimeline }.readingPage()`.
  - `FinishedBookTimeline` drops `.readingPanel()`. Each year is `Text(year)` in New York 28pt + `Hairline`.
  - `FinishedBookTimelineRow` becomes a `Button { model? present }`. It needs a `present: (DashboardSheet) -> Void` closure (default no-op for previews), and `ReadingTimelineView` gets `present` from `DashboardView`.
  - The row label is an `HStack`: a date column of 64pt (`Sep 24` 13pt semibold + `Thu` caption), a `.timeline` cover (72×108), then a VStack of New York 20pt title, author, source caption and read-only `RatingStars`. A chevron sits trailing.
  - Hover gets a surface fill (radius 14). `accessibilityLabel` is "\(title), finished \(date)"; the hint is "Open book details to rate or edit dates".
  - Remove the inline rating editor, "Edit reading dates" and "Rate/Edit rating" from the row.
- [ ] **Book details (`LibraryView.swift` BookDetailView.hero):**
  - When `finishedEntry != nil`, add a `Button("Edit reading dates")` (small) next to the finished label, presenting `ReadingDatesEditor(title:dates:timezoneID:save:)` via a new `@State editingDates`, with the same save closure as the old timeline row.
  - The hero loses its surface card; the cover gets a shadow.
- [ ] **Reviews, Health, Settings:** the shared `PageHeader`/`.readingPage()`; settings groups use `ReadingSection` + hairline rows instead of stacked cards; new `SettingsCategory.appearance` (title "Appearance", icon "paintpalette") placed second.
- [ ] **Popover:**
  - One canvas surface, 18pt padding.
  - Header: leaf + wordmark in New York 15pt, Dashboard button.
  - Book row, then the ring + stats (existing `MenuReadingGoal`, colours via tokens), then a hairline, then the streak and session in one row, then setup notices as inline rows (icon + text + small button, no fill), then the footer.
- [ ] **Sweep:** replace remaining `.foregroundStyle(.secondary)` / `Color.red` / `Color.black` shadows in dashboard files with tokens (`secondaryInk`, `warning` for destructive tint, `ink.opacity` for shadows). Verify with `grep -nE "\.secondary\)|Color\.(red|black|white|gray|green)" Sources/BooksPresence/*.swift | grep -vE "/(EPUB|Reader)"`, which should return nothing.
- [ ] Build, render and inspect; commit per screen group ("Restyle History…", "Make timeline rows open book details…", "Restyle Reviews, Settings and Data health…", "Restyle the menu-bar popover…").

### Task 5: Appearance picker and full theme catalogue

**Files:** Create `AppearancePicker.swift`; modify `ControlsView.swift` (the `.appearance` category detail).

- [ ] **Theme grid:** `AppearancePicker(store: ThemeStore.shared)` shows a `LazyVGrid` (adaptive 150) of theme cards. Each card is a 150×96 swatch: canvas background, surface strip, two ink/secondary lines and an accent pill, drawn from `theme.colors(dark: colorScheme == .dark, accent: nil)`. The name sits under it; the selected card gets a 2pt accent outline and checkmark.
- [ ] **Accent row:** "Theme default" plus 8 circles (24pt, accent colour, ring when selected). `accessibilityLabel` is "Theme: \(name)" / "Accent: \(name)", with `.isSelected` when selected. Selection calls `store.select(...)`.
- [ ] **Catalogue:** tune Graphite/Ocean/Clay/Plum/Forest and the accents until `theme-contrast-smoke` passes.
- [ ] Commit "Add appearance picker with six themes and accent presets".

### Task 6: All-theme renders, UISmoke, final verification

- [ ] **`UIRender.swift`:** when `--all-themes` is present, after the normal pass, loop `ReadingTheme.all`. Set `ThemeStore.shared.select(theme:)` on a preview defaults suite, and render the dashboard sections (today, library, timeline, history-month, history-day, review, settings-reading, settings-appearance, health) plus the popover into `<dir>/themes/<id>/<name>-<light|dark>.png`. The store's `reload(from:)` is pointed at the preview suite so the user's defaults are never written. Restore the original selection afterwards.
- [ ] **UISmoke additions**, before the view loop:

```swift
let themeSuite = UserDefaults(suiteName: suite + ".theme")!
defer { themeSuite.removePersistentDomain(forName: suite + ".theme") }
let store = ThemeStore.shared
store.reload(from: themeSuite)
themeSuite.set("bogus", forKey: "appearanceTheme"); store.reload(from: themeSuite)
guard store.themeID == "stillleaf" else { throw BooksAccessErrorForUI.failed("Unknown theme id did not fall back") }
let before = store.revision
store.select(theme: "ocean"); store.select(accent: "rose")
guard store.revision > before, themeSuite.string(forKey: "appearanceTheme") == "ocean",
      themeSuite.string(forKey: "appearanceAccent") == "rose" else { throw BooksAccessErrorForUI.failed("Theme choice did not persist") }
guard ThemeContrast.failures().isEmpty else { throw BooksAccessErrorForUI.failed("Theme contrast regressed") }
```

  Also add views `("appearance", AppearancePicker(store: store))` and `("settings-appearance", …)`. The existing loop covers them because `SettingsCategory.allCases` includes `.appearance`. Lay out `popover` and `timeline` again after the switch. Restore `store.select(theme: "stillleaf"); store.select(accent: nil)` and then `store.reload(from: .standard)` at the end.
- [ ] Run `scripts/check-local.sh` (expect all suites, contrast smoke and `--self-test-ui` to pass). Run `--render-ui <dir> --all-themes` and inspect a sample per theme in light and dark.
- [ ] Commit "Render every theme and cover themes, timeline and picker in UI smoke"; push `ui/dashboard-refresh`.
