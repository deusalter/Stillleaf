# Stillleaf offline EPUB reader: architecture decision brief

Research date: September 24, 2026. Proposal only. No dependencies installed, applications built or launched, source files changed, or live user data accessed. Primary documentation was checked during this investigation; engine capabilities below are upstream claims, not Stillleaf integration results.

## Recommendation

Add an optional built-in reader to Stillleaf's existing journal. Import a local EPUB, read it inside Stillleaf, resume where you stopped, and record eligible reading time automatically. Keep Apple Books and future verified reader connections as alternative sources, alongside manual logging. Core import, reading, search, storage and tracking should work with networking disabled, without accounts, catalogs or a hosted service.

Start with a **shared web EPUB component inside the existing native Mac shell**, isolated from application privileges. Compare Readium Web and epub.js in a small disposable evaluation, then choose one on measured results. Test the same component in Windows and both iOS and Android hosts before committing to an all-platform UI framework. Prefer Readium Web if the local-file pipeline and accessibility checks pass; epub.js is a practical comparison candidate with an explicit EPUB/CFI API. This is an evaluation order, not a claim that either already meets the requirements.

Use native Readium Swift/Kotlin readers as the mobile fallback if the shared component fails selection, accessibility or lifecycle acceptance. Preserve the Mac SwiftUI interface and BooksCore initially. A complete UI rewrite is disproportionate before proving reading quality. Phones are in scope for this investigation, superseding the earlier desktop-only expansion recommendation; neither phone OS has been selected for first release.

## Existing implementation and reuse

Observed in the shared checkout around commit `25383608ce10b21476bac9c915cfb69e51ab91ae`, with concurrent uncommitted UI work. That state may continue changing independently.

| Evidence inspected | Implication |
|---|---|
| `Package.swift`: macOS 13, Swift tools 5.8; `BooksCore`, `BooksPlatform`, native application targets | There is no existing multiplatform reader target. SwiftUI/AppKit screens and platform adapters cannot simply run on Windows/Android. |
| `BooksCore/Models.swift`, `TrackingEngine.swift`, `ReadingStore.swift` | Reuse interval credit, uncertainty, corrections, goals and transactional SQLite storage. Progress already has optional fraction/location fields. Archive version 1 is explicitly validated; new reader data needs deliberate versioning and migrations. |
| `TrackingEngine.navigationSignature` includes page, total, fraction and location | Simply injecting renderer relocation events can wrongly renew activity after reflow or restoration. Introduce navigation cause and eligibility before connecting events. |
| `BooksPresence/AppModel.swift`, `ReadingPresencePolicy.swift` | Orchestration/presence currently depends on an Apple Books reader receipt. Built-in reading needs its own document/lifecycle receipt; it must not require Accessibility permission or an open Books window. Preserve the existing external-reader gate. |
| `ReaderPagination.swift`, `PageTurns.swift` | Current page accounting is explicitly layout-sensitive. Do not reuse it as cross-device EPUB completion or normalize historical pages silently. |

The separate Windows prototype is at `/Users/abhinavnamboori/.codex/worktrees/affb/Apple Books RPC/prototypes/windows-journal/`. Its `package.json`, `src/main.cjs`, `src/journal.cjs`, and reader research were inspected. Electron owns native dialogs and disk access; a restricted renderer shows a manual journal. It stores JSON under its own application directory, with an archive explicitly incompatible with BooksCore. It has no reader or timer. Its recorded verification establishes Mac tests and Windows packaging, **not Windows execution**. The SumatraPDF experiment concerns saved PDF positions, not live EPUB activity. Preserve this prototype and its independent position/count/time semantics; it is not a production shared core. Verification handoff: `/Users/abhinavnamboori/Documents/Codex/2026-09-24/realtime-voice-chat-2/outputs/windows-prototype/VERIFICATION.md`.

## Engine shortlist and licensing

