"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { emptyState, validateState, saveReaderState, loadReaderState } = require("../src/reader-state.cjs");
const { exportState, previewImport, applyImport } = require("../src/reader-state-transfer.cjs");
const id = "a".repeat(64), publication = { manifest: [{ path: "chapter.xhtml" }] };
const fonts = ["publisher", "serif", "sans", "literata", "source-serif", "lora", "libre-baskerville", "atkinson", "inter", "nunito", "source-sans", "georgia", "palatino", "monospace"];
const themes = ["system", "paper", "sepia", "dark", "white", "stone", "mist", "forest", "dusk", "midnight", "custom"];
test("legacy preferences stay unchanged and every supported appearance ID validates", () => {
  const state = emptyState(id);
  assert.deepEqual(validateState(state, id, publication).preferences, state.preferences);
  for (const fontFamily of fonts) for (const theme of themes) {
    const value = structuredClone(state);
    Object.assign(value.preferences, {fontFamily, theme, contentWidth: 100, sideMargin: 0, immersive: true, backgroundColor: "#aBcD12", textColor: "#112233"});
    assert.deepEqual(validateState(value, id, publication).preferences, value.preferences);
  }
  for (const [key, value] of [["contentWidth", 40], ["contentWidth", 90.25], ["sideMargin", 96], ["sideMargin", 32.5], ["immersive", false], ["backgroundColor", null], ["textColor", null]]) {
    const candidate = structuredClone(state); candidate.preferences[key] = value;
    assert.deepEqual(validateState(candidate, id, publication).preferences, candidate.preferences);
  }
});
test("appearance rejects out-of-range, coerced, and CSS payloads", () => {
  const invalid = [["fontFamily", "unknown-font"], ["theme", "unknown-theme"], ["contentWidth", true], ["contentWidth", 39.99], ["contentWidth", 100.01], ["contentWidth", null], ["sideMargin", false], ["sideMargin", -0.01], ["sideMargin", 96.01], ["sideMargin", "32"], ["sideMargin", Infinity], ["contentWidth", NaN], ["immersive", 1], ["immersive", null]];
  for (const key of ["backgroundColor", "textColor"]) for (const value of ["red", "#fff", "#11223344", "#12345g", " #112233", "#112233\n", "rgb(1,2,3)", "url(https://example.invalid)", true, 123, {}]) invalid.push([key, value]);
  for (const [key, value] of invalid) {
    const state = emptyState(id); state.preferences[key] = value;
    assert.throws(() => validateState(state, id, publication), undefined, key + ": " + String(value));
  }
});
test("appearance survives durable restart and portable transfer with exact color case and null", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "stillleaf-appearance-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const source = path.join(root, "source"), destination = path.join(root, "destination"), file = path.join(root, "state.json");
  const state = emptyState(id); state.revision = 2;
  Object.assign(state.preferences, { fontFamily: "literata", theme: "custom", contentWidth: 97.5, sideMargin: 14.25, immersive: true, backgroundColor: "#aBcD12", textColor: null, scroll: true, columns: "two" });
  state.position = { href: "chapter.xhtml", type: "application/xhtml+xml", locations: { cssSelector: "#passage", progression: 0.25 } };
  await saveReaderState(source, id, publication, state);
  assert.deepEqual((await loadReaderState(source, id, publication)).state, state);
  await exportState(source, id, publication, file);
  const preview = await previewImport(destination, id, publication, file);
  await applyImport(preview);
  assert.deepEqual((await loadReaderState(destination, id, publication)).state, state);
});
