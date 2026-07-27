"use strict";
const fs = require("node:fs/promises"),
  rawFS = require("node:fs"),
  path = require("node:path"),
  crypto = require("node:crypto");
const { readEdition } = require("./library-store.cjs");
const { checkedID, atomicJSON, directory } = require("./reader-state.cjs");
async function exportOriginal(root, id, target) {
  checkedID(id);
  if (
    typeof target !== "string" ||
    !path.isAbsolute(target) ||
    path.extname(target).toLowerCase() !== ".epub"
  )
    throw Error("Choose an EPUB destination");
  const managed = await fs.realpath(root),
    parent = await fs.realpath(path.dirname(target));
  const relative = path.relative(managed, parent);
  if (
    relative === "" ||
    (relative !== ".." &&
      !relative.startsWith(".." + path.sep) &&
      !path.isAbsolute(relative))
  )
    throw Error("Save the retained EPUB outside Stillleaf managed storage");
  const original = path.join(root, "editions", id, "original.epub");
  const stat = await fs.lstat(original);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 128 * 1024 * 1024)
    throw Error("Managed original is unavailable or unsafe");
  const handle = await fs.open(target, "wx", 0o600);
  let success = false,
    count = 0;
  const hash = crypto.createHash("sha256");
  try {
    for await (const chunk of rawFS.createReadStream(original)) {
      count += chunk.length;
      if (count > 128 * 1024 * 1024) throw Error("EPUB exceeds export limit");
      hash.update(chunk);
      await handle.writeFile(chunk);
    }
    await handle.sync();
    if (hash.digest("hex") !== id)
      throw Error("Managed EPUB is damaged; no valid copy was exported");
    success = true;
    return target;
  } finally {
    await handle.close();
    if (!success) await fs.rm(target, { force: true });
  }
}
async function removeAssets(root, id, { keepAt = null, trashItem }) {
  checkedID(id);
  if (typeof trashItem !== "function") throw Error("Trash service unavailable");
  const receipt = await readEdition(root, id);
  const editionDirectory = path.join(root, "editions", id);
  let exported = null;
  if (keepAt) exported = await exportOriginal(root, id, keepAt);
  const retainedDirectory = await directory(root, "retained"),
    file = path.join(retainedDirectory, id + ".json");
  const record = {
    schemaVersion: 1,
    editionId: id,
    publication: receipt.publication,
    assetDisposition: "removal-requested",
    requestedAt: new Date().toISOString(),
    retainedEPUB: exported,
  };
  await atomicJSON(file, record);
  let trashError = null;
  try {
    await trashItem(editionDirectory);
  } catch (error) {
    trashError = error;
  }
  let remains = true;
  try {
    await fs.lstat(editionDirectory);
  } catch (error) {
    if (error.code === "ENOENT") remains = false;
    else throw error;
  }
  if (remains) {
    await atomicJSON(file, {
      ...record,
      assetDisposition: "available",
      failure: "Trash did not remove the managed directory.",
    });
    throw Error(
      "Could not move managed files to Trash. The managed directory remains and reading state is preserved." +
        (exported
          ? " Your exported EPUB is available at " + exported + "."
          : "") +
        (trashError ? " " + trashError.message : ""),
    );
  }
  let warning = trashError
    ? "Managed files are no longer present after the Trash request, but the operating system reported an error. Verify Trash; reading state is preserved."
    : null;
  try {
    await atomicJSON(file, {
      ...record,
      assetDisposition: "removed",
      removedAt: new Date().toISOString(),
    });
  } catch {
    warning =
      "Files moved to Trash. Retained journal record is pending reconciliation.";
  }
  return { removed: true, exported, warning };
}
module.exports = { removeAssets, exportOriginal };
