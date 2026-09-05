# Portable library preservation package

This package implements an offline ZIP envelope and **preservation-only** import staging. It does not replace an active journal, apply reader state, decode images, trust publication receipts, or convert native correction/merge history into Node records. It has no network calls and does not read unlisted files or credentials.

## Version 1 format

`manifest.json` contains `format: "stillleaf-portable-library"`, `version: 1`, `archiveId`, ISO `exportedAt`, `producer: {host, version}`, `requiredCapabilities`, and an ordered `entries` inventory. Each entry has an explicit portable relative `path`, `bytes`, SHA-256 `sha256`, and `role`. Unknown optional manifest fields survive preservation/re-export exactly. Unknown versions, required capabilities, and roles fail closed.

Roles:

| Role           | Required metadata and source                                                                                                                                                                                                                                         |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `journal`      | `format: native-history-json`, `schemaVersion: 1`: exact native HistoryArchive JSON, including all eight arrays. Or `format: node-journal-json`, `schemaVersion: 1`: the Node export contract below. Multiple source journals may coexist. At least one is required. |
| `reader-state` | `editionId`: lowercase SHA-256; exact schemaVersion 1 reader JSON for that edition. Optional original `bookId` association. Version, identity, revision and count bounds are checked; full publication-relative locator validation is deferred to the host.          |
| `epub`         | `editionId` must equal SHA-256 of unchanged original EPUB bytes. Never substitute extracted resources or repacked fonts. The archive does not claim the embedded EPUB is renderable; the destination importer must validate it.                                      |
| `cover`        | Explicit `bookId` or `editionId` association. Optional provenance/media metadata may be retained. Bytes remain opaque until the destination performs bounded image validation.                                                                                       |
| `provenance`   | Explicitly selected source bytes, with optional association/provenance metadata. No implicit filesystem crawl.                                                                                                                                                       |

Preserve original book IDs and native merge history. A host may put original and resolved association information in optional entry metadata, but must not replace the historical identities. Native `coverPath` strings inside an exact source envelope are retained as data and **never followed**. Only manifest-listed cover files are portable assets.

Limits are fixed at 256 MiB archive/expanded total, 128 MiB per entry, 32 MiB per journal JSON, 2 MiB manifest and reader state, 10,000 ZIP entries including the manifest, and 200:1 expansion ratio. Caller limits may tighten these. This initial in-memory implementation is bounded but can transiently use several times the archive byte limit; hosts should run large operations outside their UI process. Large libraries require a future streaming/segmented format; no partial export is represented as complete.

## Host adapter API

```js
import {
  exportArchive,
  inspectArchive,
  stageImport,
  exportPreservedArchive,
} from "./index.js";
import { exportNodeJournal } from "./node-journal.js";
```

1. Acquire the host's library-operation lock. Stop/checkpoint tracking, prevent publication removal/new readers, and ask existing readers to flush with the current draft guard. Cancellation aborts the operation. Create a private export snapshot directory. Snapshot the native history via its existing exporter or write `exportNodeJournal(journal.db)` bytes. Collect **every** reader state, including unavailable editions. Copy optional originals/covers into that private directory without altering the originals. Preserve any previously imported source envelopes as well. The archive package cannot make independently changing stores/files coherent: the host owns this lock and snapshot step.
2. `await exportArchive({sourceRoot, producer, files}, absoluteDestination, options)`. `sourceRoot` must be an existing nonsymlink directory. `files` are manifest descriptors with an optional `sourcePath` relative to that root (defaults to `path`). `sourcePath` is not exported. Missing selected files fail the whole export; to omit assets deliberately, omit descriptors and report omissions to the user. The exporter reads only listed files, rejects source symlinks, snapshots bytes, validates the entire result, and writes a store-only ZIP. Destination must not exist. Same-directory temporary file + fsync + hard link publishes without overwrite; unsupported filesystems fail rather than falling back to overwrite. Parent must already exist. Existing originals are never moved/deleted.
3. `const preview = await inspectArchive(absoluteArchivePath, {existingEntries, limits})`. This performs all ZIP inventory, path, compression, CRC, header, byte-count, source-shape, and SHA-256 checks **without writing files**. `existingEntries` optionally maps portable path to a current digest: entries report `new`, `identical`, or `conflict`. These are path/content comparisons, not journal identity reconciliation. `pendingReaderStates` lists states whose original EPUB is absent from this archive; an adapter may later match an already installed validated edition. Preview is frozen and privately retains the exact validated bytes, preventing a source-file change after inspection from changing import content.
4. Display the preview with **“Preserve archive for recovery”** semantics. `await stageImport(preview, newAbsolutePrivateDirectory)` creates a new mode-0700 directory containing `payloads/<manifest paths>`, `original.stillleaf.zip`, and a final `READY.json`. This is preservation only: `journalProjectionApplied: false`, no totals or celebrations. Existing destinations fail. Ordinary failures remove only this newly created staging directory. After process interruption a directory without READY is incomplete; a host must quarantine/delete its own incomplete stage and retry, never activate it. Reinspect `original.stillleaf.zip` before consuming a READY stage after restart; READY is a completion marker, not an authenticity guarantee. File fsync is used; full crash/power-loss guarantees across platform filesystems are not asserted.
5. `await exportPreservedArchive(preview, newAbsoluteDestination)` writes the exact input ZIP bytes, including unknown optional fields, ordering, and all source envelopes. For a preserved stage after restart, inspect its `original.stillleaf.zip` first. This supports byte-for-byte recovery round trips across hosts without inventing active journal mappings.

