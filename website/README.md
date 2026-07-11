# Stillleaf website

A local-only product and future download site, isolated from the native app. Nothing in this directory launches, changes, signs, or distributes the installed app.

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

Build output is `website/dist/`; it is ignored by Git. The site has no deployment script, hosting integration, mailing-list backend, analytics, or external runtime asset dependencies. `robots.txt` and the HTML robots meta tag prevent indexing by cooperative crawlers; they are not access controls. Keep the site local until publication is authorized.

## Structure

- `index.html`: semantic content and honest no-JavaScript availability fallback.
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
- `scripts/validate-release.mjs`, `tests/releases.test.mjs`: release-gate validation.
- `tests/showcase-model.test.mjs`: progress boundaries, invalid geometry/input, page completion thresholds, and forward/reverse preset selection.
- `VERIFICATION.md`: checked behavior and remaining limits.

This uses plain HTML, CSS and JavaScript with Vite as the build tool; no UI framework or 3D runtime is required. See the [Vite guide](https://vite.dev/guide/) for the build tool's standard commands.

## Design

The page moves from a constellation of original floating books into one continuous reading journey: a sample daily goal flows into an illustrative customizable reader. An editorial book-and-review composition follows, with genuine current Mac app screenshots in an optional closer-look gallery. Its moving dimensional books continue through gated Mac/Windows release cards. Android and iOS follow as “Coming soon,” with an explicit roadmap label and no announced date.

Palette: sea glass `#e5eeea`, pale paper `#f5f8f5`, forest ink `#183d33`, secondary ink `#52695f`, moss `#176650`, and subtle line `#d0ded6`. These adapt the native app's `ReadingPalette`. Instrument Serif gives the headlines a bookish shape; DM Sans carries navigation and reading copy. The main hero is centered; editorial sections are left aligned; release cards are parallel platform choices.

Each hero book has a front, back, spine, and page-block faces with perspective and original vector cover art. CSS drift alternates over 9–13 seconds, traversing 42 pixels vertically with rotation and depth changes. Eligible pointer movement adds subtle parallax. Scrolling sends each solid on a distinct trajectory: 160–310 pixels down, lateral offsets up to130 pixels, depth changes, and up to28 degrees of added rotation, combined with the shared24-pixel lift/48-pixel retreat. Original cover art and starting composition remain intact.

On eligible desktop views, `.reading-journey` provides a single sticky stage with native scrolling. The daily card enters with perspective, while its dotted arc moves and turns into place; the first part of the journey fills a sample goal from 0 to 24 pages. The arc follows `DottedReadingArc` in `Sources/BooksPresence/ReadingProgress.swift`, including its two rows and partial leading dots. The page count reaches “complete” at the end of that daily segment. An optional range control sits inside “Explore at your own pace,” leaving the automatic story as the default.

The same stage then wipes and transforms the daily card into the reader presentation while the shared background blends from pale paper into forest green. The reader follows scroll through Sea glass, Paper, Dusk, and Midnight. These are illustrative website looks, not a statement about the app's final theme catalog or a shipped reader interface. Visitors can select a look, typeface, line spacing, or sample page count directly. Their choice holds while they interact; automatic progression resumes once scrolling moves more than 32 pixels from that interaction. There are no separate follow-scroll buttons. Progress, the card transition, and preset choices reverse with backward scrolling. Ink and paper colors switch together, avoiding a transition that could briefly mix a light background with light text. Short captions identify the sample day and in-development reader without covering the demonstrations.

One set of botanical shapes and orbit lines carries motion through the arc-to-reader transition. A passive listener coalesces scroll/resize input into one animation frame, reads geometry before writing styles, and uses IntersectionObserver to limit work to visible or just-exited content. There is no continuous JavaScript render loop. The inactive overlapping section is marked `inert` so its controls do not remain interactive behind the visible presentation. Ordinary browser scrolling and anchor navigation remain intact; navigation and the genuine native screenshot gallery after the journey do not rely on animated reveals.

Motion starts paused until JavaScript evaluates eligibility. The heavier scroll journey is disabled at widths of900px or less, heights of700px or less, reduced motion, Save Data, and detected constrained devices. Static layouts stack the daily and reader sections, retaining both demonstrations and manual controls when JavaScript is available. Lightweight hero drift has a separate eligibility check: a compact desktop with a fine pointer can retain it while the heavier journey stays off. Touch-first compact views, reduced motion, Save Data, and devices reporting at most two logical processors disable that ambient drift too. Lower-page dimensional books follow a shared scroll coordinate across journal and downloads, with620 pixels of descent,54 degrees of turn and170 pixels of depth travel over the full range. One unobtrusive fixed pause/resume icon controls all animation and stores the preference locally; it has accessible text plus a hover/focus tooltip. Animations pause in hidden tabs and decorative drift pauses offscreen. Pausing removes the scroll listeners, cancels pending frames and reader transitions, and restores the two sections as fully visible, interactive content while preserving the active section in view. Tab visibility changes keep the shared layout geometry; a keyboard continuation link enters the reader layer. Browsers do not expose every low-power mode; these checks are conservative fallbacks, not universal battery-saving detection.

Product positioning describes an integrated EPUB reader and reading journal for Mac and Windows, with a separate in-development status. Current Mac screenshots and capability descriptions remain explicitly scoped to the existing journal; optional external-reader connections start with its Apple Books tracking. Downloads remain gated.

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

`publication.approved` is false and both platform artifacts are null. This is intentional. Do not change those values simply to make the publication check pass.

For an authorized, verified release, update each applicable platform's summary and requirements, state, and artifact metadata: permanent public HTTPS URL, exact version, actual SHA-256 checksum, and `verified: true`. `getDownload()` also requires publication approval. Validation is offline and does not prove that a URL works, a checksum belongs to a binary, or that signing has passed; the human release process must establish those facts.

Before any publication:

1. Reader lead integrates and verifies the combined application. Mac and Windows statuses must reflect the exact binaries; Windows runtime validation is still pending.
2. Verify distribution artifacts, install/open behavior, signing/notarization or platform trust requirements, and checksums. No such release certification is claimed here.
3. Confirm actual supported OS versions/hardware, app licensing/pricing and any required legal/privacy information. No application LICENSE or pricing policy was found at baseline; the website does not invent either.
4. Approve new screenshots and current-versus-planned product copy against the release. Mobile stays roadmap-only until its actual status changes.
5. Obtain explicit user authorization to publish. Only then configure publication, enable verified downloads, update/remove the local-preview notice and crawler blocks, and choose hosting/domain details.

The reader integration boundary is the complete `website/` directory. The website does not modify native sources or repository-root configuration.
