# Stillleaf for iPhone and iPad — design

Status: v1 implementation on branch `ios/iphone-app`. Scope: an App Store–ready
reading journal with the built-in offline EPUB reader, goals and the Library /
Timeline / History / Reviews views, sharing the Mac app's storage, statistics and
renderer.

## Platform constraints

- iOS gives one app no view into another app's windows. There is no Accessibility
  API across apps, so **Apple Books cannot be observed** on iPhone or iPad.
- Discord Rich Presence uses a local IPC socket to the Discord desktop client.
  iOS has neither the client nor that socket, so **Discord sharing is Mac-only**.
- Apps are suspended shortly after leaving the foreground. Stillleaf requests no
  background modes, so the iOS app records reading only while you are reading in
  it.

## Feature parity

| Capability | Mac | iOS v1 | Notes |
| --- | --- | --- | --- |
| Built-in EPUB reader (paged/continuous, appearance, contents, search, bookmarks, highlights, notes) | Yes, native AppKit panels | Yes, renderer's own web panels | Same `Reader/desktop/reader` bundle in `WKWebView` |
| Page turns | Keys, trackpad, edge clicks | Edge taps (renderer) and horizontal swipes (native) | Swipes call the same `StillleafReader.next/previous` path |
| Active reading time and page coverage from the built-in reader | Yes | Yes, foreground only | Rules below |
| EPUB import | Open panel, drag and drop, Apple Books folders | Files picker, “Open in”/share sheet, AirDrop | Unpacked Apple Books folders are Mac-only |
| Apple Books tracking and finished-book sync | Yes (Accessibility) | No | Not possible on iOS |
| Discord Rich Presence | Yes | No | Not possible on iOS |
| Manual “Log reading” (paper books, time and/or pages) | Yes | Yes | Same `ManualReadingEntry` validation |
| Live manual reading timer | Yes | No | It would need background execution; log the session afterwards |
| Local audiobooks | Yes | No (v1) | Would need the background-audio mode |
| Daily goal (pages or minutes), yearly books goal, streaks | Yes | Yes | Same `ReadingGoals` and `ReadingStatistics` |
| Library, mark finished, reading dates, rating, review | Yes | Yes | Same audit events (`bookCompleted`, `bookRated`, `bookReviewed`) |
| Timeline (finished books) | Yes | Yes | |
| History | Day/Week/Month/Year atlas | Month calendar, then a day's sessions | Atlas views are AppKit-specific; day totals use the same core functions |
| Reviews | Yes | Yes | |
| Session corrections (adjust/split/reassign/exclude) | Yes | Delete only (v1) | Imported corrections are honoured in all totals |
| Merge editions | Yes | Honoured when imported (v1) | No merge UI on iOS yet |
| Per-book “don't track” exclusion | Yes | Yes | |
| Calendar time zone | Yes | Yes | |
| JSON export/import, CSV export, SQLite backup/restore, delete all | Yes | Yes | Byte-compatible formats |
| Public cover lookup, Open Library search | Opt-in | No | The iOS app makes no network requests |
| Menu bar, login item, Dock presence | Yes | Not applicable | |
| Welcome tour | Yes | Short first-run screen | |

## Shared code

| Layer | Shared as | iOS change |
| --- | --- | --- |
| `BooksCore` (models, SQLite store, tracking engine, statistics, goals, manual entry, reader domain) | Swift package product | None; it already imports only Foundation and CSQLite |
| `CSQLite` | System library module | None; the iOS SDK ships `sqlite3.h` and `libsqlite3` |
| `BooksPlatform` | Swift package product | The seven macOS-only files (`BooksCapture`, `BooksCatalog`, `BooksReaderWindow`, `BooksWindowObserver`, `CoverCache`, `LoginService`, `SystemEligibility`) are wrapped in `#if os(macOS)`. The EPUB importer, reader scheme handler, web-view policy, reader state store and edition removal compile unchanged. |
| EPUB import | `EPUBPublicationImporter` | ZIP extraction gains a portable Swift reader that uses Apple's public `Compression` framework. macOS keeps libarchive. iOS cannot `dlopen("/usr/lib/libarchive.2.dylib")`: that library is not public on iOS, and using it risks App Review rejection under guideline 2.5.1. Packing unpacked Apple Books folders uses `Process` and stays macOS-only. |
| Reader launch | New `ReaderLaunch` in `BooksPlatform` | The resource map and `StillleafReader.open` payload move from the Mac reader window, so both hosts build identical input. |
| Renderer | `Reader/desktop/reader/dist` | Copied into the app bundle as `Reader/` by a build phase, exactly as `scripts/package-app.sh` copies it into `Contents/Resources/Reader` |
| Presentation (`HistoryPresentation`, views) | Not shared | AppKit/SwiftUI-for-Mac views stay in `BooksPresence`. The iOS `JournalSnapshot` calls the same `BooksCore` statistics functions. |

