import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import yauzl from "yauzl";
import { canonicalArchivePath } from "../publication/path-policy.js";

export const FORMAT = "stillleaf-portable-library";
export const VERSION = 1;
export const LIMITS = Object.freeze({
  archiveBytes: 256 * 1024 * 1024,
  totalBytes: 256 * 1024 * 1024,
  entryBytes: 128 * 1024 * 1024,
  jsonBytes: 32 * 1024 * 1024,
  manifestBytes: 2 * 1024 * 1024,
  entries: 10000,
  ratio: 200,
});
const CAPABILITIES = [
  "source-envelopes-v1",
  "reader-state-v1",
  "original-epub-v1",
  "cover-blobs-v1",
];
const snapshots = new WeakMap();
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const object = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);
function check(condition, message) {
  if (!condition) throw Error(message);
}
function limitsFor(options = {}) {
  const limits = { ...LIMITS, ...options.limits };
  for (const [key, value] of Object.entries(limits))
    check(
      Number.isSafeInteger(value) && value > 0 && value <= LIMITS[key],
      "Limits may only tighten fixed archive budgets",
    );
  return limits;
}
function safeName(name) {
  check(
    typeof name === "string" && !name.endsWith("/"),
    "Only explicit file paths are supported",
  );
  return canonicalArchivePath(name);
}
function checkNames(names) {
  const keys = new Set();
  for (const name of names) {
    const key = safeName(name).toLowerCase();
    check(!keys.has(key), "Duplicate or case-colliding path");
    keys.add(key);
  }
  for (const key of keys) {
    const parts = key.split("/");
    parts.pop();
    while (parts.length) {
      check(!keys.has(parts.join("/")), "File is also a parent path");
      parts.pop();
    }
  }
}
function json(bytes, cap) {
  check(bytes.length <= cap, "JSON byte budget exceeded");
  let value;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw Error("Invalid UTF-8 JSON");
  }
  check(object(value), "JSON root must be an object");
  return value;
}
function freeze(value) {
  if (value && typeof value === "object") {
    Object.freeze(value);
    for (const child of Object.values(value)) freeze(child);
  }
  return value;
}

