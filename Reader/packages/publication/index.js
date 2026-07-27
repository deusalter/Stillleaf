import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { createHash } from "node:crypto";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import yauzl from "yauzl";
import { fail, PublicationError } from "./errors.js";
import { canonicalArchivePath } from "./path-policy.js";
import { readPublicationMetadata } from "./metadata.js";
import { fontObfuscationPlan, decodeFont } from "./font-obfuscation.js";
export { PublicationError } from "./errors.js";
export { canonicalArchivePath, resolveResource } from "./path-policy.js";

export const DEFAULT_LIMITS = Object.freeze({
  archiveBytes: 128 * 1024 * 1024,
  entries: 10000,
  entryBytes: 32 * 1024 * 1024,
  totalBytes: 512 * 1024 * 1024,
  ratio: 200,
  xmlBytes: 1024 * 1024,
  pathBytes: 512,
});
const checkAbort = (signal) => {
  if (signal?.aborted)
    throw (
      signal.reason ?? new PublicationError("CANCELLED", "Import cancelled")
    );
};
function limitsFor(options) {
  const limits = { ...DEFAULT_LIMITS, ...options.limits };
  for (const [key, n] of Object.entries(limits))
    if (!Number.isSafeInteger(n) || n <= 0)
      fail("LIMITS", `Invalid limit ${key}`);
  return limits;
}

