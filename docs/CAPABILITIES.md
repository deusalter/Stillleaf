# Apple Books capability investigation

Initial investigation: macOS 26.0.1, Books 8.0, Apple Silicon. These findings describe this host, not a stable Apple Books API.

| Field | Status | Evidence / fallback |
|---|---|---|
| Installed Books version | Verified | Bundle version 8.0 |
| Running app / foreground bundle ID | Verified API and live foreground crediting | NSWorkspace/NSRunningApplication; never collect other app titles |
| Accessibility permission | Granted to diagnostic and current GUI build; checked independently | A rebuilt ad-hoc app may need a renewed grant; the optional GUI status report records its own trust |
| Reader vs library/store | One live Books 8.0 local EPUB matched; Library rejected | Exact document match preferred. Missing-document fallback requires the observed SceneWindow → six groups → one or two nonzero-sized reader WebAreas, no library navigation, a complete bounded scan, and one exact catalog title. Store previews and other layouts remain unverified |
| Active reader among multiple windows | Untested live | Focused window only; never select most recently opened catalog entry |
| Stable asset identity/title/author/path | Verified schema and read access | Read-only ZBKLIBRARYASSET, validate columns before querying |
| Page evidence | Observed separate Books 8.0 page footer | Exact English `Page <number>` or `Page <number> of <total>` description at the verified footer role path. Only small forward movement with stable reader bounds and unchanged displayed total is accepted. The total helps detect reflow; it is not a canonical page count. No words or gaze are collected. |
| Saved progress/total pages | Verified columns, freshness unverified | Optional observations marked unreliable and never used as page-turn evidence or a Discord percentage |
| Local catalog cover URL | Unavailable in current records | Column exists but values empty; inspect exact local book artwork |
| Apple Books finished metadata | Adapter implemented; live timeline still device-dependent | Read-only explicit `ZISFINISHED` flag and saved `ZDATEFINISHED` (Apple 2001 reference epoch); unknown/future dates remain unknown rather than invented |
| Apple public cover metadata | Opt-in implementation; live rendering remains separate | Apple iTunes Search API e-book results require one unique exact normalized title-and-author match; no local image is read or uploaded |
| Existing/custom covers | Verified one associated local image | Exact Books.plist book-info path resolved; cached image decoded successfully. Other formats and protected books remain untested; manual override takes priority |
| AppleScript book properties | Unavailable evidence | No sdef/scriptSuite found and no NSAppleScriptEnabled declaration; no invented scripting properties |
| Group container access | Unavailable | macOS denied directory read; no permission bypass |
| iPhone/iPad reading/backfill | Unavailable | First release only observes this Mac |

Run the bundled `books-diagnostic` to produce a current JSON report. It excludes personal metadata by default. Opt-in `--include-metadata` includes the focused Books title and matching asset metadata, never prose. Reports are local; do not commit them. Saved database progress is not proof of current activity or freshness.

## Books 8.0 reader fallback

The local EPUB reading window exposes a title but no AXDocument. The fallback is scoped to version 8.0 and the observed English reader structure. Reader identity uses roles, identifiers, children and WebArea size; it stops before web/text contents. Only the verified footer at SceneWindow → four groups → static text may have its description read, and only an exact `Page <positive ASCII integer>` is accepted. A page observation requires a small forward change while the reader bounds remain stable. No AXValue, book text, word count or gaze signal is requested. It aborts on API errors, repeated nodes, child/depth/node/time limits, ambiguous titles, missing local EPUBs, and a changed focused window. Existing file-valued AXDocument matching remains preferred; a present invalid document never falls back to title inference. Catalog progress remains an unreliable saved value.

The observed Library window exposes `iBooksX.tabBar.*` navigation identifiers and is rejected. This does not establish PDF, protected EPUB, audiobook, store-preview, full-screen, multiwindow-transition or other-version support.

## Completion metadata, ratings and covers

Apple Books history sync is optional. It reads only the catalog’s explicit finished flag and saved completion date, interpreting the date with Apple’s 2001 reference epoch. A missing, invalid or future saved date remains unknown; the app never manufactures one. The initial import is quiet, and imported completion metadata does not add time, pages or an activity claim. Deleting a book suppresses that stable Apple Books identity from future automatic imports. Ratings are optional user-entered values from zero to five in quarter-star steps.

Automatic public-cover lookup is off by default. When the reader opts in, it sends only a title and author to Apple’s documented iTunes Search API, asks for at most ten e-book results, and accepts one unique exact normalized match. It sends no local cover, book file or book text. The resulting image reference must be a validated public HTTPS image URL; local, private, credential-bearing and malformed URLs are rejected. Discord retrieves an accepted public image itself.
