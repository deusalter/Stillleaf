# In-App EPUB Reader Implementation Plan

> **Status:** historical. Written against `main` at 0e23ba6, before the Codex work-in-progress surfaced. The reader that shipped differs: it renders with the Readium navigator in a shared web renderer (`Reader/desktop/reader`) rather than a hand-written CSS-column paginator, and continuous scroll stays experimental. Kept for the protection gate, appearance and tracking rationale.

**Goal:** Read unprotected EPUBs inside Stillleaf in three layouts (continuous scroll, single-page paginated, two-page spread) with Apple Books–style appearance controls: themes including night, font family, text size, line spacing, margins and justification. Reading in the built-in reader feeds the same history, goals, streaks and Discord presence as Apple Books tracking, with first-party evidence instead of Accessibility inference.

**Architecture:** A pure package model and preferences in `BooksCore`; a bounded, DRM-gated EPUB resource provider in `BooksPlatform`; a separate reader window in `BooksPresence` hosting a `WKWebView` that loads book resources through a custom URL scheme and paginates with injected CSS columns. A small bridge reports locators and page turns back to `AppModel`, which feeds `TrackingEngine` through a dedicated reader branch of `tick()`.

**Tech Stack:** Swift 5.8, SwiftUI, AppKit, WebKit (`WKWebView`, `WKURLSchemeHandler`, `WKContentWorld`, `WKContentRuleList`), Compression framework, existing SQLite core. No third-party dependencies (no Readium).

## Global constraints

- **Never bypass DRM.** Apple Books Store purchases are FairPlay-protected and will not open. The reader opens only packages that pass the protection gate below and offers "Open in Apple Books" otherwise.
- **Never write to Apple Books databases.** Reader position is Stillleaf-local and does not sync with Books or iCloud; the UI says so.
- No network access from book content: a content rule list blocks every `http`/`https` load; only the `stillleaf-book` scheme resolves.
- Publisher JavaScript is disabled (`allowsContentJavaScript = false`). Stillleaf's pagination script runs in its own `WKContentWorld`, isolated from book content.
- Bounded reads everywhere: per-entry size limits, zip-slip rejection via `CoverCache.safeChild` semantics, no symlink escape.
- Keep the macOS 13 target and the direct `swiftc` build in `scripts/build-local.sh` (new files are picked up by its globs; WebKit is autolinked).
- Synthetic fixtures only. Generate a small EPUB in tests; never commit personal books.

## Key decisions

1. **Two engines, not three.** Single-page and two-page are the same CSS-column paginator with `columnCount` 1 or 2. Continuous scroll is a separate engine. Build the paginator first.
2. **"Flip" is a transition, not a mode.** Ship slide (default) and fade. A true page curl is optional polish: snapshot both pages with `WKWebView.takeSnapshot` and animate with Core Image `CIPageCurlTransition` (the `CATransition` page curl is unavailable on macOS). Reduce Motion always means no animation.
3. **Spread falls back automatically.** Two-page mode drops to one column when the content width is below ~900 pt, like Apple Books. The preference persists; the rendering adapts.
4. **Separate reader window, not a dashboard sheet.** Stillleaf is an `LSUIElement` accessory app. While any reader window is open, switch to `NSApp.setActivationPolicy(.regular)` so the reader appears in Cmd-Tab, the Dock and full screen; return to `.accessory` when the last reader window closes.
5. **Reader tracking needs no Accessibility permission.** The reader branch of `tick()` runs before the Accessibility and Books-foreground guards.
6. **Label reader time explicitly.** Add `ReadingMode.reader`. Raise `HistoryArchive.version` to 2 so older builds reject new archives cleanly instead of failing to decode them silently.

## Protection gate

A package opens only when all of these hold:

- `META-INF/container.xml` resolves to a readable OPF.
- There is no `META-INF/sinf.xml`, `META-INF/rights.xml` or `iTunesMetadata`-style FairPlay marker.
- `META-INF/encryption.xml` is absent, or it lists only font obfuscation (`http://www.idpf.org/2008/embedding`, `http://ns.adobe.com/pdf/enc#RC`). De-obfuscate those fonts per the OCF spec; they are not DRM. (`CoverCache` currently rejects any `encryption.xml`; the reader must not reuse that shortcut, or ordinary DRM-free books with embedded fonts will be refused.)
- The ZIP is not ZIP64 or encrypted-entry, or those are explicitly supported.

A failed gate produces a specific reason ("Protected by Apple Books", "Unsupported archive"), never a blank window.

## Appearance model (`BooksCore/ReaderPreferences.swift`)

```swift
public enum ReaderLayout: String, Codable { case scroll, singlePage, twoPage }
public enum ReaderTransition: String, Codable { case slide, fade, curl, none }
public struct ReaderTheme: Codable, Equatable { id, name, background, text, secondaryText, link, selection, dimImages: Bool }
public struct ReaderPreferences: Codable, Equatable {
    layout, transition, themeID, followsSystemAppearance: Bool, nightThemeID,
    fontFamily: ReaderFont, publisherFonts: Bool, textScale: Double,   // 0.75...2.5 in fixed steps
    lineHeight: Double,                                               // 1.2...2.0
    margins: ReaderMargins, justified: Bool, hyphenation: Bool
}
```