// Deliberately preserve source bytes; shape checks do not project either journal into the other.
function validatePayload(entry, bytes, limits) {
  check(
    entry.bytes === bytes.length && entry.sha256 === sha(bytes),
    `Integrity mismatch: ${entry.path}`,
  );
  if (entry.role === "journal") {
    const value = json(bytes, limits.jsonBytes);
    if (entry.format === "native-history-json") {
      check(
        entry.schemaVersion === 1 && value.version === 1,
        "Unsupported native history version",
      );
      for (const key of [
        "books",
        "intervals",
        "corrections",
        "goals",
        "events",
        "progress",
        "merges",
      ])
        check(Array.isArray(value[key]), `Missing native ${key} array`);
    } else {
      check(
        entry.format === "node-journal-json" &&
          entry.schemaVersion === 1 &&
          value.format === "stillleaf-node-journal" &&
          value.version === 1 &&
          value.schemaVersion === 2,
        "Unsupported journal envelope",
      );
      check(object(value.tables), "Missing Node tables");
      for (const key of [
        "books",
        "editions",
        "manual_entries",
        "events",
        "daily_goals",
        "migration_sources",
        "migration_records",
        "tracking_intervals",
        "sqlite_sequence",
      ])
        check(Array.isArray(value.tables[key]), `Missing Node ${key} table`);
    }
  } else if (entry.role === "reader-state") {
    const value = json(bytes, Math.min(limits.jsonBytes, 2 * 1024 * 1024));
    check(
      value.schemaVersion === 1 &&
        value.editionId === entry.editionId &&
        Number.isSafeInteger(value.revision) &&
        value.revision >= 0,
      "Unsupported reader snapshot",
    );
    check(
      Array.isArray(value.bookmarks) &&
        value.bookmarks.length <= 2000 &&
        Array.isArray(value.annotations) &&
        value.annotations.length <= 2000,
      "Invalid reader record counts",
    );
    // Publication-relative locator validation belongs to the destination adapter after EPUB import.
  } else if (entry.role === "epub") {
    check(
      entry.editionId === entry.sha256,
      "Original EPUB digest must equal its edition identity",
    );
  } else {
    check(
      entry.role === "cover" || entry.role === "provenance",
      "Unknown payload role",
    );
    if (entry.role === "cover")
      check(
        typeof entry.bookId === "string" ||
          /^[a-f0-9]{64}$/.test(entry.editionId),
        "Cover must identify its book or edition",
      );
  }
}
function validateManifest(manifest, files, limits) {
  check(
    manifest.format === FORMAT && manifest.version === VERSION,
    "Unsupported portable archive version",
  );
  check(
    typeof manifest.archiveId === "string" &&
      manifest.archiveId.length > 0 &&
      manifest.archiveId.length <= 200,
    "Invalid archive identity",
  );
  check(
    typeof manifest.exportedAt === "string" &&
      Number.isFinite(Date.parse(manifest.exportedAt)),
    "Invalid export time",
  );
  check(
    object(manifest.producer) &&
      typeof manifest.producer.host === "string" &&
      typeof manifest.producer.version === "string",
    "Missing producer",
  );
  check(
    Array.isArray(manifest.requiredCapabilities) &&
      manifest.requiredCapabilities.every((x) => CAPABILITIES.includes(x)),
    "Unsupported required capability",
  );
  check(
    Array.isArray(manifest.entries) &&
      manifest.entries.length > 0 &&
      manifest.entries.length < limits.entries,
    "Invalid entry inventory",
  );
  checkNames(["manifest.json", ...manifest.entries.map((e) => e.path)]);
  check(
    files.size === manifest.entries.length + 1,
    "ZIP inventory differs from manifest",
  );
  let journals = 0;
  for (const entry of manifest.entries) {
    check(
      object(entry) &&
        Number.isSafeInteger(entry.bytes) &&
        entry.bytes >= 0 &&
        entry.bytes <= limits.entryBytes &&
        /^[a-f0-9]{64}$/.test(entry.sha256),
      "Invalid manifest entry",
    );
    if (["epub", "reader-state"].includes(entry.role))
      check(/^[a-f0-9]{64}$/.test(entry.editionId), "Invalid edition identity");
    if (entry.bookId !== undefined)
      check(
        typeof entry.bookId === "string" &&
          entry.bookId.length > 0 &&
          entry.bookId.length <= 4096,
        "Invalid book association",
      );
    const bytes = files.get(entry.path);
    check(bytes, `Missing payload: ${entry.path}`);
    validatePayload(entry, bytes, limits);
    if (entry.role === "journal") journals++;
  }
  check(journals > 0, "Archive must preserve a source journal");
}
const crcTable = Array.from({ length: 256 }, (_, n) => {
  for (let k = 0; k < 8; k++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1;
  return n >>> 0;
});
function crc32(bytes) {
  let n = 0xffffffff;
  for (const b of bytes) n = crcTable[(n ^ b) & 255] ^ (n >>> 8);
  return (n ^ 0xffffffff) >>> 0;
}
// Store-only writer: avoids a second dependency and cannot create a compression bomb.
function zipBytes(files) {
  const local = [],
    central = [];
  let offset = 0;
  for (const [name, bytes] of files) {
    const filename = Buffer.from(name),
      crc = crc32(bytes),
      header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(0x800, 6);
    header.writeUInt32LE(crc, 14);
    header.writeUInt32LE(bytes.length, 18);
    header.writeUInt32LE(bytes.length, 22);
    header.writeUInt16LE(filename.length, 26);
    const dir = Buffer.alloc(46);
    dir.writeUInt32LE(0x02014b50);
    dir.writeUInt16LE(0x314, 4);
    dir.writeUInt16LE(20, 6);
    dir.writeUInt16LE(0x800, 8);
    dir.writeUInt32LE(crc, 16);
    dir.writeUInt32LE(bytes.length, 20);
    dir.writeUInt32LE(bytes.length, 24);
    dir.writeUInt16LE(filename.length, 28);
    dir.writeUInt32LE((0o100600 << 16) >>> 0, 38);
    dir.writeUInt32LE(offset, 42);
    local.push(header, filename, bytes);
    central.push(dir, filename);
    offset += header.length + filename.length + bytes.length;
  }
  const directory = Buffer.concat(central),
    end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(files.size, 8);
  end.writeUInt16LE(files.size, 10);
  end.writeUInt32LE(directory.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, directory, end]);
}
async function readRegular(file, cap) {
  check(path.isAbsolute(file), "Input path must be absolute");
  const before = await fs.lstat(file);
  check(
    before.isFile() && !before.isSymbolicLink(),
    "Input must not be a symlink or special file",
  );
  const handle = await fs.open(file, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await handle.stat();
    check(
      stat.isFile() && stat.size <= cap,
      "Input is not a bounded regular file",
    );
    // A fixed allocation/read avoids an unbounded readFile if a producer grows the file concurrently.
    const bytes = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < bytes.length) {
      const { bytesRead } = await handle.read(
        bytes,
        offset,
        bytes.length - offset,
        offset,
      );
      check(bytesRead > 0, "Input changed while reading");
      offset += bytesRead;
    }
    const after = await handle.stat();
    check(
      after.size === stat.size &&
        after.mtimeMs === stat.mtimeMs &&
        after.ctimeMs === stat.ctimeMs,
      "Input changed while reading",
    );
    return bytes;
  } finally {
    await handle.close();
  }
}
async function safeSource(root, relative) {
  safeName(relative);
  let current = root;
  for (const part of relative.split("/")) {
    current = path.join(current, part);
    const stat = await fs.lstat(current);
    check(!stat.isSymbolicLink(), "Symlink source is forbidden");
  }
  return current;
}
async function syncDirectory(directory) {
  const handle = await fs.open(directory, "r");
  try {
    await handle.sync();
  } catch (error) {
    if (!["EINVAL", "ENOTSUP", "EPERM", "EISDIR"].includes(error.code))
      throw error;
  } finally {
    await handle.close();
  }
}
async function atomicPublish(bytes, destination) {
  check(path.isAbsolute(destination), "Destination must be absolute");
  const parent = path.dirname(destination);
  const stat = await fs.lstat(parent);
  check(
    stat.isDirectory() && !stat.isSymbolicLink(),
    "Unsafe destination parent",
  );
  const temporary = path.join(parent, `.stillleaf-export-${randomUUID()}.tmp`);
  const handle = await fs.open(temporary, "wx", 0o600);
  try {
    await handle.writeFile(bytes);
    await handle.sync();
  } catch (error) {
    await handle.close();
    await fs.rm(temporary, { force: true });
    throw error;
  }
  await handle.close();
  try {
    await fs.link(temporary, destination);
    await syncDirectory(parent);
  } finally {
    await fs.rm(temporary, { force: true });
  }
  return { path: destination, bytes: bytes.length, sha256: sha(bytes) };
}

