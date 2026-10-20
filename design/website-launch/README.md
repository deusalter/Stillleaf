# Website launch pass: before and after

Viewport captures of the production build, headless Chromium, 1440×900 and 390×844. `before/` is main at `698558f`; `after/` is `website/launch-ready`. Native app screenshots inside the page's gallery are unchanged and still need recapturing (see `website/ASSETS.md`).

The draft's design is kept: floating 3D books, the daily-arc-to-reader journey, the editorial journal scene, the Pageleaf mark, palette and type. Changes, and why:

| Area | Change | Why |
| --- | --- | --- |
| Reader demo (`desktop-3-reader`) | Page colours are the Mac reader's Stillleaf, Warm, Dusk and true-black Night; typefaces New York, Georgia, San Francisco. Label is “The built-in reader”. | The draft showed invented looks labelled “in development”; the reader has shipped. |
| Reader copy timing | Pale copy and captions appear only once the background is ≥90% dark. | axe measured 2.4–3.1:1 contrast mid-transition. |
| Journal (`desktop-4-journal`) | Four views in one row: Library, Timeline, History, Reviews. | History and the Timeline were missing or merged; these are the app's four journal views. |
| Downloads (`desktop-5-downloads`) | Mac card is primary, with real requirements; Windows is secondary; cards are opaque. | The Mac app is the release. Orbit lines crossed the card text. |
| iPhone and iPad | The roadmap line becomes a config-driven card: hidden, coming soon, or App Store badge (`config-ios-available-test-badge` shows the last with a test badge). Android is no longer mentioned. | The iOS app is in development; there is no Android project. |
| Privacy section (`desktop-6-privacy-faq`) | New section in the FAQ's two-column style: no account, optional Apple Books, Discord off by default, export or delete. | Privacy is a main reason to choose the app and is needed for App Store review. |
| FAQ | Rewritten for the shipped app (DRM-free EPUBs, offline use, how pages and time are counted) with a link to Support. | Old answers said the reader wasn't available. |
| Footer (`desktop-7-footer`) | Support, Privacy, Terms, About and press; padded clear of the fixed animation button. | The button covered the only footer link; App Store listings need these URLs. |
| Type | Readable text is at least 12px (was 8–11px in 77 places); decorative spine lettering unchanged. | Legibility. |
| Headline font loading | Instrument Serif is preloaded, with width-matched fallbacks. | The hero headline reflowed on load (CLS 0.085 → 0.002). |
| New pages (`page-*`) | Privacy, Support, About and press, Terms, 404 in the same header, footer, palette and type, with a quiet Pageleaf in the hero corner. | Launch and App Store requirements. |
