# Stillleaf website

The product, download and support site for Stillleaf, isolated from the native app. It is launch-ready but unpublished: every page is `noindex` and downloads stay gated until the owner approves publication (see [Publication gates](#release-configuration-and-publication-gates) and [DEPLOY.md](DEPLOY.md)). Nothing in this directory launches, changes, signs, or distributes the installed app.

Pages: `/` (landing), `/privacy/`, `/support/`, `/about/` (about and press kit), `/terms/`, and `404.html`.

## Run locally

Requires Node 22.12 or later.

```sh
cd website
npm ci
npm run dev
```

Open http://127.0.0.1:4173. The server binds only to loopback and fails if the port is already occupied. To check the production output, stop the development server and run:

```sh
npm run build
npm run preview
```

Build output is `website/dist/`; it is ignored by Git. The site has no mailing-list backend, analytics, cookies, or external runtime dependencies. Until publication is approved, the generated `robots.txt` and robots meta tags prevent indexing by cooperative crawlers; they are not access controls. The only deploy path is the manual, gated GitHub Pages workflow described in [DEPLOY.md](DEPLOY.md). The site expects to be served from the root of its own domain (`base: "/"`).

## Structure

- `index.html`: landing page; semantic content and honest no-JavaScript availability fallback.
- `privacy/`, `support/`, `about/`, `terms/`, `404.html`: document pages. They load `src/page.css` only (no JavaScript) and share the landing page's header and footer.
- `src/site-config.js`: open publication decisions (domain, contact, legal publisher and date, iOS state, update-feed path and app identity) and their validation.
- `src/site-build.js`: pure build helpers: `{{token}}` filling, shared header/footer partials, robots/canonical/Open Graph tags, Content-Security-Policy, robots.txt and sitemap.
- `src/update-feed.js`: the Mac app's update feed (`/updates/macos.json`), generated only for a published, verified release. Contract, shared with the app and release scripts: [UPDATES.md](UPDATES.md).
- `scripts/site-plugin.mjs`: Vite plugin that applies the above at build time, preloads the headline font, and fails the build on invalid config.
- `src/pages.css`: document-page layout (reading column, contents list, tables, press assets).
- `src/style.css`: responsive design and six-surface CSS 3D books.
- `src/main.js`: native-image selector, release cards, motion eligibility, global pause control, and pointer depth.
- `src/scroll-motion.js`: passive scroll orchestration, shared-journey geometry, and hero depth.
- `src/showcase.js`: sample daily arc, reader appearance controls, continuous journey state, and automatic resumption after manual interaction.
- `src/showcase.css`: shared sticky desktop stage, arc-to-reader wipe and transforms, botanical/orbit background, reader looks, and static/mobile layouts.
- `src/showcase-model.js`: pure, reversible daily/reader and shared-journey mappings; illustrative reader presets.
- `src/closing-showcase.js` and `src/closing-showcase.css`: editorial journal, optional native gallery, release presentation, and traveling dimensional books.
- `src/releases.js`: sole source for release availability; use `getDownload`, never link directly to `artifact.url`.
- `public/covers/`: original vector jackets; `public/daily-arc.svg`: static sample arc; `public/screenshots/`: genuine native renders with sample data.
- `ASSETS.md`: provenance and font licensing.
- `scripts/validate-release.mjs`, `tests/releases.test.mjs`: release and site-config gate validation.
- `tests/site.test.mjs`: site config, noindex/indexing switch, head tags, tokens, iOS states, and the exact update feed.
- `tests/pages.test.mjs`: page structure, internal links, a privacy drift guard (every network host in `Sources/` must be named in the privacy policy), and reader colours matching `Reader/desktop/reader/src/appearance.js`.
- `tests/showcase-model.test.mjs`: progress boundaries, invalid geometry/input, page completion thresholds, and forward/reverse preset selection.
- `VERIFICATION.md`: checked behavior and remaining limits.

This uses plain HTML, CSS and JavaScript with Vite as the build tool; no UI framework or 3D runtime is required. See the [Vite guide](https://vite.dev/guide/) for the build tool's standard commands.

## Design

The page moves from a constellation of original floating books into one continuous reading journey: a sample daily goal flows into a customizable reader preview that uses the Mac reader's own page colours. An editorial book-and-review composition follows, with genuine native Mac app screenshots (from an earlier 1.5 build; recapture before launch, see ASSETS.md) in an optional closer-look gallery. Its moving dimensional books continue through gated Mac/Windows release cards. The iPhone and iPad card follows `site.ios.state`, “Coming soon” with no announced date by default. A privacy section, the FAQ and a footer with Support, Privacy, Terms and About close the page.

Palette: sea glass `#e5eeea`, pale paper `#f5f8f5`, forest ink `#183d33`, secondary ink `#52695f`, moss `#176650`, and subtle line `#d0ded6`. These adapt the native app's `ReadingPalette`. Instrument Serif gives the headlines a bookish shape; DM Sans carries navigation and reading copy. Readable text is at least 12px. Instrument Serif is preloaded and its fallbacks are width-matched (Times New Roman, then Georgia at 91.2%), so headlines don't reflow when it loads. The main hero is centered; editorial sections are left aligned; release cards are parallel platform choices.

Each hero book has a front, back, spine, and page-block faces with perspective and original vector cover art. CSS drift alternates over 9–13 seconds, traversing 42 pixels vertically with rotation and depth changes. Eligible pointer movement adds subtle parallax. Scrolling sends each solid on a distinct trajectory: 160–310 pixels down, lateral offsets up to130 pixels, depth changes, and up to28 degrees of added rotation, combined with the shared24-pixel lift/48-pixel retreat. Original cover art and starting composition remain intact.

On eligible desktop views, `.reading-journey` provides a single sticky stage with native scrolling. The daily card enters with perspective, while its dotted arc moves and turns into place; the first part of the journey fills a sample goal from 0 to 24 pages. The arc follows `DottedReadingArc` in `Sources/BooksPresence/ReadingProgress.swift`, including its two rows and partial leading dots. The page count reaches “complete” at the end of that daily segment. An optional range control sits inside “Explore at your own pace,” leaving the automatic story as the default.

The same stage then wipes and transforms the daily card into the reader presentation while the shared background blends from pale paper into forest green. The reader follows scroll through Stillleaf, Warm, Dusk, and Night: four of the Mac reader's own page colours, with New York, Georgia and San Francisco shown in the visitor's closest system font. Pale reader copy and captions fade in only once the background is at least 90% dark, so text never sits on a mid-blend green. Visitors can select a look, typeface, line spacing, or sample page count directly. Their choice holds while they interact; automatic progression resumes once scrolling moves more than 32 pixels from that interaction. There are no separate follow-scroll buttons. Progress, the card transition, and preset choices reverse with backward scrolling. Ink and paper colors switch together, avoiding a transition that could briefly mix a light background with light text. Short captions identify the sample day and in-development reader without covering the demonstrations.

One set of botanical shapes and orbit lines carries motion through the arc-to-reader transition. A passive listener coalesces scroll/resize input into one animation frame, reads geometry before writing styles, and uses IntersectionObserver to limit work to visible or just-exited content. There is no continuous JavaScript render loop. The inactive overlapping section is marked `inert` so its controls do not remain interactive behind the visible presentation. Ordinary browser scrolling and anchor navigation remain intact; navigation and the genuine native screenshot gallery after the journey do not rely on animated reveals.

Motion starts paused until JavaScript evaluates eligibility. The heavier scroll journey is disabled at widths of900px or less, heights of700px or less, reduced motion, Save Data, and detected constrained devices. Static layouts stack the daily and reader sections, retaining both demonstrations and manual controls when JavaScript is available. Lightweight hero drift has a separate eligibility check: a compact desktop with a fine pointer can retain it while the heavier journey stays off. Touch-first compact views, reduced motion, Save Data, and devices reporting at most two logical processors disable that ambient drift too. Lower-page dimensional books follow a shared scroll coordinate across journal and downloads, with620 pixels of descent,54 degrees of turn and170 pixels of depth travel over the full range. One unobtrusive fixed pause/resume icon controls all animation and stores the preference locally; it has accessible text plus a hover/focus tooltip. Animations pause in hidden tabs and decorative drift pauses offscreen. Pausing removes the scroll listeners, cancels pending frames and reader transitions, and restores the two sections as fully visible, interactive content while preserving the active section in view. Tab visibility changes keep the shared layout geometry; a keyboard continuation link enters the reader layer. Browsers do not expose every low-power mode; these checks are conservative fallbacks, not universal battery-saving detection.

Product positioning describes the Mac app: a menu-bar reading journal with a built-in offline EPUB reader, Library, Timeline, History and Reviews, optional Apple Books tracking and Discord presence, and local-only data. A privacy section and the FAQ link to the full policy and support pages. The Mac release card is primary; Windows is a secondary in-development card; the iPhone and iPad card, FAQ entry and fact sheet follow `site.ios.state` (`hidden`, `coming-soon`, `available`). Downloads remain gated.

App screenshots are genuine native renders with sample-data captions. Screenshot and theme choices use buttons with pressed states; typeface and spacing use native form controls; the daily range and FAQ use native details/summary. A skip link and visible focus outlines support keyboard use. Without JavaScript, the page retains a static 12-of-24-page arc, its original reader passage, native screenshots, and unavailable platform states; interactive controls stay hidden.

This section describes the source implementation, not a new runtime verification result. See `VERIFICATION.md` for recorded checks and their limits.

## Verify

```sh
npm test
npm run build
npm run check:release
node scripts/validate-release.mjs --for-publication
```

The final command **must fail in the current local-only state**. Normal local builds must pass.

## Release configuration and publication gates

`publication.approved` is false, both platform artifacts are null, and `site.origin`, `site.contactEmail` and `site.legal` are null. This is intentional. Do not change those values simply to make the publication check pass.

For an authorized, verified release, update the Mac entry's summary, requirements, state and artifact: permanent public HTTPS URL of the notarized DMG, version, build number, minimum macOS version, size in bytes, publication time and actual SHA-256 checksum (all copied from the release's `release-manifest.json`), and `verified: true` ([UPDATES.md](UPDATES.md) lists each field). `getDownload()` also requires publication approval. Validation is offline and does not prove that a URL works, a checksum belongs to a binary, or that signing has passed; the human release process must establish those facts.

Before any publication:

1. Verify the exact release: install/open behavior, Developer ID signing and notarization, and the checksum. No release certification is claimed here.
2. Choose the domain and fill `src/site-config.js`: `origin`, `contactEmail`, `legal.publisher` and `legal.effectiveDate`. Until then the policy pages show visible "pending" markers.
3. Review the privacy policy and terms against the release (they describe main as of this branch; `tests/pages.test.mjs` guards network hosts but not every sentence) and confirm licensing and pricing. No application LICENSE or pricing policy exists; the site invents neither.
4. Recapture the screenshots against the release (ASSETS.md) and decide the iOS state.
5. Obtain explicit user authorization to publish. Only then set `publication.approved`, which also turns on indexing, the sitemap and the update feed, and run the deploy in [DEPLOY.md](DEPLOY.md).

The integration boundary is the `website/` directory, plus the manual `.github/workflows/website-pages.yml` deploy workflow. The website does not modify native sources. `tests/pages.test.mjs` reads `Sources/` and `Reader/desktop/reader/src/appearance.js` read-only, and skips those checks in a website-only checkout.