Staging does not resolve conflicting reader revisions or conflicting book/entry identities. A future activation adapter must take validated backups, preview domain collisions under the same operation lock, validate original EPUBs through its own importer, validate locators against that publication, and perform a recoverable multi-store commit. It must retain unsupported source records, preserve unknown dates/clear events/ordering, and report unapplied history explicitly. Do not execute SQL from a source envelope or follow its paths. There is no tombstone/synchronization protocol; an old source history may contain previously deleted records.

## Exact Node source-journal contract

`exportNodeJournal(database, {exportedAt})` runs a read transaction against an existing `node:sqlite` DatabaseSync (not an already-open caller transaction). It verifies schemaVersion 2, integrity and foreign keys, and refuses unrecognized tables. It snapshots all rows and all columns of `books`, `editions`, `manual_entries`, `events`, `daily_goals`, `migration_sources`, `migration_records`, `tracking_intervals`, and `sqlite_sequence` in deterministic primary-key/sequence order. It never changes the database schema or records.

The JSON envelope is `{format: "stillleaf-node-journal", version: 1, schemaVersion: 2, exportedAt, tables, schema}`. SQL JSON columns remain their original strings; BLOB cells become `{sqliteType:"blob", base64:"..."}`; integer cells become `{sqliteType:"integer", decimal:"..."}` to avoid 64-bit precision loss. Other SQLite values retain their JSON primitive types. `schema` is the original ordered sqlite_master diagnostic data, never executable import instructions. AUTOINCREMENT sequences are preserved even when the corresponding latest row was deleted. This captures raw source state, not evaluated totals.

Native source JSON remains exactly as exported, with millisecond timestamps, correction order, inactive merges, unknown evidence and optional fields untouched. Shape validation of a source envelope deliberately does not certify active domain validity. Byte preservation and integrity checks are not a claim of bidirectional journal projection.

## Evidence and limits

Run `npm ci --offline --ignore-scripts` using the existing cached pinned `yauzl@3.4.0` dependency, then `npm test`. The dependency matches the publication package; path policy is reused from `../publication/path-policy.js`, so both workspace packages must ship together. No speculative network install is needed.

Tests use synthetic temporary files and an actual temporary Node journal. They cover native + Node source coexistence, exact source and full-archive round trips, correction/merge/unknown-field retention, BLOB provenance, missing EPUB state, conflict previews, no overwrite, immutable inspection snapshots, source and ZIP symlinks, traversal/case/device names, unsupported versions/capabilities, digest and CRC corruption, local-header mismatch, manifest inventory mismatch, and expansion/size/count budgets. Mac-hosted Node evidence does not establish Windows filesystem behavior. Native UI and Electron menu wiring, same-host active restore, active cross-host journal projection, real-device crash recovery, and huge-library segmentation remain host/future work.
