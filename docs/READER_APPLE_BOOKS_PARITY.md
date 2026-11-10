# Reader parity with Apple Books

What the reader matches in Apple Books on the Mac, measured where possible. Reference captures were taken from Books 8.0
(build 6476) on macOS 26, on a 1280 × 800 pt display at 2×. They stay outside the repository because they show book
text and Apple's interface. Only the numbers below were kept.

## How it was measured

- **Source.** One user-owned EPUB, read in Books with the reader's own settings. Window captures were made by window ID,
  so only Books' windows were captured. Popovers and menus are separate windows, and their sizes come from the window
  list. Colours are exact pixels. Positions are points (pixels ÷ 2).
- **The owner's theme is customised.** Its Original theme uses Iowan, line spacing 1.44, character 1%, word 4%,
  margins −3%, Columns 2 and Justify on. Values marked "(owner's theme)" reflect those settings. Books' unmodified
  defaults come from its Paper theme (marked "(default)").
- **Theme colours.** Switching theme crossfades for more than 0.9 s, so the full-window theme captures caught Books
  mid-change. Only Original and Focus settled. Every other theme colour comes from its tile in the Themes & Settings
  popover (marked "(swatch)").
- **Page turns.** About 60 window-only frames were captured around one arrow key press in each direction, and the
  text offset in each frame was found by correlation.
- **Chrome timing.** Read from the accessibility tree at about 10 Hz while the pointer was moved.
- **Never measured.** A display wider than 1280 pt, Books' Auto Set column threshold (the owner's theme forces two
  columns), and the bookmark list with rows in it.

## Element by element