- **Themes:** Original (white), Paper (warm sepia), Quiet (grey), Calm (soft tan), Focus (cream), Night (near-black with soft grey text and dimmed images), Stillleaf (the app's mint palette). "Match system appearance" switches between a chosen day theme and Night.
- **Fonts:** Original (publisher), New York (`ui-serif`), San Francisco (`system-ui`), Athelas, Charter, Georgia, Iowan Old Style, Palatino, Seravek, Times New Roman. At runtime, hide families `NSFontManager` does not report. Monospace elements (`pre`, `code`, `kbd`, `samp`) and SVG text are never overridden.
- **CSS generation** is a pure function `ReaderStylesheet.css(for: ReaderPreferences, viewport:)` in `BooksCore`, unit-tested. Overrides use `!important` on body text colour, background and font. Publisher layout (headings, drop caps, alignment of centred elements) is preserved unless "publisher fonts" is off.
- **Formatting:** `font-kerning: normal`, `text-rendering: optimizeLegibility`, `hyphens: auto` with the package language, `widows/orphans: 2`, `hanging-punctuation: first`, images `max-width: 100%` and `max-height` equal to the column height with `break-inside: avoid`. In scroll mode the line length is capped at about 70ch.

## Locator and reflow

`ReaderLocator { spineIndex, href, progression: Double, domPath: [Int]?, charOffset: Int? }` is a CFI-like DOM path plus a progression fallback. Before any relayout (theme, font, size, spacing, margins, layout, window resize), JS captures the first visible text position. After relayout, it restores that range into view. Position persists per book to a new `reader_positions` table (migration), with debounced writes on turn and immediate writes on close. `deleteBook` and `deleteAll` must remove it, and JSON export includes it.

## Tracking, goals and Discord

- `tick()` gets a reader branch: if a Stillleaf reader window is key, `NSApp.isActive` is true, and the window is not miniaturized, call `apply(book:mode: .reader, …)`. Otherwise the reader contributes nothing, and the existing Books path runs unchanged. Lock, sleep and pause still apply through `commonPauseReason()`.
- **Page evidence** comes straight from the bridge rather than the Accessibility-derived `PageTurnTracker`. Paginated modes count forward turns: 1 per single-page turn and 2 per spread turn. Scroll mode counts viewport heights scrolled forward and labels them "page-equivalents". A bound rejects skimming (e.g. more than 8 pages within 2 s), and TOC or slider jumps never count. Record each turn as a `pageTurn` event whose `PageTurnEvidence` source reads "Stillleaf reader".
- Activity evidence comes from turns and scrolls inside the reader; the uncertainty threshold behaves exactly as for Books.
- **Discord:** `publishPresence()` treats an open reader window as `readerOpen` without the Accessibility window check. Paginated modes show "page X of Y (this layout)"; scroll mode shows the chapter title.
- **Popover:** "Continue reading" opens the most recent reader book at its saved locator.

## Work packages

- [ ] **P0 Reconcile:** push local WIP to a branch; diff it against this plan; keep what fits, record decisions here.
- [ ] **P1 Package (Core/Platform):** `EPUBPackage` (container, OPF metadata, manifest, spine, EPUB 3 nav with NCX fallback, rendition layout, language). Add a native ZIP central-directory reader with raw-deflate decode via `Compression`, replacing per-entry `/usr/bin/unzip` for the reader, plus the protection gate and font de-obfuscation. Tests: synthetic ZIP and directory EPUBs, zip-slip, oversize entries, obfuscated fonts, protected markers.
- [ ] **P2 Reader shell:** `ReaderWindowController`, SwiftUI chrome (TOC, progress scrubber, chapter title, Aa popover), `WKWebView` host with the `stillleaf-book://<bookID>/<path>` scheme handler, network-blocking rule list, content world bridge. Add single-page pagination with keyboard (arrows, space), click-edge and trackpad-swipe input, plus position persistence.
- [ ] **P3 Appearance:** preferences model, stylesheet generator, themes, fonts, size, spacing, margins, justification, night mode and system-appearance following, reflow-preserving locator. Preferences are global; per-book overrides come later.
- [ ] **P4 Layouts:** two-page spread (including `page-spread-left/right` and auto-fallback), continuous scroll with chapter-edge continuation, slide/fade transitions, Reduce Motion.
- [ ] **P5 Integration:** `ReadingMode.reader`, archive v2, `tick()` reader branch, page evidence, goals, Discord, Library card "Read" / "Open in Apple Books" actions, popover "Continue reading", activation-policy switching.
- [ ] **P6 Verification:** extend `UISmoke`/`--render-ui` with reader renders for every layout and theme in both appearances from a synthetic EPUB; add `scripts/reader-smoke.swift` to `check-local.sh`; run macOS CI.
- [ ] **Later:** fixed-layout (pre-paginated) EPUBs, page-curl transition, in-book search, highlights and notes, importing standalone DRM-free EPUBs that are not in Apple Books.

## Open questions for the owner

- What share of the library is DRM-free? If it is mostly Apple Books Store purchases, the reader will refuse most books. That is a hard constraint, not a bug to work around.
- Should reader pages count toward page goals equally with Apple Books pages, given that both depend on layout?
