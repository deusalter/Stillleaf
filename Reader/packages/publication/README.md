# Stillleaf publication import foundation

Engine-independent EPUB inspection and managed-copy import. This package performs no network operations and does not open a reader, record reading time, set file associations, modify the source EPUB, or mutate existing Stillleaf journal data.

**Verification:** 38 synthetic Node tests pass on macOS; the current pinned dependency audit reports zero vulnerabilities. Windows filesystem/runtime behavior is not yet verified on Windows hardware. This is a bounded import foundation, not a security certification or EPUB-conformance validator.

## API

```js
import { importEPUB, inspectEPUB, PublicationError } from "./index.js";

const result = await importEPUB(sourcePath, appOwnedPublicationRoot, {
  signal: abortController.signal,
  // Optional bounded policy overrides; defaults normally suffice.
  // limits: { archiveBytes: 128 * 1024 * 1024 }
});
// result.status === 'imported' | 'duplicate'
// result.editionId: SHA-256 of the exact copied original EPUB bytes
// result.directory: absolute committed edition directory
// result.publication: metadata below

const metadata = await inspectEPUB(sourcePath); // read-only metadata inspection
```

`inspectEPUB` checks ZIP metadata/local headers and reads/checksums the container, OPF, and mimetype. It does **not** inflate/checksum every book resource. `importEPUB` additionally verifies all extracted resource sizes/CRCs before publishing. Inspection of an independently changing source path is advisory; import uses its own bounded, hashed snapshot and inspects that snapshot.

Metadata contains `formatVersion`, `epubVersion`, `layout`, nullable `title`, `creators`, `identifiers`, `languages`, `opfPath`, `spine`, `manifest`, and nullable `cover`. Manifest/spine items contain canonical archive-relative `path`, `id`, `mediaType`, and `properties`; spine items add `linear`. A cover is `{path, mediaType, provenance: 'epub-metadata'}` and comes only from EPUB 3 `cover-image` or EPUB 2 `meta name="cover"` declarations. A random manifest image is never selected. Missing cover means a local placeholder downstream, never a lookup.

`PublicationError.code` provides policy errors (`PATH`, `REFERENCE`, `PROTECTED`, `CHECKSUM`, `ENTRY_SIZE`, `ARCHIVE_SIZE`, `TOTAL_SIZE`, `RATIO`, `ENTRY_COUNT`, `HEADER`, `COMPRESSION`, `FILE_TYPE`, `MIMETYPE`, `CONTAINER`, `OPF`, `MISSING`, `XML`, `STORAGE`, `SOURCE`, `LIMITS`, `BUSY`). Filesystem, ZIP-library and cancellation errors can also propagate; callers must handle general failure instead of assuming every exception is a PublicationError.

Imports do not mark a book as read. The host adds or focuses its single Library after results, then begins reading only after an explicit user action. Exact-byte duplicates return the already committed edition; host-level work/book matching and history preservation belong outside this package.

## Storage contract

```text
<app-owned root>/
  .staging/import-<random>/       # temporary private snapshot/extraction
  .locks/<sha256>/               # cooperating importer lock
  editions/<sha256>/
    original.epub               # usable complete managed copy
    publication.json           # schemaVersion 1, editionId, publication
    resources/...              # validated archive paths
```

The original selected file is read only and left untouched. The managed EPUB remains a usable standalone file; a future Keep EPUB removal operation must export/reveal it before removing its app index. This package implements **no deletion UI or book removal**. It does not delete any committed edition or external source.

The importer snapshots the source, scans every central entry and local header before any inflation, validates container/OPF, acquires the edition lock, extracts with streaming bounds and CRC checks, writes a receipt, and atomically renames the staged directory into `editions`. The staging and destination directories are on the same filesystem. A duplicate is returned only after a bounded SHA-256 verification of the stored original against the source-derived edition ID, without overwriting existing content. A damaged managed original returns a storage error, preserving both the source and the damaged edition for explicit recovery. Missing/corrupt receipts and symlink edition destinations fail rather than being replaced. A concurrent identical import returns `BUSY`; use the host's serial import queue or retry after the active import completes.

Ordinary failures/cancellation remove partial stage files and release the lock. Cleanup failures propagate honestly; callers should expose a secondary storage error and offer diagnostics rather than claim a clean rollback. Hard process termination/power loss may leave staging directories or locks. **No crash-recovery sweeper is included**; a future recovery procedure must verify no live importer owns them before removing only stale staging/locks. Rename provides atomic visibility, not an fsync-backed power-loss durability guarantee. The app database transaction/reconciliation with committed receipts remains host work.

The caller must supply an app-owned root whose ancestors cannot be modified by an untrusted actor. Existing managed child roots and edition directories are checked against symlinks, but this does not implement OS-specific directory-descriptor traversal or protection from a concurrent privileged local attacker swapping ancestors. Source `lstat` and read are also separate operations; the snapshot/hash binds the bytes actually copied, not a claim that the external file cannot change concurrently.

## Enforced bounds and policies

| Default                        |           Limit |
| ------------------------------ | --------------: |
| Compressed source archive      |         128 MiB |
| ZIP entries                    |          10,000 |
| One inflated entry             |          32 MiB |
| Sum of declared inflated sizes |         512 MiB |
| Per-entry expansion ratio      |           200:1 |
| Container/OPF XML              |      1 MiB each |
| Canonical path                 | 512 UTF-8 bytes |
| XML tag count / lexical depth  |    20,000 / 128 |

Entry counts, declared byte totals and ratios are checked **before** opening any entry stream. Actual entry output is bounded by both declared size and configured cap; CRC32 verifies contents. Archive snapshot copying is also capped. Counts/limits must be positive safe integers. These are conservative product policy values, not EPUB spec limits.

