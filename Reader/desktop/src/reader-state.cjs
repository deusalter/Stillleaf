"use strict";
const fs = require("node:fs/promises"),
  path = require("node:path"),
  crypto = require("node:crypto");
const identity = /^[a-f0-9]{64}$/;
const MAX_BYTES = 2 * 1024 * 1024;
function checkedID(id) {
  if (typeof id !== "string" || !identity.test(id))
    throw Error("Invalid edition identity");
  return id;
}
function text(value, max, label) {
  if (typeof value !== "string" || value.length > max)
    throw Error("Invalid " + label);
  return value;
}
function timestamp(value) {
  text(value, 64, "annotation timestamp");
  if (!Number.isFinite(Date.parse(value)))
    throw Error("Invalid annotation timestamp");
  return value;
}
function validateLocator(value, paths) {
  if (value === null) return null;
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    !paths.has(value.href)
  )
    throw Error("Reader location references unknown resource");
  const locator = {
    href: value.href,
    type: text(value.type || "application/xhtml+xml", 128, "location type"),
  };
  if (value.title !== undefined)
    locator.title = text(value.title, 4096, "location title");
  if (value.locations !== undefined) {
    const p = value.locations;
    if (!p || typeof p !== "object" || Array.isArray(p))
      throw Error("Invalid location");
    locator.locations = {};
    for (const key of ["progression", "totalProgression"])
      if (p[key] !== undefined) {
        if (!Number.isFinite(p[key]) || p[key] < 0 || p[key] > 1)
          throw Error("Invalid location progression");
        locator.locations[key] = p[key];
      }
    if (p.position !== undefined) {
      if (!Number.isSafeInteger(p.position) || p.position < 1)
        throw Error("Invalid position");
      locator.locations.position = p.position;
    }
    if (p.fragments !== undefined) {
      if (!Array.isArray(p.fragments) || p.fragments.length > 20)
        throw Error("Invalid location fragments");
      locator.locations.fragments = p.fragments.map((v) =>
        text(v, 8192, "fragment"),
      );
    }
    if (p.domRange !== undefined) {
      if (!p.domRange || typeof p.domRange !== "object")
        throw Error("Invalid DOM range");
      const point = (value) => {
        if (!value || typeof value !== "object")
          throw Error("Invalid DOM range point");
        const out = {
          cssSelector: text(value.cssSelector, 8192, "DOM selector"),
        };
        for (const key of ["textNodeIndex", "charOffset"])
          if (value[key] !== undefined) {
            if (
              !Number.isSafeInteger(value[key]) ||
              value[key] < 0 ||
              value[key] > 10000000
            )
              throw Error("Invalid DOM range offset");
            out[key] = value[key];
          }
        return out;
      };
      locator.locations.domRange = {
        start: point(p.domRange.start),
        end: point(p.domRange.end),
      };
    }
    for (const key of ["cssSelector", "partialCfi"])
      if (p[key] !== undefined)
        locator.locations[key] = text(p[key], 8192, key);
  }
  if (value.text !== undefined) {
    const t = value.text;
    if (!t || typeof t !== "object") throw Error("Invalid location text");
    locator.text = {};
    for (const key of ["before", "highlight", "after"])
      if (t[key] !== undefined)
        locator.text[key] = text(t[key], 16384, "location context");
  }
  return locator;
}
// Appearance ids shared with Reader/desktop/reader/src/appearance.js and the Mac
// validator (ReaderStateValidation). Ids are never renamed once saved.
const THEMES = ["system", "original", "paper", "sepia", "calm", "focus", "quiet", "dark", "night", "white", "stone", "mist", "forest", "dusk", "midnight", "custom"];
const FONT_FAMILIES = ["publisher", "newyork", "sans", "athelas", "charter", "serif", "iowan", "palatino", "seravek", "times", "literata", "source-serif", "lora", "libre-baskerville", "atkinson", "inter", "nunito", "source-sans", "georgia", "monospace"];
const MARGINS = ["narrow", "normal", "wide"];
function emptyState(id) {
  return {
    schemaVersion: 1,
    editionId: checkedID(id),
    revision: 0,
    position: null,
    preferences: {
      theme: "system",
      fontFamily: "publisher",
      fontSize: 1.2,
      lineHeight: 1.6,
      measure: 65,
    },
    bookmarks: [],
    annotations: [],
  };
}
function validateState(value, id, publication) {
  checkedID(id);
  if (
    !value ||
    JSON.stringify(value).length > MAX_BYTES ||
    value.schemaVersion !== 1 ||
    value.editionId !== id ||
    !Number.isSafeInteger(value.revision) ||
    value.revision < 0
  )
    throw Error("Invalid reader state");
  const paths = new Set(publication.manifest.map((x) => x.path)),
    result = emptyState(id);
  result.revision = value.revision;
  result.position = validateLocator(value.position ?? null, paths);
  const p = value.preferences;
  if (
    !p ||
    !THEMES.includes(p.theme) ||
    !FONT_FAMILIES.includes(p.fontFamily)
  )
    throw Error("Invalid reader preferences");
  result.preferences = { theme: p.theme, fontFamily: p.fontFamily };
  for (const [key, min, max] of [
    ["fontSize", 0.5, 3],
    ["lineHeight", 1, 3],
    ["measure", 20, 120],
  ]) {
    if (!Number.isFinite(p[key]) || p[key] < min || p[key] > max)
      throw Error("Invalid " + key);
    result.preferences[key] = p[key];
  }
  for (const key of ["scroll", "hyphens", "immersive"]) {
    if (p[key] !== undefined) {
      if (!(key === "hyphens" && p[key] === null) && typeof p[key] !== "boolean")
        throw Error("Invalid " + key);
      result.preferences[key] = p[key];
    }
  }
  if (p.fontWeight !== undefined) {
    if (p.fontWeight !== null && (!Number.isFinite(p.fontWeight) || p.fontWeight < 100 || p.fontWeight > 1000))
      throw Error("Invalid fontWeight");
    result.preferences.fontWeight = p.fontWeight;
  }
  for (const key of ["letterSpacing", "wordSpacing"]) {
    if (p[key] !== undefined) {
      if (!Number.isFinite(p[key]) || p[key] < 0 || p[key] > 1) throw Error("Invalid " + key);
      result.preferences[key] = p[key];
    }
  }
  for (const [key, min, max] of [["contentWidth", 40, 100], ["sideMargin", 0, 96]]) {
    if (p[key] !== undefined) {
      if (key === "sideMargin" && p[key] === null) { result.preferences[key] = null; continue; }
      if (!Number.isFinite(p[key]) || p[key] < min || p[key] > max) throw Error("Invalid " + key);
      result.preferences[key] = p[key];
    }
  }
  for (const key of ["backgroundColor", "textColor"]) {
    if (p[key] !== undefined) {
      if (p[key] !== null && (typeof p[key] !== "string" || p[key].length !== 7 || !/^#[0-9a-fA-F]{6}$/.test(p[key]))) throw Error("Invalid " + key);
      result.preferences[key] = p[key];
    }
  }
  for (const [key, allowed] of [["textAlign", ["publisher", "start", "justify"]], ["columns", ["one", "two"]], ["margins", MARGINS]]) {
    if (p[key] !== undefined) {
      if (!allowed.includes(p[key])) throw Error("Invalid " + key);
      result.preferences[key] = p[key];
    }
  }
  for (const key of ["bookmarks", "annotations"]) {
    if (!Array.isArray(value[key]) || value[key].length > 2000)
      throw Error("Too many " + key);
    const ids = new Set();
    result[key] = value[key].map((item) => {
      if (!item || typeof item !== "object") throw Error("Invalid saved item");
      const itemID = text(item.id, 128, "item identity");
      if (!itemID || ids.has(itemID)) throw Error("Duplicate saved identity");
      ids.add(itemID);
      const out = {
        id: itemID,
        locator: validateLocator(item.locator, paths),
        createdAt: timestamp(item.createdAt),
      };
      if (!out.locator) throw Error("Missing saved location");
      if (key === "bookmarks")
        out.label = text(item.label ?? "", 4096, "bookmark label");
      else {
        out.quote = text(item.quote ?? "", 32768, "highlight text");
        out.note = text(item.note ?? "", 65536, "note");
        out.color = text(item.color ?? "yellow", 64, "highlight color");
        out.updatedAt = timestamp(item.updatedAt);
      }
      return out;
    });
  }
  return result;
}
async function directory(root, name) {
  const dest = path.join(root, name);
  await fs.mkdir(dest, { recursive: true, mode: 0o700 });
  const stat = await fs.lstat(dest);
  if (!stat.isDirectory() || stat.isSymbolicLink())
    throw Error("Unsafe state directory");
  return dest;
}
async function readJSON(file) {
  const stat = await fs.lstat(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_BYTES)
    throw Error("Unsafe or oversized saved state");
  return JSON.parse(await fs.readFile(file, "utf8"));
}
async function atomicJSON(file, value, { backup = true } = {}) {
  const temporary = file + ".tmp-" + crypto.randomUUID();
  const data = JSON.stringify(value, null, 2);
  if (Buffer.byteLength(data) > MAX_BYTES)
    throw Error("Saved state exceeds size limit");
  let handle;
  try {
    handle = await fs.open(temporary, "wx", 0o600);
    await handle.writeFile(data);
    await handle.sync();
    await handle.close();
    handle = null;
    try {
      const stat = await fs.lstat(file);
      if (!stat.isFile() || stat.isSymbolicLink())
        throw Error("Unsafe saved state");
      if (backup) {
        const old = await fs.readFile(file);
        const backupTemp = file + ".bak.tmp-" + crypto.randomUUID();
        try {
          await fs.writeFile(backupTemp, old, { flag: "wx", mode: 0o600 });
          await fs.rename(backupTemp, file + ".bak");
        } finally {
          await fs.rm(backupTemp, { force: true });
        }
      }
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    await fs.rename(temporary, file);
  } finally {
    await handle?.close();
    await fs.rm(temporary, { force: true });
  }
}
async function loadReaderState(root, id, publication) {
  checkedID(id);
  const dir = await directory(root, "reader-state"),
    file = path.join(dir, id + ".json");
  try {
    return {
      state: validateState(await readJSON(file), id, publication),
      warning: null,
    };
  } catch (error) {
    if (error.code === "ENOENT") {
      try {
        const state = validateState(
          await readJSON(file + ".bak"),
          id,
          publication,
        );
        return { state, warning: "Recovered reader state from backup." };
      } catch (backupError) {
        if (backupError.code === "ENOENT")
          return { state: emptyState(id), warning: null };
        throw backupError;
      }
    }
    try {
      return {
        state: validateState(await readJSON(file + ".bak"), id, publication),
        warning:
          "Recovered reader state from backup; original file preserved until next successful save.",
      };
    } catch {
      throw Error("Reader state is damaged; files preserved for recovery.");
    }
  }
}
const writes = new Map();
function saveReaderState(root, id, publication, value) {
  const key = path.resolve(root) + ":" + checkedID(id),
    next = validateState(value, id, publication);
  const task = (writes.get(key) || Promise.resolve())
    .catch(() => {})
    .then(async () => {
      const previous = await loadReaderState(root, id, publication);
      if (next.revision < previous.state.revision) return previous.state;
      const dir = await directory(root, "reader-state");
      const file = path.join(dir, id + ".json");
      if (previous.warning) {
        const recovery = file + ".recovery-" + crypto.randomUUID();
        try {
          await fs.copyFile(
            file,
            recovery,
            require("node:fs").constants.COPYFILE_EXCL,
          );
        } catch (error) {
          if (error.code !== "ENOENT") throw error;
        }
      }
      await atomicJSON(file, next, { backup: !previous.warning });
      return next;
    });
  writes.set(key, task);
  task
    .finally(() => {
      if (writes.get(key) === task) writes.delete(key);
    })
    .catch(() => {});
  return task;
}
module.exports = {
  THEMES,
  FONT_FAMILIES,
  MARGINS,
  checkedID,
  emptyState,
  validateState,
  loadReaderState,
  saveReaderState,
  atomicJSON,
  directory,
  readJSON,
};
