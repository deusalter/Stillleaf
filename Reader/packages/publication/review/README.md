# Bounded native importer adversarial review

Read-only review of `Sources/BooksPlatform/EPUBPublicationImporter.swift`, `Sources/BooksCore/EPUBPublication.swift`, native smoke and handoff docs. Only this review directory was written. Synthetic archives were imported through an isolated command-line Swift probe, never through Stillleaf or real user data. Raw outcomes: `results.json`. Tested on macOS only.

## Findings

### P2: Duplicate import trusts a damaged managed EPUB

`loadReceipt` (reviewed line 115) checks that `original.epub` is a regular file below the maximum size, but does not check its hash or even a positive minimum size. After a successful fixture import, the reproducer replaces **only the synthetic managed copy** with `broken managed original`; importing the intact source returns `alreadyImported=true`. The result therefore endorses a broken standalone EPUB, and reimporting the original cannot recover the edition. This affects reliable Keep EPUB/export/portability behavior. The initial Node importer shared this gap. The lead subsequently authorized its repair: a new Node regression test verifies damaged managed originals now return a storage error without replacing either copy. Native remediation is assigned separately; the native observations below describe the reviewed source snapshot.

Suggested bounded fix: verify the stored original's SHA256 when resolving a duplicate, comparing it to the source-derived edition ID. Fail clearly if corrupt (or perform a separately reviewed repair that preserves annotations/history), rather than silently claiming a valid duplicate. It need not rehash every resource on every library launch. App-private storage assumptions mitigate malicious receipt editing but do not eliminate interrupted restore or accidental corruption.

### P2: Windows-reserved superscript device names accepted

The native `safePath` reserved-name list (reviewed line 138) omits `COM¹`, `COM²`, `COM³`, `LPT¹`, `LPT²`, `LPT³`. The synthetic `EPUB/COM¹.txt` archive is accepted and committed on Mac. [Microsoft documents these names as reserved in every directory](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file#naming-conventions). A Mac-imported publication containing them fails the co-primary Windows portable-path contract. The Node policy already rejects these names. Include them with the other device names and add the fixture to native tests. This test does not claim execution on Windows.

### P2: Invalid package root/namespace accepted as EPUB metadata

The metadata delegate matches element name suffixes globally, without requiring an OPF `package` root, namespace or supported version. A fixture replacing `<package>` with `<random>` and the OPF namespace with `https://example.invalid/` still imports with a normal spine and no structural warning. This causes the Library to accept an archive that a standards-based engine can reject at Read time; the Node parser already rejects it. Validate the container and package root/namespace/version before treating extracted tags as publication metadata. This is a conformance/host consistency issue, not an observed code-execution exploit.

## Additional observations, not raised as high-impact defects

- Multiple explicit cover declarations select the first even if its type is not an image, producing nil instead of rejecting ambiguous metadata.
- A standalone `META-INF/rights.xml` marker is accepted; unlike encryption.xml, this alone does not establish that content is encrypted. Reconcile with conservative Node policy rather than claiming a DRM bypass.
- File/parent conflicts reject during extraction (both ordering variants), although they are not rejected during native preflight. Staging cleanup limits their impact.
- Managed roots are assumed app-private; this review did not test a privileged concurrent local attacker swapping root ancestors.

## Checks that held

Valid EPUB imports. Both file/parent conflict orderings, a deflate stream whose actual output exceeds its declared size, corrupt CRC, and conflicting local/central entry names all reject. No archive path escape, arbitrary write or external fetch was demonstrated. Existing native smoke adds traversal, symlink, encoding/case-alias and DTD cases; this bounded review does not replace independent comprehensive fuzzing.

## Reproduce

From repository root, build the probe into this owned directory:

```sh
swiftc -emit-library -emit-module -module-name BooksCore Sources/BooksCore/EPUBPublication.swift -emit-module-path Reader/packages/publication/review/build/BooksCore.swiftmodule -o Reader/packages/publication/review/build/libBooksCore.dylib
swiftc -emit-library -emit-module -module-name BooksPlatform -I Reader/packages/publication/review/build -L Reader/packages/publication/review/build -lBooksCore Sources/BooksPlatform/EPUBPublicationImporter.swift -emit-module-path Reader/packages/publication/review/build/BooksPlatform.swiftmodule -o Reader/packages/publication/review/build/libBooksPlatform.dylib
swiftc -I Reader/packages/publication/review/build -L Reader/packages/publication/review/build -lBooksCore -lBooksPlatform Reader/packages/publication/review/probe.swift -o Reader/packages/publication/review/build/probe
node Reader/packages/publication/review/run-review.js
```

`build/` must exist. `run-review.js` creates synthetic files exclusively in ignored `review/work/`; remove that generated directory before an independent clean rerun so previous duplicate/corruption state is not reused. Never redirect these probes to real managed storage. No native application source edits were made.
