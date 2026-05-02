# Apple Books capability investigation

Initial investigation: macOS 26.0.1, Books 8.0, Apple Silicon. These findings describe this host, not a stable Apple Books API.

| Field | Status | Evidence / fallback |
|---|---|---|
| Installed Books version | Verified | Bundle version 8.0 |
| Running app / foreground bundle ID | Verified API; live switching pending | NSWorkspace/NSRunningApplication; never collect other app titles |
| Accessibility permission | Granted to diagnostic; GUI grant checked independently | A rebuilt ad-hoc app may need a renewed grant; the optional GUI status report records its own trust |
| Reader vs library/store | One live Books 8.0 local EPUB matched; Library rejected | Exact document match preferred. Missing-document fallback requires the observed SceneWindow → six groups → one nonzero-sized WebArea structure, no library navigation, a complete bounded scan, and one exact catalog title. Store previews and other layouts remain unverified |
| Active reader among multiple windows | Untested live | Focused window only; never select most recently opened catalog entry |
| Stable asset identity/title/author/path | Verified schema and read access | Read-only ZBKLIBRARYASSET, validate columns before querying |
| Live page/location | Untested; omitted from capture | No verified fresh source; no reading text traversal |
| Saved progress/total pages | Verified columns, freshness unverified | Optional observations marked unreliable; not used for pages-read metrics |
| Local catalog cover URL | Unavailable in current records | Column exists but values empty; inspect exact local book artwork |
| Existing/custom covers | Verified one associated local image | Exact Books.plist book-info path resolved; cached image decoded successfully. Other formats and protected books remain untested; manual override takes priority |
| AppleScript book properties | Unavailable evidence | No sdef/scriptSuite found and no NSAppleScriptEnabled declaration; no invented scripting properties |
| Group container access | Unavailable | macOS denied directory read; no permission bypass |
| iPhone/iPad reading/backfill | Unavailable | First release only observes this Mac |

Run the bundled `books-diagnostic` to produce a current JSON report. It excludes personal metadata by default. Opt-in `--include-metadata` includes the focused Books title and matching asset metadata, never prose. Reports are local; do not commit them. Saved database progress is not proof of current activity or freshness.

## Books 8.0 reader fallback

The local EPUB reading window exposes a title but no AXDocument. The fallback is scoped to version 8.0 and the observed reader structure. It reads only roles, identifiers, children and WebArea size; it stops before web/text contents. It aborts on API errors, repeated nodes, child/depth/node/time limits, ambiguous titles, missing local EPUBs, and a changed focused window. Existing file-valued AXDocument matching remains preferred; a present invalid document never falls back to title inference. Catalog progress remains an unreliable saved value.

The observed Library window exposes `iBooksX.tabBar.*` navigation identifiers and is rejected. This does not establish PDF, protected EPUB, audiobook, store-preview, full-screen, multiwindow-transition or other-version support.