/** Exact source files are snapshotted under sourceRoot; only listed relative paths are read. */
export async function exportArchive(
  {
    sourceRoot,
    files,
    producer,
    archiveId = randomUUID(),
    exportedAt = new Date().toISOString(),
    requiredCapabilities = CAPABILITIES,
  },
  destination,
  options = {},
) {
  const limits = limitsFor(options);
  check(path.isAbsolute(sourceRoot), "Source root must be absolute");
  const stat = await fs.lstat(sourceRoot);
  check(stat.isDirectory() && !stat.isSymbolicLink(), "Unsafe source root");
  check(
    Array.isArray(files) && files.length > 0 && files.length < limits.entries,
    "Invalid export inventory",
  );
  checkNames(["manifest.json", ...files.map((e) => e.path)]);
  const data = new Map();
  const entries = [];
  let total = 0;
  for (const descriptor of files) {
    const { sourcePath = descriptor.path, ...metadata } = descriptor;
    const bytes = await readRegular(
      await safeSource(sourceRoot, sourcePath),
      limits.entryBytes,
    );
    total += bytes.length;
    check(total <= limits.totalBytes, "Total byte budget exceeded");
    const entry = { ...metadata, bytes: bytes.length, sha256: sha(bytes) };
    entries.push(entry);
    data.set(entry.path, bytes);
  }
  const manifest = {
    format: FORMAT,
    version: VERSION,
    archiveId,
    exportedAt,
    producer,
    requiredCapabilities,
    entries,
  };
  const manifestBytes = Buffer.from(JSON.stringify(manifest, null, 2) + "\n");
  check(
    manifestBytes.length <= limits.manifestBytes,
    "Manifest byte budget exceeded",
  );
  total += manifestBytes.length;
  check(total <= limits.totalBytes, "Total byte budget exceeded");
  data.set("manifest.json", manifestBytes);
  validateManifest(manifest, data, limits);
  const bytes = zipBytes(data);
  check(bytes.length <= limits.archiveBytes, "Archive byte budget exceeded");
  return atomicPublish(bytes, destination);
}
async function decodeZip(bytes, limits) {
  const zip = await new Promise((resolve, reject) =>
    yauzl.fromBuffer(
      bytes,
      {
        lazyEntries: true,
        autoClose: false,
        decodeStrings: false,
        validateEntrySizes: true,
        strictFileNames: true,
      },
      (e, z) => (e ? reject(e) : resolve(z)),
    ),
  );
  const centralDirectoryOffset = zip.readEntryCursor;
  try {
    const entries = await new Promise((resolve, reject) => {
      const found = [];
      let total = 0;
      zip.on("error", reject);
      zip.on("end", () => resolve(found));
      zip.on("entry", (entry) => {
        try {
          check(found.length < limits.entries, "ZIP entry count exceeded");
          check(
            entry.generalPurposeBitFlag & 0x800 ||
              entry.fileName.every((b) => b < 128),
            "Filename must declare UTF-8",
          );
          entry.rawName = entry.fileName;
          entry.name = new TextDecoder("utf-8", { fatal: true }).decode(
            entry.fileName,
          );
          safeName(entry.name);
          check(
            !(entry.generalPurposeBitFlag & 0x41),
            "Encrypted ZIP is forbidden",
          );
          check(
            [0, 8].includes(entry.compressionMethod),
            "Unsupported compression",
          );
          const kind = (entry.externalFileAttributes >>> 16) & 0xf000;
          check(!kind || kind === 0x8000, "Symlink or special ZIP file");
          check(
            Number.isSafeInteger(entry.uncompressedSize) &&
              entry.uncompressedSize <= limits.entryBytes,
            "ZIP entry byte budget exceeded",
          );
          total += entry.uncompressedSize;
          check(total <= limits.totalBytes, "ZIP expansion budget exceeded");
          check(
            entry.uncompressedSize <=
              Math.max(entry.compressedSize, 1) * limits.ratio,
            "ZIP expansion ratio exceeded",
          );
          found.push(entry);
          zip.readEntry();
        } catch (error) {
          reject(error);
        }
      });
      zip.readEntry();
    });
    checkNames(entries.map((e) => e.name));
    const ranges = [];
    for (const entry of entries) {
      const local = await new Promise((resolve, reject) =>
        zip.readLocalFileHeader(entry, (e, v) => (e ? reject(e) : resolve(v))),
      );
      check(
        local.fileName.equals(entry.rawName) &&
          local.compressionMethod === entry.compressionMethod &&
          local.generalPurposeBitFlag === entry.generalPurposeBitFlag,
        "ZIP local header mismatch",
      );
      if (!(entry.generalPurposeBitFlag & 8))
        check(
          local.crc32 === entry.crc32 &&
            local.uncompressedSize === entry.uncompressedSize &&
            local.compressedSize === entry.compressedSize,
          "ZIP header integrity mismatch",
        );
      const end = local.fileDataStart + entry.compressedSize;
      check(end <= centralDirectoryOffset, "ZIP entry overlaps directory");
      ranges.push([entry.relativeOffsetOfLocalHeader, end]);
    }
    ranges.sort((a, b) => a[0] - b[0]);
    for (let i = 1; i < ranges.length; i++)
      check(ranges[i][0] >= ranges[i - 1][1], "Overlapping ZIP entries");
    const files = new Map();
    for (const entry of entries) {
      const stream = await zip.openReadStreamPromise(entry),
        chunks = [];
      let size = 0;
      for await (const chunk of stream) {
        size += chunk.length;
        check(
          size <= entry.uncompressedSize && size <= limits.entryBytes,
          "Expanded entry exceeds declared size",
        );
        chunks.push(chunk);
      }
      const value = Buffer.concat(chunks);
      check(
        size === entry.uncompressedSize && crc32(value) === entry.crc32,
        "ZIP checksum mismatch",
      );
      files.set(entry.name, value);
    }
    return files;
  } finally {
    zip.close();
  }
}

