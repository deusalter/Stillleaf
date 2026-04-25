# Apple Books capability investigation

Initial investigation: macOS 26.0.1, Books 8.0, Apple Silicon. These findings describe this host, not a stable Apple Books API.

| Field | Status | Evidence / fallback |
|---|---|---|
| Installed Books version | Verified | Bundle version 8.0 |
| Running app / foreground bundle ID | Verified API; live switching pending | NSWorkspace/NSRunningApplication; never collect other app titles |
| Accessibility permission | Unavailable initially | AXIsProcessTrusted returned false; app can request access |
| Reader vs library/store | Untested live | Fail closed unless focused AXDocument exactly matches local catalog path |
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