The Mac-side diff is limited to `Package.swift` (an added `.iOS("17.0")`
platform), file-level guards, the importer's extraction switch and the
`ReaderLaunch` extraction. Behaviour on macOS is unchanged.

## Project definition: XcodeGen

`iOS/project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec.
`iOS/scripts/generate-project.sh` fetches a pinned XcodeGen release (2.46.0)
into `.build/tools` and generates `iOS/Stillleaf.xcodeproj`, which is ignored
by Git. The app target depends on the repository's own `Package.swift` as a
local package.

Alternatives considered:

- **Committed `.xcodeproj`**: `project.pbxproj` merges badly across the parallel
  branches this repository runs, and it can only be edited reliably in Xcode.
- **Tuist**: capable, but a heavier toolchain with Swift manifests and a
  project-local runtime, for one app target and one test target.
- **SwiftPM-only app** (`.swiftpm`/Playgrounds): it has no supported path for
  asset catalogs, a privacy manifest, document types and `xcodebuild archive`
  in CI.

XcodeGen gives one reviewable YAML file, deterministic output, and the same
generation command in CI and locally. It needs no Xcode to *generate*, only to
build.

## Storage

All data lives in the app container under `Application Support/Stillleaf/`:

- `history.sqlite`: the Mac's exact schema, through `ReadingStore`.
- `Publications/<sha256>/`: imported editions (`publication.json` plus
  `resources/`), the same layout as on the Mac.
- `ReaderState/<sha256>.json`: reader position, preferences, bookmarks and
  annotations, validated by `ReaderStateStore`.

Book IDs match across platforms. An EPUB is `epub:<sha256 of its bytes>`, so the
same file imported on Mac and iPhone is the same journal book. Manual books are
`manual:<uuid>`. The iOS app stores no absolute cover paths, because container
paths change across reinstall and restore. Covers are read from the
publication's own cover image when drawn.

**v1 is local-only.** JSON export is the complete versioned archive the Mac
imports (duplicate-safe). JSON from the Mac imports on iOS: its books and
history appear, and its EPUBs become readable once the same files are imported.
CSV export writes the Mac's table set into a folder. SQLite backups are the
Mac's backup format, and restore validates the backup before replacing history.
Device backups (iCloud/Finder) include the container as usual.

## Reading-time rules on iOS

Time is credited only while **all** of these hold:

1. Tracking is on in Settings, and the book is not excluded.
2. The scene is `active` (foreground, unlocked, not covered by Control Centre,
   the app switcher or a call).
3. The reader is presented and the renderer has reported `ready` for this
   edition.

A one-second foreground timer feeds `TrackingEngine`, the same engine and
evidence as the Mac. Leaving `active` pauses immediately and checkpoints.
Nothing is credited in the background, and no background modes are requested.
If iOS suspends the app without a transition, the engine rejects the
monotonic-clock gap over five seconds, so no time is invented. As on the Mac,
there is no inactivity threshold: long pauses on one page count while the
reader stays in front. The system auto-lock is respected and never disabled.

Page coverage uses the renderer's authenticated `pageTurn` departures. They count
only forward, sequential turns while time is being credited, recorded as the Mac
records them. Position (`position` events) is saved independently of tracking.

## Privacy

- No network access. The reader's content rule list blocks every non-session
  URL, publication scripts are removed, and the app itself makes no requests.
- No accounts, analytics, advertising or third-party SDKs.
- No permissions requested. Import uses the system document picker, which needs
  no photo or file entitlement.
- App Store privacy label: **Data Not Collected**.

### Privacy manifest (`PrivacyInfo.xcprivacy`)

| Key | Value |
| --- | --- |
| `NSPrivacyTracking` | false |
| `NSPrivacyTrackingDomains` | none |
| `NSPrivacyCollectedDataTypes` | none |
| Required-reason API: `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1`: app-only settings |
| Required-reason API: `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1`: `systemUptime` measures elapsed reading time |
| Required-reason API: `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1`: size, type and identity checks of files inside the app container |

## App Store requirements checklist

- [x] Privacy manifest with the reasons above.
- [x] Export compliance: `ITSAppUsesNonExemptEncryption = NO`. SHA-256 is used
      only for content addressing, and there is no networking.
- [x] App icon: a single 1024 × 1024 opaque PNG rendered from the Pageleaf
      geometry (`iOS/scripts/generate-app-icon.swift`).
- [x] Launch screen: `UILaunchScreen` with a background colour asset; no
      storyboard.
- [x] Document type for `org.idpf.epub-container`
      (`LSSupportsOpeningDocumentsInPlace = NO`: files are copied in, then
      imported).
- [x] iPhone and iPad (`TARGETED_DEVICE_FAMILY = 1,2`), all orientations on
      iPad.
- [x] Built with the iOS 26 SDK (Xcode 26) in CI, as App Store Connect requires
      for 2026 uploads. Deployment target: iOS 17.0.
- [ ] Apple Developer Program membership, team ID and bundle ID registration
      (user).
- [ ] Privacy policy URL and support URL (needs the website domain).
- [ ] Screenshots: 6.9″ iPhone, plus 13″ iPad while iPad is supported.
- [ ] Age rating questionnaire (expected 4+), category Books, and the App Store
      description without Apple Books or Discord claims.
- [ ] Open-source notices for the bundled renderer (Readium BSD-3, DOMPurify,
      css-tree, OFL fonts), shared with the Mac distribution.

## Verification

- `.github/workflows/ios.yml` (macos-26 runner, newest Xcode 26): builds the
  renderer, generates the project, builds for the iOS Simulator and runs the
  `StillleafTests` XCTest bundle on a simulator. It runs on pushes to `ios/**`,
  on pull requests and manually.
- The tests cover ZIP extraction against hostile archives, import of synthetic
  EPUBs, journal operations, Mac-format JSON/CSV/backup round trips, tracking
  rules (foreground only, pause on inactive, gap rejection), the bundled
  privacy manifest and renderer, and an end-to-end reader test. That test
  opens a synthetic EPUB in a real `WKWebView`, waits for `ready`, turns pages
  and checks position and page-coverage evidence.
- Locally, with Command Line Tools only, `iOS/scripts/check-model-local.sh`
  compiles the platform-neutral iOS model against the macOS build of
  `BooksCore`/`BooksPlatform` and runs it. It also runs the existing
  `epub-import-smoke` suite through the portable ZIP extractor, so every
  hostile-archive case is checked against both extractors.

## Open decision: sync between Mac and iPhone

v1 ships local-only with manual export/import. Options for later:

| Option | Work | Running cost | Trade-offs |
| --- | --- | --- | --- |
| A. Manual JSON export/import (v1) | Done | None | Explicit and private; the user moves files |
| B. iCloud Drive snapshot files | ~1–2 weeks | None for you; uses the user's iCloud storage | Both apps write archives to a shared ubiquity container and merge with the existing duplicate-safe import. Coarse, last-writer timing, but simple. |
| **C. CloudKit private database via `CKSyncEngine` (recommended)** | ~3–5 weeks | None for you (private database counts against the user's iCloud quota); needs the paid Developer Program on both apps | Records map cleanly because history is append-only with UUIDs. Needs tombstones for deletions and a cross-device overlap policy (`ReadingStore` rejects overlapping intervals). The Mac app needs an iCloud-provisioned Developer ID profile. `CKSyncEngine` requires macOS 14, so the Mac minimum would rise from 13. |

Recommendation: ship v1 local-only, then build **C** for journal data and
reader state. Leave EPUB files per-device at first: identical files share IDs,
so history lines up without uploading books. Book-file sync via `CKAsset`
can follow if users ask.

## Other decisions for the user

- **Bundle identifier**: the default is `com.bookspresence.app`, the Mac's
  identifier, so a future Mac App Store build could use universal purchase.
  Change `STILLLEAF_BUNDLE_ID` in `iOS/project.yml` to use a separate one.
- **iPad**: included because SwiftUI adapts. It adds iPad screenshots and review
  surface. Set `TARGETED_DEVICE_FAMILY: "1"` for iPhone-only.
- **Inactivity**: kept identical to the Mac (no threshold; auto-lock ends a
  session). A phone propped open with auto-lock disabled would keep counting.
  A cap is a one-line policy change if you prefer one.
