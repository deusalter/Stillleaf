const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { THEMES, FONT_FAMILIES, MARGINS, validateState, emptyState } = require("../src/reader-state.cjs");

// The renderer writes these ids; if this host's lists drift, saving a new choice fails.
const source = fs.readFileSync(path.join(__dirname, "../reader/src/appearance.js"), "utf8");
const ids = (start, end) => {
  const section = source.slice(source.indexOf(start), source.indexOf(end));
  return [...section.matchAll(/\{id:'([a-z-]+)'/g)].map((m) => m[1]).sort();
};

test("host appearance ids match the shared renderer", () => {
  assert.deepEqual([...THEMES].sort(), [...ids("export const THEMES", "export const THEME_IDS"), "system"].sort());
  assert.deepEqual([...FONT_FAMILIES].sort(), ids("export const FONTS", "export const FONT_IDS"));
  const margins = source.slice(source.indexOf("export const MARGINS"), source.indexOf("export const MARGIN_IDS"));
  assert.deepEqual([...MARGINS].sort(), [...margins.matchAll(/ ([a-z-]+):\{label:/g)].map((m) => m[1]).sort());
});

test("every appearance choice is saved and unknown ones are rejected", () => {
  const id = "a".repeat(64), publication = { manifest: [{ path: "chapter.xhtml" }] };
  const state = (preferences) => ({ ...emptyState(id), preferences: { ...emptyState(id).preferences, ...preferences } });
  for (const [key, values] of [["theme", THEMES], ["fontFamily", FONT_FAMILIES], ["margins", MARGINS]]) {
    for (const value of values) assert.equal(validateState(state({ [key]: value }), id, publication).preferences[key], value, `${key}=${value}`);
    assert.throws(() => validateState(state({ [key]: "unknown" }), id, publication), key);
  }
});