Rejected inputs include:

- Traversal, absolute/drive/UNC paths, backslashes, percent-encoded archive names, ambiguous Unicode normalization, controls, Windows-reserved names/characters and trailing spaces/dots.
- Duplicate/case-colliding entries, file-versus-parent conflicts, symlinks/special entries, overlapping entries and inconsistent local/central names/flags/methods/sizes.
- ZIP encryption, unsupported encryption.xml methods/structure, and rights.xml markers. Standard IDPF font obfuscation is supported for manifest-declared font resources only; other methods remain unsupported.
- Compression methods other than stored/deflate, invalid mimetype placement/content, multiple supported rootfiles, missing manifest resources, invalid spine/cover declarations.
- External/protocol references in OPF, root-escaping references, encoded traversal, DTD/entity declarations and malformed metadata XML. Legitimate `../Images/cover.png` references remain allowed when they stay inside the archive; percent-encoded spaces resolve to actual names.

These policies intentionally reject some legitimate unusual EPUBs (non-UTF-8 name encodings, UTF-16 XML, ZIP64 local-header variants, deeply nested metadata, unsupported protected fonts, excessive compression, remote OPF resources, multiple renditions). Return a clear unsupported/import-failed result; do not silently drop chapters or fetch missing resources.

**Content is not sanitized.** XHTML/CSS/SVG are extracted as publication bytes. They can contain scripts, remote URLs, embedded frames, hostile images or CSS. The renderer/native host must still deny publication scripting, navigation and external loads, isolate book origins/resource maps, constrain image/font decoding and enforce media budgets. The cover field is a metadata designation, not certification that its image bytes are safe to render.

## Platform boundaries

- `path-policy.js` is pure JavaScript policy (TextEncoder only), with no Node I/O or renderer dependency.
- `metadata.js` takes a bounded `readResource(name, cap)` callback plus available resource names. It depends on xmldom and pure path policy, not Node filesystem APIs. This permits future worker/bridge reuse, but no WKWebView bundle or Swift bridge has been built here.
- `index.js` uses Node filesystem, streams, crypto and yauzl. It can serve a Windows Node/Electron host; it is **not** drop-in Swift code and does not require or bundle Node into the current Mac app. A native Mac importer must implement the same validated archive/storage contract or provide a separately reviewed bridge.

## Tests and dependencies

```sh
npm ci --ignore-scripts
npm test
npm audit
```

Synthetic ZIP fixtures are constructed locally in temporary test directories, including invalid headers and corrupt CRCs. Tests cover valid EPUB 2/3, explicit cover/no cover, hashes, untouched originals, duplicate outcome, traversal/encoded/absolute paths, symlinks, encryption, ZIP header mismatch, bombs, lying sizes, OPF references, XML failures, partial-extraction cleanup, pre-abort, incomplete existing destinations, managed-directory symlinks and damaged managed-original duplicate rejection. `test-results.txt` and `audit.json` retain this run's evidence.

Runtime pins: `yauzl@3.4.0` (MIT), `@xmldom/xmldom@0.9.12` (MIT). Formatting-only development pin: `prettier@3.9.9` (MIT). Lockfile included. Audit0 is a current advisory scan, not a blanket guarantee. No shell unzip and no runtime fetch are used.

Primary references: [yauzl API/security design](https://github.com/thejoshwolfe/yauzl), [xmldom parser](https://github.com/xmldom/xmldom). The implementation was checked against the exact installed pinned source. Fuzzing, broader real EPUB corpora, disk-full/permission fault injection, crash recovery, native platform verification and hostile-rendering tests remain required before release.

Fixed-layout detection preserves EPUB 3 rendition layout metadata and spine overrides plus clear EPUB 2 fixed-layout/Apple display-options hints as `layout: "pre-paginated"`. The host passes this to the renderer for an explicit unsupported result until fixed-layout rendering is implemented; it must not silently reflow declared fixed-layout books.

Navigation metadata is additive: optional `toc`, `landmarks`, `pageList` contain Readium-style `{href,title,children?}` links. EPUB3 XHTML nav supports nested lists and namespaced `epub:type`; EPUB2 uses the spine-referenced NCX (or one unambiguous NCX), plus OPF guide landmarks. Target paths resolve relative to the navigation document, retain fragments, and must reference local manifest resources. External, root-escaping, ambiguous encoded traversal, query-bearing, missing-resource and invalid fragment references reject import. Existing XML UTF-8/DTD/entity/tag-depth safety also applies. Navigation input is capped at2MiB,10000 links,32 nested levels,16KiB titles,8KiB target URLs and4KiB fragments. Heading-only groups flatten to their children, matching the native importer. Optional `readingProgression` accepts ltr/rtl/default. Older metadata/receipts without these fields remain valid. The desktop reader-input adapter passes these fields and languages through; no renderer rebuild is required for this parser change.

## Standard font obfuscation

The importer accepts the IDPF `http://www.idpf.org/2008/embedding` font method described in [EPUB 3.3](https://www.w3.org/TR/epub-33/#sec-font-obfuscation). It derives the transient SHA-1 key from the selected unique identifier after removing only XML whitespace, then XORs the first1040 extracted font bytes. The original EPUB, source file, edition SHA256 and remaining font bytes stay unchanged. ZIP CRC verification precedes decoding. The key is not persisted in receipts.

Only the explicit font MIME allowlist is accepted. Unknown algorithms, non-font references, unsafe/missing/duplicate targets, malformed XML, transforms, missing/ambiguous identifiers and DTDs reject the import. Existing archive budgets and atomic staging remain in force. Tests use an independent SHA-1 known vector, short/boundary/long resources and split stream chunks. This is import-byte verification, not a claim that every font format renders correctly in every platform.