const crcTable = Array.from({ length: 256 }, (_, n) => {
  for (let k = 0; k < 8; k++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1;
  return n >>> 0;
});
function crcUpdate(crc, chunk) {
  for (const byte of chunk) crc = crcTable[(crc ^ byte) & 255] ^ (crc >>> 8);
  return crc;
}
const openZip = (file) =>
  new Promise((resolve, reject) =>
    yauzl.open(
      file,
      {
        lazyEntries: true,
        autoClose: false,
        decodeStrings: false,
        validateEntrySizes: true,
        strictFileNames: true,
      },
      (error, zip) => (error ? reject(error) : resolve(zip)),
    ),
  );
const localHeader = (zip, entry) =>
  new Promise((resolve, reject) =>
    zip.readLocalFileHeader(entry, (error, header) =>
      error ? reject(error) : resolve(header),
    ),
  );
function allEntries(zip, limits, signal) {
  return new Promise((resolve, reject) => {
    const entries = [];
    const names = new Map();
    let total = 0;
    const stop = (error) => {
      zip.removeListener("entry", entry);
      zip.removeListener("end", end);
      reject(error);
    };
    const entry = (e) => {
      try {
        checkAbort(signal);
        if (entries.length >= limits.entries)
          fail("ENTRY_COUNT", "Too many ZIP entries");
        // Strict UTF-8 for flagged names; unflagged ASCII only avoids platform encoding ambiguity.
        if (
          !(e.generalPurposeBitFlag & 0x800) &&
          e.fileName.some((byte) => byte > 127)
        )
          fail("PATH", "Non-ASCII ZIP names must declare UTF-8");
        let text;
        try {
          text = new TextDecoder("utf-8", { fatal: true }).decode(e.fileName);
        } catch {
          fail("PATH", "Invalid UTF-8 filename");
        }
        e.rawName = e.fileName;
        e.fileName = text;
        e.safeName = canonicalArchivePath(text, limits);
        e.directory = text.endsWith("/");
        const key = e.safeName.toLowerCase();
        if (names.has(key))
          fail("DUPLICATE_ENTRY", "Duplicate or case-colliding archive entry");
        names.set(key, e.directory);
        if (e.generalPurposeBitFlag & 0x41)
          fail("PROTECTED", "Encrypted ZIP entries are unsupported");
        if (![0, 8].includes(e.compressionMethod))
          fail("COMPRESSION", "Unsupported compression");
        const kind = (e.externalFileAttributes >>> 16) & 0xf000;
        if (kind && kind !== (e.directory ? 0x4000 : 0x8000))
          fail("FILE_TYPE", "Symlink or special ZIP entry");
        if (
          !Number.isSafeInteger(e.uncompressedSize) ||
          e.uncompressedSize > limits.entryBytes
        )
          fail("ENTRY_SIZE", "Entry exceeds budget");
        total += e.uncompressedSize;
        if (!Number.isSafeInteger(total) || total > limits.totalBytes)
          fail("TOTAL_SIZE", "Archive expansion exceeds budget");
        if (e.uncompressedSize > Math.max(e.compressedSize, 1) * limits.ratio)
          fail("RATIO", "Archive expansion ratio exceeds budget");
        if (e.directory && e.uncompressedSize !== 0)
          fail("FILE_TYPE", "Directory with data");
        if (key === "meta-inf/rights.xml")
          fail(
            "PROTECTED",
            "Encrypted, obfuscated, or rights-managed EPUB unsupported",
          );
        entries.push(e);
        zip.readEntry();
      } catch (error) {
        stop(error);
      }
    };
    const end = () => {
      try {
        for (const e of entries) {
          const parts = e.safeName.toLowerCase().split("/");
          parts.pop();
          while (parts.length) {
            if (names.get(parts.join("/")) === false)
              fail("PATH", "File is also a parent directory");
            parts.pop();
          }
        }
        resolve(entries);
      } catch (error) {
        reject(error);
      }
    };
    zip.on("entry", entry);
    zip.once("end", end);
    zip.once("error", stop);
    zip.readEntry();
  });
}
async function inspectHeaders(zip, entries, signal) {
  const ranges = [];
  for (const e of entries) {
    checkAbort(signal);
    const local = await localHeader(zip, e);
    if (
      !local.fileName.equals(e.rawName) ||
      local.compressionMethod !== e.compressionMethod ||
      local.generalPurposeBitFlag !== e.generalPurposeBitFlag
    )
      fail("HEADER", "Local/central ZIP header mismatch");
    if (
      !(e.generalPurposeBitFlag & 8) &&
      (local.crc32 !== e.crc32 ||
        local.compressedSize !== e.compressedSize ||
        local.uncompressedSize !== e.uncompressedSize)
    )
      fail("HEADER", "ZIP size/checksum header mismatch");
    const end = local.fileDataStart + e.compressedSize;
    if (end > zip.centralDirectoryOffset)
      fail("HEADER", "ZIP entry overlaps directory");
    ranges.push([e.relativeOffsetOfLocalHeader, end]);
  }
  ranges.sort((a, b) => a[0] - b[0]);
  for (let i = 1; i < ranges.length; i++)
    if (ranges[i][0] < ranges[i - 1][1])
      fail("HEADER", "Overlapping ZIP entries");
}
async function entryStream(zip, entry, cap, signal) {
  checkAbort(signal);
  if (entry.uncompressedSize > cap)
    fail("ENTRY_SIZE", "Resource exceeds read budget");
  const stream = await zip.openReadStreamPromise(entry);
  let count = 0,
    crc = 0xffffffff;
  const guard = new Transform({
    transform(chunk, encoding, callback) {
      try {
        checkAbort(signal);
        count += chunk.length;
        if (count > cap || count > entry.uncompressedSize)
          fail("ENTRY_SIZE", "Inflated entry exceeds declared or allowed size");
        crc = crcUpdate(crc, chunk);
        callback(null, chunk);
      } catch (error) {
        callback(error);
      }
    },
    flush(callback) {
      if (
        count !== entry.uncompressedSize ||
        (crc ^ 0xffffffff) >>> 0 !== entry.crc32
      )
        callback(
          new PublicationError("CHECKSUM", "ZIP data length or CRC mismatch"),
        );
      else callback();
    },
  });
  return { stream, guard };
}
async function entryBytes(zip, entry, cap, signal) {
  if (!entry) fail("MISSING", "Required EPUB resource missing");
  const { stream, guard } = await entryStream(zip, entry, cap, signal);
  const chunks = [];
  await pipeline(
    stream,
    guard,
    async (source) => {
      for await (const chunk of source) chunks.push(chunk);
    },
    { signal },
  );
  return Buffer.concat(chunks);
}
async function openInspected(source, options) {
  const limits = limitsFor(options);
  checkAbort(options.signal);
  const stat = await fsp.lstat(source);
  if (!stat.isFile() || stat.isSymbolicLink())
    fail("SOURCE", "Source must be a regular file");
  if (stat.size > limits.archiveBytes)
    fail("ARCHIVE_SIZE", "EPUB exceeds archive budget");
  const zip = await openZip(source);
  zip.centralDirectoryOffset = zip.readEntryCursor;
  try {
    if (zip.entryCount > limits.entries)
      fail("ENTRY_COUNT", "Too many ZIP entries");
    const entries = await allEntries(zip, limits, options.signal);
    await inspectHeaders(zip, entries, options.signal);
    const files = new Map(
      entries.filter((e) => !e.directory).map((e) => [e.safeName, e]),
    );
    const mime = files.get("mimetype");
    if (
      !mime ||
      mime.relativeOffsetOfLocalHeader !== 0 ||
      mime.compressionMethod !== 0
    )
      fail("MIMETYPE", "EPUB mimetype must be first and stored");
    if (
      (await entryBytes(zip, mime, 64, options.signal)).toString() !==
      "application/epub+zip"
    )
      fail("MIMETYPE", "Invalid EPUB mimetype");
    const publication = await readPublicationMetadata(
      (name, cap) => entryBytes(zip, files.get(name), cap, options.signal),
      new Set(files.keys()),
      limits,
    );
    const fonts = await fontObfuscationPlan(
      (name, cap) => entryBytes(zip, files.get(name), cap, options.signal),
      publication, new Set(files.keys()), limits,
    );
    return { zip, entries, publication, limits, fonts };
  } catch (error) {
    zip.close();
    throw error;
  }
}
/** Read-only inspection; importEPUB snapshots before inspection for stable edition identity. */
export async function inspectEPUB(source, options = {}) {
  const context = await openInspected(source, options);
  try {
    return context.publication;
  } finally {
    context.zip.close();
  }
}
async function managedDirectory(directory) {
  await fsp.mkdir(directory, { recursive: true, mode: 0o700 });
  const stat = await fsp.lstat(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink())
    fail("STORAGE", "Managed directory cannot be a symlink");
}
async function copySnapshot(source, destination, limits, signal) {
  const stat = await fsp.lstat(source);
  if (
    !stat.isFile() ||
    stat.isSymbolicLink() ||
    stat.size > limits.archiveBytes
  )
    fail("SOURCE", "Invalid or oversized source");
  let total = 0;
  const hash = createHash("sha256");
  const guard = new Transform({
    transform(chunk, encoding, callback) {
      try {
        checkAbort(signal);
        total += chunk.length;
        if (total > limits.archiveBytes)
          fail("ARCHIVE_SIZE", "Source grew beyond archive budget");
        hash.update(chunk);
        callback(null, chunk);
      } catch (error) {
        callback(error);
      }
    },
  });
  await pipeline(
    fs.createReadStream(source),
    guard,
    fs.createWriteStream(destination, { flags: "wx", mode: 0o600 }),
    { signal },
  );
  return hash.digest("hex");
}
async function verifyManagedOriginal(file, expectedHash, cap, signal) {
  const hash = createHash("sha256");
  let total = 0;
  const input = fs.createReadStream(file, { signal });
  try {
    for await (const chunk of input) {
      checkAbort(signal);
      total += chunk.length;
      if (total > cap) fail("STORAGE", "Stored EPUB exceeds archive budget");
      hash.update(chunk);
    }
  } finally {
    input.destroy();
  }
  if (hash.digest("hex") !== expectedHash)
    fail(
      "STORAGE",
      "Stored EPUB digest does not match its edition; existing data preserved",
    );
}

/** Atomic directory publication on one local filesystem; no application database mutation. */
export async function importEPUB(source, managedRoot, options = {}) {
  const root = path.resolve(managedRoot),
    limits = limitsFor(options);
  checkAbort(options.signal);
  await managedDirectory(root);
  const staging = path.join(root, ".staging"),
    editions = path.join(root, "editions"),
    locks = path.join(root, ".locks");
  for (const directory of [staging, editions, locks])
    await managedDirectory(directory);
  const stage = await fsp.mkdtemp(path.join(staging, "import-"));
  let context, lock;
  try {
    const editionId = await copySnapshot(
      source,
      path.join(stage, "original.epub"),
      limits,
      options.signal,
    );
    context = await openInspected(path.join(stage, "original.epub"), options);
    const destination = path.join(editions, editionId);
    const lockPath = path.join(locks, editionId);
    try {
      await fsp.mkdir(lockPath, { mode: 0o700 });
      lock = lockPath;
    } catch (error) {
      if (error.code === "EEXIST")
        fail("BUSY", "Same edition import already in progress");
      throw error;
    }
    try {
      const destinationStat = await fsp.lstat(destination);
      if (!destinationStat.isDirectory() || destinationStat.isSymbolicLink())
        fail("STORAGE", "Existing edition must be a real directory");
      const receiptFile = path.join(destination, "publication.json");
      const receiptStat = await fsp.lstat(receiptFile);
      if (
        !receiptStat.isFile() ||
        receiptStat.isSymbolicLink() ||
        receiptStat.size > 4 * 1024 * 1024
      )
        fail("STORAGE", "Invalid existing receipt");
      const receipt = JSON.parse(await fsp.readFile(receiptFile, "utf8"));
      if (receipt.editionId !== editionId)
        fail("STORAGE", "Existing edition identity mismatch");
      const originalStat = await fsp.lstat(
        path.join(destination, "original.epub"),
      );
      if (
        !originalStat.isFile() ||
        originalStat.isSymbolicLink() ||
        originalStat.size > limits.archiveBytes
      )
        fail("STORAGE", "Existing EPUB missing");
      await verifyManagedOriginal(
        path.join(destination, "original.epub"),
        editionId,
        limits.archiveBytes,
        options.signal,
      );
      return {
        status: "duplicate",
        editionId,
        directory: destination,
        publication: receipt.publication,
      };
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      try {
        await fsp.lstat(destination);
        fail("STORAGE", "Incomplete existing edition");
      } catch (check) {
        if (check.code !== "ENOENT") throw check;
      }
    }
    const resources = path.join(stage, "resources");
    await fsp.mkdir(resources, { mode: 0o700 });
    for (const entry of context.entries) {
      checkAbort(options.signal);
      const output = path.join(resources, ...entry.safeName.split("/"));
      if (entry.directory) {
        await fsp.mkdir(output, { recursive: true, mode: 0o700 });
        continue;
      }
      await fsp.mkdir(path.dirname(output), { recursive: true, mode: 0o700 });
      const { stream, guard } = await entryStream(
        context.zip,
        entry,
        limits.entryBytes,
        options.signal,
      );
      await pipeline(
        stream,
        guard,
        ...(context.fonts.has(entry.safeName) ? [decodeFont(context.fonts.get(entry.safeName))] : []),
        fs.createWriteStream(output, { flags: "wx", mode: 0o600 }),
        { signal: options.signal },
      );
    }
    const receipt = {
      schemaVersion: 1,
      editionId,
      publication: context.publication,
    };
    await fsp.writeFile(
      path.join(stage, "publication.json"),
      JSON.stringify(receipt, null, 2),
      { flag: "wx", mode: 0o600 },
    );
    checkAbort(options.signal);
    context.zip.close();
    context = undefined;
    await fsp.rename(stage, destination);
    return {
      status: "imported",
      editionId,
      directory: destination,
      publication: receipt.publication,
    };
  } finally {
    context?.zip.close();
    await fsp.rm(stage, { recursive: true, force: true });
    if (lock) await fsp.rmdir(lock);
  }
}
