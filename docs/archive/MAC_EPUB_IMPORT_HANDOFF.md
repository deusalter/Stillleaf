# Native EPUB import foundation

Implemented in `Sources/BooksPlatform/EPUBPublicationImporter.swift` and `Sources/BooksCore/EPUBPublication.swift`.

## API and storage

- `EPUBPublicationImporter(directory: URL, limits: Limits = Limits())`
- `importPublication(from: URL) throws -> EPUBPublicationImportResult`
- `loadLibrary() throws -> [EPUBPublicationImportResult]`
- Result: `publication`, `directory`, `alreadyImported`.
- Publication: `id` (SHA-256 original bytes), `title`, `authors`, `packagePath`, `resources` (id/path/mediaType), `spine` (ordered package-relative paths), `coverPath`, `warnings`.
- Layout: `<managed root>/<sha256>/original.epub`, `resources/<package paths>`, `publication.json`.
- Swift receipt uses `id`, unlike cross-platform proposed `editionId`; host adapters must translate. This importer does not claim journal/archive schema compatibility.
- Import serializes within each importer instance. The host must keep one importer per managed root and perform calls off the main thread. Different processes are not coordinated.
- Root creates a private staging directory, streams a bounded original copy while hashing, validates/extracts it, writes receipt, then atomically renames staging to the final edition directory. Failed imports remove staging. Original source is unchanged.
- Existing duplicates and library receipts validate bounded metadata, resource references/existence and reject resource-parent/file symlinks. They do not rehash all extracted resources at every launch; managed storage is assumed app-private.

## Safety and current limitations

Raw central-directory preflight checks local headers, duplicate names, component case/Unicode aliases, links via libarchive, nonportable Windows names, absolute/traversing/backslash paths, encrypted flags, supported ZIP methods, entry counts, resource/total expansion bounds and 1000:1 maximum per-resource declared ratio. Raw validation is necessary because the installed libarchive normalizes backslashes. Native extraction independently checks paths/types and actual bytes expanded. Defaults: 128 MiB original, 256 MiB expanded, 32 MiB resource, 10,000 entries. XML metadata capped at 2 MiB, UTF-8 only, DTD/entity declarations rejected and external entity resolution disabled. Titles/authors are bounded.

ZIP64, split archives, non-UTF-8 entry names, unsupported compression methods, percent-literal resource names, relative `..` manifest references, ZIP encryption and unsupported resource-encryption methods remain unsupported. Standard IDPF font obfuscation is supported for exact manifest-declared font resources: only the staged extracted font prefix is decoded; the original EPUB and edition hash stay unchanged. Strict filename rules may reject otherwise valid EPUBs; errors are visible and originals remain available. XML package parsing is a bounded metadata extractor, not complete EPUB conformance validation. XHTML/CSS/SVG remain **untrusted originals** in managed resources: importer does not sanitize publication content and must not be treated as the reader security boundary. Host must sanitize content and deny external network requests before rendering. Import itself performs no network operations.

Cover selection uses only manifest `cover-image` or EPUB2 explicit cover metadata and permitted raster media types. No guessed image, online fallback, or SVG cover. A declared image is not decoded by the importer; native CoverCache must bound/decode before display.

System libarchive is dynamically loaded from `/usr/lib/libarchive.2.dylib` through explicit C calling-convention function bindings. Installed SDK exposes its library stub but no headers. No shell extraction, added npm dependency, Package.swift dependency, linker flag or C shim is required. Existing glob-based builds pick up the Swift files.

## Verification

Executed on macOS with the Command Line Tools compiler, in separate `.build/mac-import` output:

```sh
swiftc -emit-library -emit-module -module-name BooksCore Sources/BooksCore/EPUBPublication.swift -emit-module-path .build/mac-import/BooksCore.swiftmodule -o .build/mac-import/libBooksCore.dylib
swiftc -emit-library -emit-module -module-name BooksPlatform -I .build/mac-import -L .build/mac-import -lBooksCore Sources/BooksPlatform/EPUBPublicationImporter.swift -emit-module-path .build/mac-import/BooksPlatform.swiftmodule -o .build/mac-import/libBooksPlatform.dylib
swiftc -I .build/mac-import -L .build/mac-import -lBooksCore -lBooksPlatform scripts/epub-import-smoke.swift -o .build/mac-import/smoke
.build/mac-import/smoke
```

Synthetic fixtures created using Python standard-library ZIP writer in a temporary folder. PASS: metadata/spine/explicit cover, missing explicit cover remains nil, byte-preserved original, SHA-256 dedupe, receipt enumeration; rejection of traversal, absolute/backslash paths, duplicate entries, case aliases, DTD/entities, unsupported declared encryption, encryption ZIP flags, symlink, truncated ZIP, extreme ratio, Windows reserved path, overlong author, resource expansion bound; staging cleanup; forged resource symlink rejected both during enumeration and duplicate import. No real books/data, installed app, permissions, push or release were touched. Full app integration/build remains root-owned.

## Review hardening

Duplicate imports and receipt enumeration now stream-hash the managed original against the edition ID; a corrupted original fails visibly and remains untouched. Windows superscript device aliases COM¹/²/³ and LPT¹/²/³ are rejected. XML parsing enables namespace processing and requires the container namespace/root plus OPF package namespace/root and version 2.0 or 3.0. Expanded synthetic tests pass for wrong package root/namespace/version, superscript device paths, and corrupted-original duplicate/enumeration rejection. This supersedes the earlier receipt note only with respect to the original EPUB: extracted resource contents still are not rehashed on every receipt load.

## IDPF font verification follow-up

The native importer smoke now includes a hardcoded SHA-1 known vector, exact XML-whitespace removal, short and1500-byte fonts (including unchanged bytes after1040), original equality/dedupe and14 invalid font declarations with staging cleanup. Node parity additionally checks split-stream decoding, ambiguous manifest identity, trailing-slash references and non-whitespace encryption text. The accepted method is the [EPUB standard IDPF font method](https://www.w3.org/TR/epub-33/#sec-font-obfuscation); Adobe and other encryption methods remain rejected. This verifies import transformation, not complete font rendering or publisher fidelity.