| Element | Apple Books (measured unless marked) | Stillleaf before | Stillleaf now |
|---|---|---|---|
| Page surface | The window and everything in it are the page colour. Nothing frames the text column. | With the garden on (the default), the page was a card on a backdrop (`#151515` around Night's `#000`), with a 10 px radius, a shadow, a fold between facing pages and a footer pill. With it off, a 1 px footer rule remained. | One colour from edge to edge in every theme and mode, at 1512×982, 1728×1117, 2560×1440 and 3840×2160, in WebKit and Chromium (`test/reader-surface.test.mjs`). |
| Title band | Part of the page. The page runs under a transparent title bar. | Title bar in the page colour, but a separate surface above the web view. | The web view runs under a transparent, full-size title bar, so there is one surface. The window and the under-page area follow the page colour. |
| Default window | 1024 × 768 | 1000 × 800 | 1024 × 768 |
| Text top | 76.5–77 pt from the window's top, in a window and in full screen, with controls shown or hidden. | 66 pt bar, then a 32 pt inset. | The first line's ink starts at 77 pt in both. The text never moves when the controls show or hide. |
| Facing columns, 1280 wide | (default) 77.5–596.5 and 681.5–1201.5: outer margin 77.5 (6.05%), gap 85, column 519. (owner's theme) 60–606.5 and 672.5–1218.5. | 1376 pt maximum spread, 44 pt gutters. | 77–597 and 682–1202 (justified text). Outer margin 6.05% of the width, gutter 3.3%, measured after Readium's type-size zoom. |
| Facing columns, 1024 wide | (owner's theme) 49.5–484.5 and 539–976 | Single column below 1100 pt | 62–477 and 546–961, two columns from 960 pt. |
| Column width as the window grows | Proportional at 1024 and 1280. Unmeasured beyond 1280. | Fixed measure, centred | Proportional margins, with columns capped at the chosen line width (about 65 characters), so very wide windows get wider margins on one surface. |
| One or two pages | Follows window width ("drag the window's sides"). The Columns setting offers 1, 2 and Auto Set. | Single by default; Facing was a choice. | New books open in two columns when the window is 960 pt or wider. Saved Single choices are kept. |
| Line pitch | (owner's theme) 24 pt. (default) about 26 pt. | 30.7 pt (19.2 px × 1.6) | 27–29 pt (19.2 px × 1.45). Saved line heights are kept. |
| Page number | Centred, 8 pt digit height (about 11 pt semibold). Centre is 48 pt above the bottom. Reads `311` with controls hidden and `311 of 546` with them shown. Colour `#8C8C8C` on black, `#808080` on white. | Left and right footer labels with "pages left in chapter", above a rule. | Centred 11 px semibold, centre 48 pt above the bottom, `311` or `311 of 546` (screen readers still get the full label). Colour is ink at 55% (`#828283` on Night). |
| Page numbers across layouts | They reflow: 311 of 546 in the window became 247 in full screen for the same text. | Same, as screen counts | Same: one number per screen or spread, counted per layout. |
| Progress knob | A 24.5 × 9 pt pill at the window's foot, at the book's progress (57%), `#808080` while the controls show. | none | Not built (see Still different). |
| Toolbar band | 52 pt. Traffic lights at 18 pt. | 52 pt, with buttons Contents, Search, Notes, Previous, Next, Bookmark, Focus and Aa, each on its own bezel. | 52 pt with Books' layout (below). |
| Toolbar groups | A left capsule (Contents, Bookmarks, Highlights) at x 98–210, the title centred, a right capsule (Aa, Search) at 889–962, and the Bookmark circle at 979–1015. 35 pt tall, about 37 pt a button. | as above | The same groups, sizes and order, drawn by our own view with SF Symbols. Previous, Next and Focus stay in the menu and on the keyboard. |
| Capsule colour | `#131313` on a black page. On white, the page colour with a soft shadow. | system bezels | Ink at 8% on dark pages. On light pages, the panel colour with a 10% shadow at radius 8. |
| Bookmark button | Solid when the page is bookmarked. | outline, toggled | `bookmark` / `bookmark.fill` |
| Controls in a window | Shown when a book opens, until the pointer moves. Then shown only while the pointer is in the top band: visible at 50 pt, gone at 70 pt. They go about 0.14 s after the pointer leaves. Movement elsewhere does not bring them back. Hidden, the title stays as dim text (`#8C8C8C`, 13 pt, y 21–31) and the traffic lights go. | Always visible | The same rule, with a 60 pt band and a 0.18 s fade, and the same dim title. They stay for an open panel, VoiceOver and full keyboard access. **Never seen with a real pointer** (see Verification). |
| Controls in full screen | Nothing but the page and its number. The toolbar slides in under the menu bar when the pointer reaches the top, and leaves within about 0.24 s. | AppKit default | `.fullScreen + .autoHideMenuBar + .autoHideToolbar`. **Never seen in real full screen.** |
| Page turn (keyboard) | The whole window slides: text moves 1220 pt at 1280 wide. About 420 ms, cubic-bezier(.25,.9,.4,1) within 8.5 pt rms. No fade and no edge shadow. | 320 ms slide clipped to the text column, with a fade and an edge shadow. | The page crosses the whole window in 420 ms on the fitted curve, with only a transform. Time to the first moving frame is unchanged (WebKit, interleaved runs: 61.6 / 60.1 ms before, 59.8 / 58.6 ms after). |
| Themes & Settings popover | 312 × 373. Centred grey title, an A \| A capsule (about 168 × 47), a moon capsule (about 81 × 47), six theme tiles 3 × 2 (about 80 × 72, "Aa" and the name inside), and a Customize capsule. Fill `#F6F6F6` light, `#151515` dark. Control fill `#DEDEDF` / `#303033`. | 380 × 640 panel, all controls at once | 312 × 424: the same header, A \| A (5% steps), a moon/sun button between Original and Night, nine tiles 3 × 3 and a Customize capsule. Customize grows the panel to 640 and holds the rest. |
| Customize | A 704 × 760 sheet: Font, Bold Text, Line, Character and Word spacing, Margins, Columns (1/2/Auto Set), Justify Text, Reset Theme. | Advanced section | Inside the same panel: more themes, Text, Layout, Garden, Advanced, Reset appearance. |
| Contents | Popover 312 × 722. Centred "Contents", hairline, semibold titles with the page number at the right, the current chapter on a filled row. | 380 × 560 panel with a Contents / Bookmarks / Notes switcher | 312 × 722 with the same header, semibold titles with the chapter's start page at the right, and the current row filled. Bookmarks and Highlights each have their own toolbar button and panel (⌘1–3 still switch). |
| Bookmarks | Popover 312 × 722 (only seen empty) | tab | Own button and panel, 312 × 722 |
| Highlights & Notes | Popover 312 × 251 when empty | tab | Own button, 312 × 480 |
| Search | A field-only popover (312 × 211 empty). "Searching…" shows under the field while results load. | 380 × 560 with a title | 312 × 480 with a centred "Search" title over the field. |
| Selection | A drag selects in grey (`#404040` on black) with no pop-up. Control-click opens a menu: five dots, underline, Add Note, Translate, Search, Copy, Share…, Speech (303 × 229, fill `#1B1B1B`). | A toolbar on selection with three colours | The selection toolbar stays, now with Books' five colours (see below). |
| Highlight colours | `#EAD158` `#A7DA8C` `#9CB8F9` `#F1A0B4` `#C1B0F6` | `#E4C778` `#A7CBB0` `#D7A9B4` | The five measured colours. Saved ids (`gold`, `sage`, `rose`) are unchanged; `blue` and `purple` are new. |
| Panel surface | Translucent (blurred) | Solid (owner's choice, 2026-10-14) | Solid, 18 pt corners, 312 pt wide, tokens shared by `panels.css` and `ReaderPanelStyle.swift` |
| Margin garden | none | On by default, framed as a card | Off by default, drawn straight on the page colour when chosen (Appearance › Customize › Garden). A saved `vines: 'margins'` reads as off unless the new `vinesChosen` says it was picked. |

## Theme colours

| Books theme | Light page | Dark page | Stillleaf nearest | Stillleaf page / text |
|---|---|---|---|---|
| Original | `#FFFFFF` / text `#000000` | `#000000` / `#FFFFFF` | Original, and System by day | `#FFFFFF` / `#111113` |
| Original (dark) | | `#000000` / `#FFFFFF` | Night, and System by night | `#000000` / `#ECECEE` (kept by choice) |
| Quiet | `#4A4A4D` (swatch) | `#000000` (swatch) | Quiet | `#3A3A3E` / `#F2F2F4` (higher contrast, kept) |
| Paper | `#EEEDED` (swatch) | `#1C1C1E` (swatch) | none | |
| Bold | `#FFFFFF` (swatch) | `#000000` (swatch) | Original with Bold weight | |
| Calm | `#EEE2CC` (swatch) | `#413B31` (swatch) | Calm | `#EEE2CC` / `#261E15` (already equal) |
| Focus | `#FFFCF5`, text `#141202` | `#18160D`, text `#FEF9EC` | Focus | `#FFFBEF` / `#100F0C` |

Links measured `#459BD7` on black and `#0000F5` on white.

## Still different, and why

- **Kept by your choice (2026-10-14):** Night is `#000` with `#ECECEE` text (Books uses pure white), panels are solid rather than translucent, the default typeface is New York (Books defaults to the book's own font), and the Quiet and Focus colours stay at the higher-contrast values.
- **My calls, open to reversal:**
  - The garden is off by default in the reader.
  - System by day is now white like Books' Original, not the Stillleaf mint.
  - New books open in two columns from 960 pt.
  - The default line height is 1.45, close to your Books setting of 1.44.
  - A book saved while the garden was the default opens with it off. Someone who had turned it off and on again loses that choice once.
- **Not built yet:**
  - The progress knob at the window's foot.
  - The arrows that appear at the page edges on hover.
  - The underline highlight style.
  - Books' wait-for-Control-click selection menu. Stillleaf still shows its toolbar as soon as you select.
  - Books' separate Customize sheet.
- **Unmeasured, so following the measured proportions:**
  - Column width on displays wider than 1280 pt.
  - Books' Auto Set threshold for one page versus two.
  - Exact type sizes of Books' defaults.
- **Never seen live:**
  - Real full screen, and the auto-hiding controls under a real pointer. Background-mode tools cannot take focus or move the pointer, so these need you at the Mac.

## Verification

- `test/reader-surface.test.mjs`: one colour at four full-screen sizes, in every theme and mode, in WebKit and Chromium. It also covers focus reading, the web bar, the garden on, a frame held halfway through a page turn, and a check that it sees text so a blank page cannot pass.
- `test/layout-key.test.mjs`: saved page maps follow the layout key. Theme and garden changes keep the count; margins and window size start a new map.
- The renderer suites, the native EPUB smoke (`--self-test-epub`), `scripts/check-local.sh`, `iOS/scripts/check-model-local.sh` and `--capture-window-chrome` (page under a transparent full-size title bar, with band presses going to the title bar).
- `scripts/render-reader-surface.mjs` renders any matrix of sizes, themes and modes, and reports how many colours each surface uses.