/** Read-only preview. The returned token captures exact validated bytes, not mutable file paths. */
export async function inspectArchive(file, options = {}) {
  const limits = limitsFor(options);
  const bytes = await readRegular(file, limits.archiveBytes);
  const files = await decodeZip(bytes, limits);
  check(files.has("manifest.json"), "Missing manifest");
  const manifest = json(files.get("manifest.json"), limits.manifestBytes);
  validateManifest(manifest, files, limits);
  const existing = options.existingEntries ?? {};
  const editionAssets = new Set(
    manifest.entries.filter((e) => e.role === "epub").map((e) => e.editionId),
  );
  const entries = manifest.entries.map((entry) => ({
    ...entry,
    status: Object.hasOwn(existing, entry.path)
      ? existing[entry.path] === entry.sha256
        ? "identical"
        : "conflict"
      : "new",
  }));
  const preview = freeze({
    manifest,
    sha256: sha(bytes),
    bytes: bytes.length,
    entries,
    pendingReaderStates: manifest.entries
      .filter(
        (e) => e.role === "reader-state" && !editionAssets.has(e.editionId),
      )
      .map((e) => e.editionId),
    activation: "preservation-only",
    journalProjectionApplied: false,
  });
  snapshots.set(preview, { bytes, files });
  return preview;
}
/** Preserve an inspected bundle byte-for-byte, including unknown optional metadata/source fields. */
export async function exportPreservedArchive(preview, destination) {
  const snapshot = snapshots.get(preview);
  check(snapshot, "Inspect archive before exporting");
  return atomicPublish(snapshot.bytes, destination);
}
/** New private staging directory only; never overwrites or activates a destination library. */
export async function stageImport(preview, destination) {
  const snapshot = snapshots.get(preview);
  check(snapshot, "Inspect archive before staging");
  check(path.isAbsolute(destination), "Stage path must be absolute");
  const parent = await fs.lstat(path.dirname(destination));
  check(
    parent.isDirectory() && !parent.isSymbolicLink(),
    "Unsafe stage parent",
  );
  await fs.mkdir(destination, { mode: 0o700 });
  try {
    for (const [name, bytes] of snapshot.files) {
      const target = path.join(destination, "payloads", name);
      await fs.mkdir(path.dirname(target), { recursive: true, mode: 0o700 });
      const handle = await fs.open(target, "wx", 0o600);
      try {
        await handle.writeFile(bytes);
        await handle.sync();
      } finally {
        await handle.close();
      }
    }
    await atomicPublish(
      snapshot.bytes,
      path.join(destination, "original.stillleaf.zip"),
    );
    const report = {
      version: 1,
      state: "preserved",
      archiveSha256: preview.sha256,
      activation: "preservation-only",
      journalProjectionApplied: false,
      entries: preview.entries,
      pendingReaderStates: preview.pendingReaderStates,
    };
    await atomicPublish(
      Buffer.from(JSON.stringify(report, null, 2) + "\n"),
      path.join(destination, "READY.json"),
    );
    await syncDirectory(destination);
    return { directory: destination, ...report };
  } catch (error) {
    await fs.rm(destination, { recursive: true, force: true });
    throw error;
  }
}
