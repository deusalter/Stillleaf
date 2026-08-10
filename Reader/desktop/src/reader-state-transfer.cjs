"use strict";
const fs = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const { checkedID, validateState, loadReaderState, saveReaderState } = require("./reader-state.cjs");
const MAX_BYTES = 2 * 1024 * 1024;
const previews = new WeakMap(), applying = new Map();
const digest = value => crypto.createHash("sha256").update(value).digest("hex");
function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map(key => [key, stable(value[key])]));
  return value;
}
const encode = value => Buffer.from(JSON.stringify(stable(value)));
async function current(root, id, publication) {
  for (const suffix of [".json", ".json.bak"]) {
    try { await fs.lstat(path.join(root, "reader-state", id + suffix)); return (await loadReaderState(root, id, publication)).state; }
    catch (error) { if (error.code !== "ENOENT") throw error; }
  }
  return null;
}
async function boundedInput(file) {
  if (!path.isAbsolute(file)) throw Error("Choose an absolute reader-state file path.");
  const stat = await fs.lstat(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_BYTES) throw Error("Choose a regular reader-state JSON file within the size limit.");
  const handle = await fs.open(file, "r"), chunks = [];
  let size = 0;
  try {
    for (;;) {
      const buffer = Buffer.alloc(65536), { bytesRead } = await handle.read(buffer, 0, buffer.length, null);
      if (!bytesRead) break;
      size += bytesRead;
      if (size > MAX_BYTES) throw Error("Reader-state file exceeds the size limit.");
      chunks.push(buffer.subarray(0, bytesRead));
    }
  } finally { await handle.close(); }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}
async function exportState(root, id, publication, destination) {
  checkedID(id);
  if (!path.isAbsolute(destination)) throw Error("Choose an absolute export path.");
  const state = await current(root, id, publication);
  if (!state) throw Error("This edition has no saved reader state to export.");
  const bytes = encode(validateState(state, id, publication));
  const temporary = path.join(path.dirname(destination), ".stillleaf-state-" + crypto.randomUUID());
  let handle;
  try {
    handle = await fs.open(temporary, "wx", 0o600);
    await handle.writeFile(bytes); await handle.sync(); await handle.close(); handle = null;
    // Same-directory hard link publishes the complete file without replacing any destination.
    await fs.link(temporary, destination);
    return { path: destination, bytes: bytes.length, sha256: digest(bytes) };
  } finally { await handle?.close(); await fs.rm(temporary, { force: true }); }
}
async function previewImport(root, id, publication, source) {
  checkedID(id);
  const incoming = validateState(await boundedInput(source), id, publication);
  const local = await current(root, id, publication);
  const incomingHash = digest(encode(incoming)), localHash = local ? digest(encode(local)) : null;
  const disposition = incomingHash === localHash ? "identical" : local && incoming.revision < local.revision ? "stale" : local ? "replacement" : "newEditionState";
  const preview = Object.freeze({ editionId: id, disposition, incomingRevision: incoming.revision, localRevision: local?.revision ?? null,
    incomingBookmarks: incoming.bookmarks.length, incomingAnnotations: incoming.annotations.length,
    localBookmarks: local?.bookmarks.length ?? 0, localAnnotations: local?.annotations.length ?? 0,
    incomingSHA256: incomingHash, localSHA256: localHash });
  previews.set(preview, { root, id, publication, incoming });
  return preview;
}
// Host must close/flush this edition and serialize reader operations for the whole preview/apply flow.
async function applyImport(preview, { replacingExisting = false } = {}) {
  const data = previews.get(preview);
  if (!data) throw Error("Review this reader-state import before applying it.");
  const key = path.resolve(data.root) + ":" + data.id;
  const task = (applying.get(key) || Promise.resolve()).catch(() => {}).then(async () => {
    const local = await current(data.root, data.id, data.publication);
    if ((local ? digest(encode(local)) : null) !== preview.localSHA256) throw Error("Local reading changes arrived after the preview. Review the import again.");
    if (preview.disposition === "identical") return false;
    if (preview.disposition === "stale") throw Error("The imported revision is older than local state. Nothing was changed.");
    if (preview.disposition === "replacement" && replacingExisting !== true) throw Error("Explicit replacement is required. Notes are not merged.");
    await saveReaderState(data.root, data.id, data.publication, data.incoming);
    return true;
  });
  applying.set(key, task);
  try { return await task; } finally { if (applying.get(key) === task) applying.delete(key); }
}
module.exports = { exportState, previewImport, applyImport };
