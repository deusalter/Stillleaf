"use strict";
const fs = require("node:fs/promises"),
  path = require("node:path");
const { loadReaderState } = require("./reader-state.cjs");
const editionPattern = /^[a-f0-9]{64}$/;
async function readEdition(root, id) {
  if (!editionPattern.test(id)) throw Error("Invalid edition identity");
  const dir = path.join(root, "editions", id),
    file = path.join(dir, "publication.json");
  for (const p of [dir, file]) {
    const stat = await fs.lstat(p);
    if (stat.isSymbolicLink())
      throw Error("Unexpected linked library resource");
  }
  const stat = await fs.stat(file);
  if (stat.size > 4 * 1024 * 1024) throw Error("Oversized publication receipt");
  const receipt = JSON.parse(await fs.readFile(file, "utf8"));
  if (
    receipt.schemaVersion !== 1 ||
    receipt.editionId !== id ||
    !Array.isArray(receipt.publication?.manifest) ||
    !Array.isArray(receipt.publication?.spine)
  )
    throw Error("Invalid publication receipt");
  return receipt;
}
/** Validated on-disk location and size of one publication resource. */
async function resourceFile(root, id, href) {
  if (
    typeof href !== "string" ||
    href.split("/").some((p) => !p || p === "." || p === "..") ||
    /[:\\%?#\0]/.test(href)
  )
    throw Error("Invalid publication resource");
  const base = path.join(root, "editions", id, "resources");
  let current = base;
  for (const part of ["", ...href.split("/")]) {
    current = path.join(current, part);
    const stat = await fs.lstat(current);
    if (stat.isSymbolicLink()) throw Error("Linked resources are unsupported");
  }
  const stat = await fs.stat(current);
  if (!stat.isFile() || stat.size > 32 * 1024 * 1024)
    throw Error("Oversized resource");
  return { file: current, size: stat.size };
}
async function resourceBytes(root, id, href) {
  return fs.readFile((await resourceFile(root, id, href)).file);
}
// Editions are content-addressed and never rewritten in place, so a book's
// Library entry is reused until the edition directory or its receipt changes on
// disk. The host lists the Library on every journal change, including reading
// checkpoints every few seconds. Covers are located, not read: the host serves
// their bytes by URL so each snapshot stays small.
const listings = new Map();
const copy = (book) => ({
  ...book,
  cover: book.cover && { ...book.cover },
});
async function listLibrary(root) {
  const base = path.join(root, "editions");
  const editions = await fs.readdir(base).catch((e) => {
    if (e.code === "ENOENT") return [];
    throw e;
  });
  const books = [],
    warnings = [],
    seen = new Set();
  for (const id of editions.filter((x) => editionPattern.test(x)).sort()) {
    const dir = path.join(base, id);
    seen.add(dir);
    try {
      const [folder, receipt] = await Promise.all([
        fs.lstat(dir),
        fs.lstat(path.join(dir, "publication.json")),
      ]);
      const signature = [folder, receipt]
        .map((s) => `${s.dev}:${s.ino}:${s.size}:${s.mtimeMs}:${s.ctimeMs}`)
        .join("/");
      const cached = listings.get(dir);
      if (cached?.signature === signature) {
        books.push(copy(cached.book));
        continue;
      }
      listings.delete(dir);
      const { publication: p } = await readEdition(root, id);
      let cover = null;
      if (
        p.cover &&
        ["image/png", "image/jpeg", "image/gif", "image/webp"].includes(
          p.cover.mediaType,
        )
      )
        cover = {
          file: (await resourceFile(root, id, p.cover.path)).file,
          type: p.cover.mediaType,
        };
      const book = {
        editionId: id,
        title: p.title || "Untitled",
        creators: p.creators || [],
        cover,
        coverProvenance: cover ? "epub-metadata" : "local-placeholder",
      };
      listings.set(dir, { signature, book });
      books.push(copy(book));
    } catch (error) {
      listings.delete(dir);
      warnings.push({ editionId: id, message: error.message });
    }
  }
  for (const dir of listings.keys())
    if (path.dirname(dir) === base && !seen.has(dir)) listings.delete(dir);
  return { books, warnings };
}
/** With `serve`, resources are host-served: each entry carries the URL `serve`
 *  returns plus its size, and the reader fetches bytes only when a chapter needs
 *  them. Without it every resource is inlined as base64, which copies the whole
 *  book into the renderer; that form is kept for callers outside the app host. */
async function readerInput(root, id, { serve } = {}) {
  const { publication: p } = await readEdition(root, id);
  let total = 0;
  const resources = [];
  for (const [index, item] of p.manifest.entries()) {
    const { file, size } = await resourceFile(root, id, item.path);
    total += size;
    if (total > 256 * 1024 * 1024)
      throw Error("Book exceeds reader memory budget");
    resources.push(
      serve
        ? {
            href: item.path,
            type: item.mediaType,
            url: serve({ file, size, type: item.mediaType }, index),
            size,
          }
        : {
            href: item.path,
            type: item.mediaType,
            dataBase64: (await fs.readFile(file)).toString("base64"),
          },
    );
  }
  const saved = await loadReaderState(root, id, p);
  return {
    layout: p.layout,
    toc: p.toc,
    landmarks: p.landmarks,
    pageList: p.pageList,
    readingProgression: p.readingProgression,
    languages: p.languages,
    state: saved.state,
    stateWarning: saved.warning,
    editionId: id,
    title: p.title,
    creators: p.creators,
    language: p.languages?.[0],
    readingOrder: p.spine
      .filter((x) => x.linear)
      .map((x) => ({ href: x.path, type: x.mediaType })),
    resources,
  };
}
module.exports = {
  listLibrary,
  readerInput,
  readEdition,
  resourceBytes,
  resourceFile,
};
