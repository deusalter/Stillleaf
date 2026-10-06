# Stillleaf: a standalone desktop reading journal

Research snapshot: September 24, 2026. Recommendation only; no application changes, website deployment, reader installation, or live integration tests performed. Inspected local checkout at `54cf337b12a12de4f49d13a7beca09180523b120` with ongoing uncommitted UI work, which was preserved. External evidence below is primary documentation retrieved during this task. Published capabilities are distinguished from tested local behavior and proposed work.

## Recommended direction

Make Stillleaf a complete reading journal that works before the user connects anything. Users add books, organize their reading, record progress and sessions, reflect, and view their history. Reader connections optionally reduce data entry. Discord is an optional sharing destination. The download website introduces this product clearly and delivers a trusted installer directly.

Recommended sequence: public Mac distribution and website; a fully independent journal experience on Mac; an adapter boundary and one additional Mac reader; a Windows feasibility prototype followed by a manual-first Windows journal; further reader connections according to demand and verified capabilities. Mobile and hosted community remain separate future decisions.

## What Fable demonstrates—and what it actually supports

Fable combines reading organization, habit tracking, reflection, discovery and community. Its official overview describes reading-status lists, custom lists, notes, feeds, direct messages and clubs. Its product site emphasizes personal statistics, monthly recaps and spoiler-separated discussions. These make a reading history feel useful between reading sessions. [Fable overview](https://help.fable.co/article/11-what-is-fable), [product site](https://fable.co/).

The platform picture is more nuanced than “mobile-only”:

| Surface | Evidence and limits |
|---|---|
| Mobile apps | Official listings establish Android and iPhone/iPad distribution. The Apple listing has iOS/iPadOS 17 compatibility, plus Apple Vision; it does not list Mac compatibility. No native Windows release was verified. These are listing checks, not installed-app tests. [App Store](https://apps.apple.com/us/app/fable-track-discuss-books/id1488170618), [Google Play](https://play.google.com/store/apps/details?id=co.fable.fable) |
| Ebook reading and club participation on desktop | Fable's published help explicitly says these are unavailable on the web and require a phone/tablet. That article was last updated November 6, 2024: it remains their published answer, but authenticated current behavior was not independently tested. [Desktop support answer](https://help.fable.co/article/91-can-i-read-books-on-my-laptop-can-i-access-my-club-discussion-on-a-computer) |
| Website | Public book/club discovery pages and a web Goodreads CSV import exist. Public club pages do not establish browser discussion participation or full tracker parity. [Website](https://fable.co/), [CSV import help](https://help.fable.co/article/131-can-i-import-my-goodreads-data-from-a-csv-file) |
| Desktop browser extension | Fable documents a Chrome beta that adds books from book pages to lists after website sign-in. This is a useful desktop workflow, not evidence of a full desktop journal or live reader tracker. [Extension help](https://help.fable.co/article/133-browser-extension) |
| Connected reading | Fable's May 27, 2026 help says linked Everand reading/listening activity automatically updates in Fable. This is a specific partnership, not evidence of a public integration API for Stillleaf. [Sync help](https://help.fable.co/article/191-do-my-everand-books-and-activity-sync-to-fable) |

Use Fable's patterns selectively: clear Want to Read / Reading / Finished / Did Not Finish states; reread history; optional goals; thoughtful book pages; easy progress entry; private notes/reviews; shareable recaps. Fable's listing also documents progress by page or percentage and editable past streaks. Stillleaf should preserve its own explicit correction history when adopting friendly editing. [Fable app description](https://apps.apple.com/us/app/fable-track-discuss-books/id1488170618).

The strongest proposed distinction is a keyboard-friendly desktop journal, usable offline without an account, with local ownership of history and optional connections whose capabilities are visible. This is a product hypothesis, not demonstrated market demand or a claim that Fable lacks all these qualities. Validate it with desktop readers before a major rewrite.

Community can initially mean exported reading recaps, copied reviews, links to existing clubs, and optional Discord presence. A native feed, clubs, comments or messaging would require accounts, hosting, permissions, moderation, reporting/blocking, deletion and ongoing operation. The user's interest in Fable does not authorize building that infrastructure. A small private buddy-reading experiment could be evaluated later, separately from a public social network.

## What the repository already provides

| Area | Observed implementation | Expansion implication |
|---|---|---|
| Core | `Sources/BooksCore/Models.swift`, `TrackingEngine.swift`, `ReadingStore.swift`: Foundation value types, SQLite, automatic/manual/imported modes, intervals, corrections, progress, goals, merges and archives | Strong reuse candidate. No Windows compilation was attempted; Foundation behavior, SQLite linkage, files and dates still need testing. |
| Identity | Apple Books IDs are namespaced `apple-books:...`; new manual books use UUID identities. `BookRecord.source` is a string. | Preserve stable identities and existing history. Add structured connection identity rather than equating matching titles. |
| Manual reading | `AppModel.tick()` processes a manual book before Accessibility and Books-foreground gates. `startManual`, `stopManual`, `addManual`, page adjustments and ratings already exist. | Independence is real at the logging level, though orchestration still polls Books-related services. |
| Manual limitations | Manual sessions still pass through shared lock/display/pause and uncertainty logic; `apply()` uses elapsed system input activity when no navigation token exists. | Paper readers can go idle at the computer while reading. A useful standalone timer needs an explicit policy for idle time, lock/sleep and later confirmation. |
| Native shell | `BooksPresence` uses SwiftUI and AppKit; `AppModel` mixes orchestration, settings, dialogs, imports and platform calls. | Windows requires a new UI/shell and substantial orchestration separation. |
| Reader/system services | `BooksCapture`, `BooksWindowObserver`, `BooksReaderWindow`, `SystemEligibility` depend on Accessibility, AppKit and CoreGraphics; login uses ServiceManagement. | Separate reader evidence from foreground/session/power monitoring and startup services. |
| Other platform dependencies | `CoverCache` uses AppKit/CryptoKit; `SingleInstance` uses Darwin. Local build targets macOS and dylibs. | Port image handling, paths, instance locking, runtime packaging and CI too. |
| Discord | `DiscordPresence.swift` uses Darwin Unix sockets. `AppModel.publishPresence()` and `ReadingPresencePolicy.state()` require a verified open Books reader, even for manual mode. | Manual logging independence does not imply standalone Discord sharing. Windows needs named pipes and a deliberate manual-sharing policy. |
| Distribution | `scripts/package-app.sh` signs ad hoc and creates a host-architecture ZIP. `.github/workflows/macos.yml` builds/tests on macOS and uploads a development artifact. | No public signed/notarized release pipeline is established by these files. Current external release state was not audited. |

The implementation is more current than parts of `docs/INTERFACES.md`: that document still describes exact-document-only identity and temporary missing-window presence retention. Current code and `docs/CAPABILITIES.md` include a Books 8.0 structural fallback, and current presence code hides on reader closure. Resolve that documentation drift in a future implementation task.

## The independent journal experience

Suggested first-run flow: create a book or import a history file, then optionally connect a reader. Request Accessibility only for connections that need it. A person logging paper books should not encounter Apple Books failures or have to configure Discord.

Minimum coherent product additions beyond today's timer/history UI:

- Persistent reading-status shelves, a book detail page, reread episodes, and optional private notes/reviews.
- A quick entry such as “read to page 84 today” or “read 25 pages,” with duration optional. Current session page adjustments are not a complete standalone progress-entry model.
- Explicitly distinguish current position, pages read, completion, and time. Moving backwards, rereading, changing editions or importing finished books must not fabricate session time or page counts.
- Reuse an existing book when adding a record; resolve duplicate identities explicitly. Support custom books without a catalog match.
- Make uncertainty review and correction understandable. Recommend a user-started manual timer with a visible stop control and explicit treatment of long idle/lock periods; do not silently infer attention from unrelated keyboard use.
- Keep JSON/CSV export and local backup prominent. Imports should preview mappings/conflicts; import completion dates without inventing daily activity. Existing JSON is an archive format, not a general Goodreads/Fable importer.

A pure manual mode is worthwhile on both operating systems and supports paper, e-readers and unsupported apps. Recommend no account requirement initially. If cross-device sync is later requested, design conflicts, deletion propagation and privacy explicitly; copying SQLite files between active installations is not a sync design.

For Discord, preserve current automatic-mode behavior: a verified reader must remain open. Offer a separately explicit “share this manual session” control only if the user chooses that product behavior, with stop/expiry rules. Never require an unrelated Apple Books window to legitimize paper-book sharing. A shipped Stillleaf application ID could remove developer-portal setup friction, but validate that ID and rendering with unrelated Discord accounts before advertising one-toggle setup. The app ID is not a user token; no account token should be requested. [Discord RPC](https://docs.discord.com/developers/topics/rpc).

## Reader connections: capability-specific, not universal

Show what each connection supplies: library metadata, saved progress, live reader identity, observed navigation, completion, or import only. A saved position is not live activity. A deep link is not an event stream. “Connected” must never imply all capabilities.

| Reader/source | Realistic connection | Evidence status and next step |
|---|---|---|
| Apple Books / Mac | Existing read-only private catalog plus bounded Accessibility observation | Implemented, limited to documented local evidence. `docs/CAPABILITIES.md` reports one Books 8.0 EPUB layout and rejects ambiguity; other layouts/versions are not established. Do not advertise all Apple Books formats or device sync. |
| Skim / Mac PDFs | AppleScript metadata/position adapter, if its installed dictionary exposes the necessary read properties; foreground/window verification separately | Official help confirms scriptability, not all required property semantics. First candidate for a bounded probe of document identity, active page, multiple windows and Automation permissions. [Skim help](https://skim-app.sourceforge.io/manual/SkimHelp_45.html) |
| calibre / Mac and Windows | Library/book association and documented opening links; investigate a supported plugin or cooperative integration for live position | Official URL scheme opens a library book at a location; viewer remembers position. Neither proves a supported subscription to live reading events. Probe viewer interfaces before promising automatic tracking. [URL scheme](https://manual.calibre-ebook.com/url_scheme.html), [viewer manual](https://manual.calibre-ebook.com/viewer.html) |
| Thorium / Mac and Windows | Investigate upstream cooperation or bounded accessibility metadata; possible explicitly supported import later | EDRLab documents a cross-platform reader and saved position. No public live activity API was established by this research; OPDS catalog/lending support is not reading telemetry. [Thorium](https://www.edrlab.org/software/thorium-reader/) |
| Preview / other PDF apps | Version-scoped Accessibility probe, if trustworthy document identity and page metadata exist | Not tested here; no reliable integration is promised. Use manual journaling until proved. |
| Kindle, Kobo and other proprietary readers | Manual logging initially; user-provided supported exports/imports if verified for each vendor | This research establishes no general live third-party API for these readers. Do not infer one from Fable's Kindle list-import feature or attempt DRM extraction. Prioritize based on user demand before deeper vendor-specific research. |
| Fable | Manual reference/link and user-controlled import only if a documented export becomes available | No public Stillleaf integration API or usable export contract was verified. Fable's Goodreads importer is not evidence of a Fable exporter. |

Windows UI Automation exposes other apps' controls, making observation plausible, but the controls each reader supplies determine success. It cannot guarantee stable book identity or pages. [Microsoft UI Automation](https://learn.microsoft.com/en-us/windows/win32/winauto/entry-uiautocore-overview).

Proposed internal boundary: a reader adapter returns source identity, namespaced book identity, capture timestamp, reader-window receipt, optional position with units/layout identity, evidence quality and health/capabilities. Platform services provide clock, foreground, session/power state, paths, startup and transport. The journal owns user entries and the core owns crediting/storage. The app coordinates these parts rather than calling Books directly throughout its model.

Preserve adapter-specific pagination: EPUB locations, percentages and PDF page indexes are not interchangeable. Add fixture tests for book switches, stale observations, library-only windows, duplicate titles, reflow and missing controls; require live checks for each advertised reader/version. Imports never establish present-tense Discord activity.

## Website and public delivery

A small static site is sufficient: product overview, real screenshots, one prominent Mac download, supported OS/CPU information, installation help, optional reader-connection instructions, privacy/data policy, changelog and support contact. Provide visible platform choices; label Windows as planned until there is an actual release. Use semantic HTML, keyboard navigation, sufficient contrast and reduced-motion support.

GitHub may host the binaries behind a direct download button, so users never navigate a repository. GitHub documents direct latest-release asset links. Prefer a version-pinned link and release metadata published atomically; a latest link is useful only with consistent asset names. CI artifacts alone are not the public release experience. [GitHub release links](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases).

Before public download: establish Developer ID signing, hardened-runtime configuration, notarization, stapling, versioned artifacts/checksums and clean-machine install/upgrade checks. Apple documents these as the supported direct-distribution path. Its developer membership currently costs USD 99/year, with regional differences and some waivers. [Developer ID](https://developer.apple.com/developer-id/), [membership](https://developer.apple.com/programs/enroll/).

Decide whether to ship separate Apple Silicon/Intel binaries or a tested universal build; the current script emits only the build host's architecture. Preserve bundle identity and data paths for upgrades. Test permission behavior across an update, not just first launch. A manual download/update flow can ship before an automatic updater. Domain, hosting and bandwidth depend on the selected provider; no paid service is necessary to choose during this research.

## Windows: feasible, but a new platform project

Swift is officially available on Windows, including x86_64 and ARM64 tooling. That supports investigating core reuse; it does not bring this AppKit/SwiftUI shell to Windows. [Swift Windows installation](https://www.swift.org/install/windows/).

| Approach | Benefit | Cost/constraint | Recommendation |
|---|---|---|---|
| Keep Swift core; new Windows UI such as WinUI | Preserve mature journal semantics and the native Mac app | New UI; Swift/C#/C++ boundary or local helper protocol; runtime and SQLite deployment; Windows lifecycle adapters | First feasibility spike if native desktop quality is central. Prove core compilation and one complete save/reopen/export flow before committing. |
| New Windows implementation with compatible archives | Idiomatic Windows development | Duplicated business logic and migrations; regression risk in corrections/timezones/recovery | Consider only if bridging costs exceed maintaining two implementations; share fixtures and archive specifications. |
| Cross-platform shell such as Tauri | Potential UI reuse across future desktop targets | Existing SwiftUI screens are rewritten; Rust/web tooling, WebView2, adapter/sidecar boundary and packaging added | Credible strategic option if shared UI is a priority, not a cheap wrapping of the current app. |
| Browser/PWA journal | Broad access to manual forms and summaries | A website alone cannot reuse the current native observer/socket implementation; desktop integration needs a helper/extension; offline lifecycle and sync become separate design work | Later companion candidate, distinct from the download site. |

Microsoft documents WinUI support for C# and C++ and Windows App SDK lifecycle/deployment services. Tauri documents its C++ build dependencies and WebView2 runtime on Windows. [Windows App SDK](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/), [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/).

Windows work includes UI accessibility, tray behavior, DPI, sleep/lock/resume, clock semantics, local paths/permissions, cover decoding, file dialogs, single instance, startup, SQLite packaging, updater/installer, and CI. Discord documents Windows named-pipe IPC versus Unix paths on macOS; the payload logic can be reused conceptually, but the Darwin transport cannot. [Discord transport](https://docs.discord.com/developers/topics/rpc).

Budget for Windows test hardware or VMs, signing and maintenance as well as initial development. Microsoft currently documents free Store signing for MSIX submissions; MSI/EXE Store submissions require publisher signing. For direct distribution its comparison lists Artifact Signing at approximately USD 9.99/month with identity/geographic eligibility, and warns that signing does not instantly remove reputation warnings. Recheck eligibility and pricing when choosing distribution. [Microsoft signing options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options).

No reliable delivery estimate is justified before the core/UI packaging spike. Manual-first Windows reduces reader-integration uncertainty, but does not eliminate these platform costs.

## Phases and completion gates

1. **Public Mac release and download site.** Gate: signed/notarized artifact opens on a clean supported Mac, upgrades preserve history, download works without GitHub navigation, and website claims match tested capabilities.
2. **Independent journal on Mac.** Gate: with Books absent and Accessibility denied, a person can create/reuse books, manage statuses, log progress and past sessions, review history and export it. Resolve paper-timer semantics and manual sharing explicitly.
3. **Adapter separation and one new Mac connection.** Start with a Skim probe, or calibre if user demand strongly favors EPUB. Gate: documented capabilities, ambiguity/staleness tests and live reader checks; disconnecting never destroys journal history.
4. **Windows feasibility, then a manual journal beta.** Gate the stack choice on a working core/storage/UI/installer slice. Beta must pass cross-platform archive and timezone/correction fixtures plus lock/sleep/recovery checks. Reader connections can follow without making Windows usefulness depend on them.
5. **Selective additional connections and sharing.** Choose by demand and maintainability. Consider exported recaps before hosted community. Mobile remains outside this roadmap.

Mobile manual journaling is plausible as a future client, but automatic cross-app observation cannot be assumed: Apple's iOS sandbox confines access to explicitly provided services. Reader partnerships/imports or an owned reader would be different approaches. [Apple runtime security](https://support.apple.com/en-ca/guide/security-pdf/sec15bfe098e/web).

## Decisions still needed before implementation

- Which reading audience comes first: paper/e-reader journal users, Mac ebook readers, or Windows readers? This determines whether journal depth or a second adapter comes first after distribution.
- Is preserving native UI on each desktop platform worth maintaining two shells, or is a shared UI the long-term priority?
- Should a manual timer keep running when the computer is idle or locked? How should users confirm that time, and should manual Discord sharing be offered?
- Should the first expanded journal include private notes/reviews and shelves, with community limited to user-initiated sharing? A hosted social product needs a separate scope decision.
- Is local storage with explicit export sufficient initially, or is Mac/Windows sync a launch requirement? The latter materially expands the project.
- Who owns the release identity, domain and signing accounts? What pricing/open-source policy and supported CPU/OS matrix should the public site state?

These are implementation decisions, not blockers to the research recommendation. No deployment or platform work has begun.