| Engine | Verified upstream scope | Fit and qualification |
|---|---|---|
| Readium Swift | iOS/iPadOS toolkit; reflow/fixed EPUB, preferences, RTL, search and highlight decorations; BSD-3-Clause | Strong native iOS candidate. Current package declares iOS and links UIKit: **not a drop-in AppKit macOS reader**. Pin a stable compatible release; develop currently requires a newer toolchain than Stillleaf's declared minimum. [Features](https://github.com/readium/swift-toolkit), [package](https://github.com/readium/swift-toolkit/blob/develop/Package.swift), [license](https://github.com/readium/swift-toolkit/blob/develop/LICENSE). |
| Readium Kotlin | Android toolkit with EPUB 2/3, pagination, scrolling, RTL, search and decorations; BSD-3-Clause | Strong Android candidate. Kotlin branding does not establish a Windows or shared desktop navigator. [Features](https://github.com/readium/kotlin-toolkit), [license](https://github.com/readium/kotlin-toolkit/blob/develop/LICENSE). |
| Readium Web / TypeScript toolkit | Web navigator, shared publication models and browser-frame injectables; BSD-3-Clause | Promising shared reader surface. Verify how a local EPUB becomes a publication and how its resources are served offline; do not assume navigator packages alone provide import, library, search UI or annotation persistence. [Repository](https://github.com/readium/ts-toolkit), [license](https://github.com/readium/ts-toolkit/blob/develop/LICENSE). |
| epub.js | Browser EPUB rendering, pagination, CFI/location and annotation APIs; two-clause BSD license | Practical small-scope comparator. Stillleaf supplies native import, persistence, UI and lifecycle. Book scripting is disabled by default; upstream explicitly warns enabling it weakens its sandbox. [Overview/security](https://github.com/futurepress/epub.js/blob/master/README.md), [API](https://github.com/futurepress/epub.js/blob/master/documentation/md/API.md), [license](https://github.com/futurepress/epub.js/blob/master/license). |
| foliate-js | Modular browser renderer, CFI/highlight/search components; MIT | Useful alternative, but upstream explicitly warns its API is unstable and targets recent browser engines. Its library license must not be confused with the separate Foliate application's license. [Scope/status](https://github.com/johnfactotum/foliate-js), [license](https://github.com/johnfactotum/foliate-js/blob/main/LICENSE). |

These licenses require retaining relevant notices; BSD-3 also contains a non-endorsement clause. Before selecting a dependency, record the pinned revision and licenses of its included dependencies, fonts and assets. The table covers the named libraries, not blanket permission for every bundled component.

## Platform architecture choices

| Path | Benefit | Cost / recommendation |
|---|---|---|
| Native shells, shared web reader | Keep Mac SwiftUI/BooksCore; embed reader in WKWebView. Windows can evaluate the existing Electron shell or a native WebView2 host. Mobile uses a packaged webview with native file/lifecycle services. | Best initial experiment. Share renderer and contracts; do not promise shared journal UI or Swift portability. WebKit and Chromium still need separate testing. |
| Native mobile Readium plus web desktop reader | Dedicated mobile navigation and platform integration; Swift journal reuse may be feasible on iOS | More renderer implementations and locator conversion work. Preferred fallback if mobile web reading quality fails. Android persistence/credit rules need a port or a proven shared-core bridge. |
| Shared application UI/core, e.g. Tauri | Potential reuse across Mac, Windows, iOS and Android | Rewrites current screens and introduces a Rust/native boundary. Different system webviews remain underneath. Consider only after reader evidence and a staffing/maintenance decision. [Tauri webviews](https://v2.tauri.app/reference/webview-versions/). |

Electron can preserve the Windows experiment, but is not the phone architecture. Avoid choosing a new Rust/C++ core or assuming Swift-on-Windows/Android interoperability is cheap. First share a versioned data contract and golden behavioral fixtures. Prove one Mac-to-other-platform archive round trip before deciding whether language-level core sharing beats small platform implementations. The existing Windows JSON format requires an explicit importer; relabeling it as BooksCore version 1 would be incorrect.

Proposed flow: **reader events / external adapter / manual entry → source arbitration and lifecycle eligibility → journal rules → durable store**. Renderer modules never own the history database. A single active source should receive automatic time credit; simultaneous windows or external readers must not double-count.

## Reader features and durable locations

MVP: DRM-free reflowable EPUB 2/3, local import, extracted metadata/cover, table of contents, chapter navigation and return from footnotes, keyboard/touch navigation, text-size/theme/spacing controls, saved position, bookmarks, eligible time, and portable backup. Search and highlights are feasible next features: they need local text extraction, selection/range anchoring, persistence and accessible result controls beyond the renderer APIs. Defer fixed-layout guarantees, scripted books, media overlays, read-aloud and other formats until independently validated.

Accessibility is a release criterion, not a checkbox inferred from engine choice: verify VoiceOver, NVDA and TalkBack reading order, heading navigation, focus after chapter changes, selection, contrast, zoom and reduced motion. Respect publisher structure while allowing readable overrides; font enlargement must not clip or lose text. Include RTL, complex scripts and vertical-writing samples in evaluation, but advertise only combinations actually tested.

Store a versioned locator containing publication fingerprint, resource href/type, engine-native anchor (CFI or equivalent), optional text context and progression. Readium's locator model provides resource references, location alternatives and text context; CFI identifies positions within an EPUB structure. Neither guarantees matching a revised edition. [Readium locator model](https://readium.org/architecture/models/locators/), [EPUB CFI specification](https://idpf.org/epub/linking/cfi/epub-cfi.html).

Retain original anchors when converting between engines. A reopened position should survive typography and viewport changes in the same publication; upgrades, sanitization and injected markup require regression fixtures. If exact restoration fails, offer a chapter/progression fallback and label it approximate. Cross-engine anchor equivalence must be demonstrated, not presumed from use of the same JSON fields.

## Honest tracking

Proposed event envelope: source/document/session identity, sequence number, monotonic receipt time, wall timestamp, locator, foreground/visible state, and navigation cause. Validate messages at the host boundary; deduplicate and reject stale/wrong-document events. Causes include sequential navigation, TOC/search jump, bookmark restore, reflow and programmatic relocation.

| Metric | Meaning and policy |
|---|---|
| Current position | Last durable locator. Navigation updates it, including backwards movement. |
| Progress percentage | Approximate location in this edition, with a versioned calculation. A jump updates position, not amount read. |
| Time | Inferred eligible time while the book is visible/active. Retain pause, uncertainty, lock/sleep and crash rules. No proof of attention. |
| Screen pages | Layout-dependent navigation, if shown. Do not sum with printed page labels or existing Apple Books pages as if equivalent. |
| Completion / rereading | Explicit completion and separately identifiable reading episodes. Reaching the end or importing a finished book creates no historical time. |

Use **time goals for built-in EPUB MVP** and show position separately. Keep historical/manual page counts with their provenance. Later normalized positions or content coverage need a defined algorithm and honest labeling; they are not printed pages or proof every word was read. Searching ahead, rotating a phone, resizing a window and reopening a chapter must credit zero pages. Long static reading may become uncertain without being discarded; screen-reader navigation must count as relevant interaction where observable.

On phones, checkpoint on lifecycle transitions, stop credit on background/lock, and never credit elapsed suspension as reading. Handle abrupt termination without relying on a final callback. External-reader availability is platform-specific: this investigation establishes no phone equivalent of the Mac Apple Books observer. Manual entry/import remains the fallback for unsupported connections.

## Offline import, isolation and storage

EPUB packages contain web content and may reference remote resources. “Local file” alone therefore does not ensure offline behavior. [EPUB specification](https://www.w3.org/TR/epub-33/).

Proposed import pipeline: user file picker → bounded staging copy → validate archive/package → fingerprint → atomically install managed original → store metadata and location. Import into app-owned storage so removing the source file or losing a file-provider permission does not break reading. Identical byte hashes can deduplicate copies; changed editions remain distinct, with optional explicit journal association rather than title-based merges.

Reject archive traversal, absolute paths, symlinks and excessive entry counts/decompressed sizes; bound XML parsing, images and fonts, and disable external entities. Keep book scripts disabled. Trusted reader code should run outside untrusted publication privileges. Deny remote subresources, frames, redirects, forms and network APIs at the host/resource layer as well as with content policy; block book access to general filesystem and native IPC. Expose only narrowly validated reader messages. EPUB content must never inherit the Windows journal preload API. Electron's official guidance supports sandboxing, context isolation, sender validation and navigation restrictions. [Security guidance](https://www.electronjs.org/docs/latest/tutorial/security).

Bundle reader assets and fonts; do not use a CDN, online conversion or automatic cover lookup. A scoped local resource handler is preferable; an engine requiring loopback serving needs per-book access control and no public network listener. Unsupported remote-dependent content should show a local explanation. External links can require deliberate opening outside the reader. Test zero outbound requests even with Wi-Fi enabled, not just airplane-mode functionality.

Keep original EPUBs in managed files, structured journal/locators/annotations in a transactional database, and search indexes/render caches rebuildable. Search text and highlights are private local data. Preserve existing history IDs and correction lineage through migration; distinguish deleting a downloaded book file from deleting its journal history. Do not access Apple Books' protected files to populate this library: import user-supplied readable EPUBs.

Offer a portable archive with a format version, checksums, metadata, locators, annotations, history and optional EPUB binaries. Validate into staging and preview conflicts before import. A journal-only export can remain available for smaller backups. Copying a live SQLite database with incomplete WAL files is not portability. Manual export/import or user-controlled file transfer is sufficient initially; automatic cross-device sync, conflict resolution and deletion propagation are separate future decisions.

DRM-free EPUB only is the proportionate MVP. An EPUB engine does not grant access to Apple, Kindle, Adobe or other protected purchases. Readium's LCP support has additional integration requirements, including a separately supplied client framework in Swift; do not equate the base BSD toolkit with ready-to-ship DRM support. [Readium LCP requirements](https://github.com/readium/swift-toolkit#building-with-readium-lcp). Handle encryption errors clearly; standard font obfuscation should not be misclassified as unsupported book DRM.

Optional Discord and public-cover lookup remain explicitly network-dependent integrations, separate from offline reading. Existing opt-ins should not become mandatory or silently switch on during reader import. Do not advertise the entire application as making no network requests when users have enabled those features.

## Phases and decision gates

1. **Contract and isolated evaluation.** Pin two candidate engines; compare a representative DRM-free corpus on Mac, Windows, iOS and Android with disposable data. Prove import, offline resource loading, reflow-safe resume, TOC/footnotes, screen-reader navigation, remote-resource denial, large-book memory use and lifecycle events. This gate selects renderer architecture, not every future feature.
2. **Mac vertical slice.** Add one reading window to the existing shell, native import, bookmarks, durable locators, time tracking and archive migration. Test coexistence with Apple Books and manual mode. Coordinate with active Mac UI/history owners before source work.
3. **Platform slices.** Reuse the selected reader component on Windows and test on real Windows; assess both phone hosts, then choose release order from device availability and results. If needed, substitute Readium Mobile behind the same journal contract. Prove portable archives and equivalent lifecycle/credit fixtures before claiming parity.
4. **Polish after evidence.** Add highlights/search, accessibility fixes, broader EPUB coverage and release signing/install flows. Make sync, DRM and additional formats separate scoped decisions.

Major risks: untrusted publication isolation; cross-engine locator drift; malformed/complex EPUB typography; mobile selection/accessibility; double credit from multiple sources; incompatible archive migrations; and accumulating several implementations before the reader is validated. There is no evidence here for universal EPUB or external-reader support, and no reliable delivery estimate without the first evaluation.

No user decision blocks this research. Before implementation, choose first shipping platform after Mac, confirm local transfer is sufficient initially, and agree on time-based built-in-reader goals. Defaults recommended here are both phones evaluated, no sync requirement, and time plus durable position. Application code and ongoing UI/session fixes remain owned by their existing tasks.
