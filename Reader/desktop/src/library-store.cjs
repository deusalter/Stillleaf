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
async function resourceBytes(root, id, href) {
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
  return fs.readFile(current);
}
async function listLibrary(root) {
  const editions = await fs.readdir(path.join(root, "editions")).catch((e) => {
    if (e.code === "ENOENT") return [];
    throw e;
  });
  const books = [],
    warnings = [];
  for (const id of editions.filter((x) => editionPattern.test(x)).sort()) {
    try {
      const { publication: p } = await readEdition(root, id);
      let cover = null;
      if (
        p.cover &&
        ["image/png", "image/jpeg", "image/gif", "image/webp"].includes(
          p.cover.mediaType,
        )
      )
        cover =
          "data:" +
          p.cover.mediaType +
          ";base64," +
          (await resourceBytes(root, id, p.cover.path)).toString("base64");
      books.push({
        editionId: id,
        title: p.title || "Untitled",
        creators: p.creators || [],
        cover,
        coverProvenance: cover ? "epub-metadata" : "local-placeholder",
      });
    } catch (error) {
      warnings.push({ editionId: id, message: error.message });
    }
  }
  return { books, warnings };
}
async function readerInput(root, id) {
  const { publication: p } = await readEdition(root, id);
  let total = 0;
  const resources = [];
  for (const item of p.manifest) {
    const bytes = await resourceBytes(root, id, item.path);
    total += bytes.length;
    if (total > 256 * 1024 * 1024)
      throw Error("Book exceeds reader memory budget");
    resources.push({
      href: item.path,
      type: item.mediaType,
      dataBase64: bytes.toString("base64"),
    });
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
module.exports = { listLibrary, readerInput, readEdition, resourceBytes };
