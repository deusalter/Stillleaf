const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { listLibrary, readerInput } = require("../src/library-store.cjs");
test("receipt-backed Library preserves corrupt records and rejects resource traversal", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "stillleaf-receipts-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const id = "a".repeat(64),
    other = "b".repeat(64);
  const dir = path.join(root, "editions", id);
  await fs.mkdir(path.join(dir, "resources"), { recursive: true });
  const publication = {
    title: "Local book",
    creators: ["Author"],
    spine: [
      {
        path: "chapter.xhtml",
        mediaType: "application/xhtml+xml",
        linear: true,
      },
    ],
    manifest: [{ path: "chapter.xhtml", mediaType: "application/xhtml+xml" }],
    cover: null,
  };
  await fs.writeFile(
    path.join(dir, "publication.json"),
    JSON.stringify({ schemaVersion: 1, editionId: id, publication }),
  );
  await fs.writeFile(
    path.join(dir, "resources", "chapter.xhtml"),
    "<html><body>Local.</body></html>",
  );
  await fs.mkdir(path.join(root, "editions", other));
  await fs.writeFile(
    path.join(root, "editions", other, "publication.json"),
    "bad JSON",
  );
  const state = await listLibrary(root);
  assert.equal(state.books.length, 1);
  assert.equal(state.warnings.length, 1);
  assert.equal(state.books[0].cover, null);
  assert.equal(
    await fs.readFile(
      path.join(root, "editions", other, "publication.json"),
      "utf8",
    ),
    "bad JSON",
  );
  assert.equal((await readerInput(root, id)).resources.length, 1);
  publication.manifest[0].path = "../publication.json";
  await fs.writeFile(
    path.join(dir, "publication.json"),
    JSON.stringify({ schemaVersion: 1, editionId: id, publication }),
  );
  await assert.rejects(readerInput(root, id), /Invalid publication resource/);
});
test("Library listing reuses unchanged editions and notices changed receipts", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "stillleaf-listing-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const id = "c".repeat(64),
    dir = path.join(root, "editions", id),
    receipt = path.join(dir, "publication.json");
  await fs.mkdir(path.join(dir, "resources"), { recursive: true });
  const publication = {
    title: "Cached book",
    creators: [],
    spine: [],
    manifest: [{ path: "cover.png", mediaType: "image/png" }],
    cover: { path: "cover.png", mediaType: "image/png" },
  };
  await fs.writeFile(
    receipt,
    JSON.stringify({ schemaVersion: 1, editionId: id, publication }),
  );
  await fs.writeFile(path.join(dir, "resources", "cover.png"), "first");
  const first = await listLibrary(root);
  assert.match(first.books[0].cover, /base64,Zmlyc3Q=$/);
  // Returned entries are copies, so a caller cannot alter the next listing.
  first.books[0].title = "Changed by caller";
  assert.equal((await listLibrary(root)).books[0].title, "Cached book");
  await fs.writeFile(receipt, "bad JSON");
  const damaged = await listLibrary(root);
  assert.equal(damaged.books.length, 0);
  assert.equal(damaged.warnings.length, 1);
  await fs.writeFile(
    receipt,
    JSON.stringify({
      schemaVersion: 1,
      editionId: id,
      publication: { ...publication, title: "Renamed" },
    }),
  );
  assert.equal((await listLibrary(root)).books[0].title, "Renamed");
  await fs.rm(dir, { recursive: true });
  assert.deepEqual(await listLibrary(root), { books: [], warnings: [] });
});
const {
  emptyState,
  loadReaderState,
  saveReaderState,
} = require("../src/reader-state.cjs");
const { removeAssets } = require("../src/removal.cjs");
async function importedFixture(t) {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), "stillleaf-state-"));
  t.after(() => fs.rm(temp, { recursive: true, force: true }));
  const { epub, zip } =
    await import("../../packages/publication/test/fixtures.js");
  const { importEPUB } = await import("../../packages/publication/index.js");
  const source = path.join(temp, "source.epub"),
    root = path.join(temp, "library");
  await fs.writeFile(source, zip(epub()));
  return { temp, source, root, ...(await importEPUB(source, root)) };
}
function stateWithNote(id) {
  const state = emptyState(id),
    locator = {
      href: "EPUB/chapter.xhtml",
      type: "text/html",
      locations: { progression: 0.4 },
    };
  state.revision = 1;
  state.position = locator;
  state.bookmarks = [
    {
      id: "b1",
      locator,
      label: "My place",
      createdAt: "2026-01-01T01:02:03.000Z",
    },
  ];
  state.annotations = [
    {
      id: "a1",
      locator,
      quote: "Synthetic reading",
      note: "Private note",
      color: "yellow",
      createdAt: "2026-01-01T01:02:03.000Z",
      updatedAt: "2026-01-01T01:02:03.000Z",
    },
  ];
  return state;
}
test("versioned locator/annotations persist, stale events rejected, corrupt primary recovers backup", async (t) => {
  const f = await importedFixture(t),
    state = stateWithNote(f.editionId);
  await saveReaderState(f.root, f.editionId, f.publication, state);
  state.revision = 2;
  state.annotations[0].note = "New note";
  await saveReaderState(f.root, f.editionId, f.publication, state);
  assert.equal(
    (await readerInput(f.root, f.editionId)).state.annotations[0].note,
    "New note",
  );
  await saveReaderState(f.root, f.editionId, f.publication, {
    ...state,
    revision: 1,
    annotations: [],
  });
  assert.equal(
    (await loadReaderState(f.root, f.editionId, f.publication)).state.revision,
    2,
  );
  const file = path.join(f.root, "reader-state", f.editionId + ".json");
  await fs.writeFile(file, "damaged");
  const recovered = await loadReaderState(f.root, f.editionId, f.publication);
  assert.equal(recovered.state.revision, 1);
  assert.match(recovered.warning, /Recovered/);
  await saveReaderState(f.root, f.editionId, f.publication, {
    ...recovered.state,
    revision: 3,
  });
  assert.equal(
    (await loadReaderState(f.root, f.editionId, f.publication)).state.revision,
    3,
  );
  assert.ok(
    (await fs.readdir(path.dirname(file))).some((x) =>
      x.includes(".recovery-"),
    ),
  );
});
test("state rejects unknown locations, forged edition and unreasonable payloads", async (t) => {
  const f = await importedFixture(t),
    state = stateWithNote(f.editionId);
  for (const forged of [
    { ...state, editionId: "b".repeat(64) },
    { ...state, position: { href: "../outside" } },
    {
      ...state,
      annotations: [{ ...state.annotations[0], note: "x".repeat(65537) }],
    },
    { ...state, preferences: { ...state.preferences, fontSize: 10000 } },
  ])
    assert.throws(() =>
      saveReaderState(f.root, f.editionId, f.publication, forged),
    );
});
test("keep EPUB saves exact usable copy then trashes only managed assets; state and journal retained", async (t) => {
  const f = await importedFixture(t),
    state = stateWithNote(f.editionId);
  await saveReaderState(f.root, f.editionId, f.publication, state);
  const sourceBytes = await fs.readFile(f.source),
    keepAt = path.join(f.temp, "kept.epub"),
    trashed = path.join(f.temp, "fixture-trash");
  const result = await removeAssets(f.root, f.editionId, {
    keepAt,
    trashItem: async (file) => {
      assert.equal(file, f.directory);
      await fs.rename(file, trashed);
    },
  });
  assert.equal(result.removed, true);
  assert.deepEqual(await fs.readFile(keepAt), sourceBytes);
  assert.deepEqual(await fs.readFile(f.source), sourceBytes);
  assert.equal((await listLibrary(f.root)).books.length, 0);
  assert.equal(
    (await loadReaderState(f.root, f.editionId, f.publication)).state
      .annotations[0].note,
    "Private note",
  );
  const record = JSON.parse(
    await fs.readFile(path.join(f.root, "retained", f.editionId + ".json")),
  );
  assert.equal(record.assetDisposition, "removed");
  assert.equal(record.publication.title, "Fixture");
});
test("keep export refuses overwrite or managed destination, cancellation does not invoke removal", async (t) => {
  const f = await importedFixture(t);
  let calls = 0;
  const trashItem = async () => {
    calls++;
  };
  const target = path.join(f.temp, "existing.epub");
  await fs.writeFile(target, "keep this");
  await assert.rejects(
    removeAssets(f.root, f.editionId, { keepAt: target, trashItem }),
  );
  assert.equal(await fs.readFile(target, "utf8"), "keep this");
  await assert.rejects(
    removeAssets(f.root, f.editionId, {
      keepAt: path.join(f.directory, "new.epub"),
      trashItem,
    }),
    /outside/,
  );
  assert.equal(calls, 0);
  assert.equal((await listLibrary(f.root)).books.length, 1);
});
test("Trash failure retains Library/assets/history and reports successful export honestly", async (t) => {
  const f = await importedFixture(t),
    keepAt = path.join(f.temp, "kept.epub");
  await assert.rejects(
    removeAssets(f.root, f.editionId, {
      keepAt,
      trashItem: async () => {
        throw Error("fixture unavailable");
      },
    }),
    /exported EPUB is available/,
  );
  assert.equal((await listLibrary(f.root)).books.length, 1);
  assert.deepEqual(await fs.readFile(keepAt), await fs.readFile(f.source));
  assert.equal(
    JSON.parse(
      await fs.readFile(path.join(f.root, "retained", f.editionId + ".json")),
    ).assetDisposition,
    "available",
  );
});
test("delete choice uses Trash without touching external original", async (t) => {
  const f = await importedFixture(t),
    before = await fs.readFile(f.source);
  await removeAssets(f.root, f.editionId, {
    trashItem: async (file) =>
      fs.rename(file, path.join(f.temp, "fixture-trash")),
  });
  assert.deepEqual(await fs.readFile(f.source), before);
  assert.equal((await listLibrary(f.root)).books.length, 0);
});
test("Trash error after actual move reports removed assets truthfully", async (t) => {
  const f = await importedFixture(t);
  const outcome = await removeAssets(f.root, f.editionId, {
    trashItem: async (file) => {
      await fs.rename(file, path.join(f.temp, "fixture-trash"));
      throw Error("late fixture failure");
    },
  });
  assert.equal(outcome.removed, true);
  assert.match(outcome.warning, /operating system reported an error/);
  assert.equal((await listLibrary(f.root)).books.length, 0);
});
test("damaged managed original cannot produce a misleading kept EPUB", async (t) => {
  const f = await importedFixture(t),
    target = path.join(f.temp, "kept.epub");
  await fs.writeFile(path.join(f.directory, "original.epub"), "broken");
  let called = false;
  await assert.rejects(
    removeAssets(f.root, f.editionId, {
      keepAt: target,
      trashItem: async () => {
        called = true;
      },
    }),
    /damaged/,
  );
  assert.equal(called, false);
  await assert.rejects(fs.stat(target), (e) => e.code === "ENOENT");
  assert.equal((await listLibrary(f.root)).books.length, 1);
});
test("annotation DOM ranges survive validation and restart", async (t) => {
  const f = await importedFixture(t),
    state = stateWithNote(f.editionId);
  const domRange = {
    start: {
      cssSelector: "body > p:nth-of-type(1)",
      textNodeIndex: 0,
      charOffset: 0,
    },
    end: {
      cssSelector: "body > p:nth-of-type(1)",
      textNodeIndex: 0,
      charOffset: 9,
    },
  };
  state.annotations[0].locator.locations.domRange = domRange;
  await saveReaderState(f.root, f.editionId, f.publication, state);
  assert.deepEqual(
    (await loadReaderState(f.root, f.editionId, f.publication)).state
      .annotations[0].locator.locations.domRange,
    domRange,
  );
});

test("optional advanced preferences preserve exact values across state restart", async (t) => {
  const f = await importedFixture(t), state = stateWithNote(f.editionId);
  const advanced = {scroll: true, fontWeight: 550.5, textAlign: "justify", hyphens: false, letterSpacing: 0.125, wordSpacing: 1, columns: "two"};
  Object.assign(state.preferences, advanced);
  await saveReaderState(f.root, f.editionId, f.publication, state);
  const restored = (await loadReaderState(f.root, f.editionId, f.publication)).state;
  assert.deepEqual(restored.preferences, state.preferences);
  state.revision++;
  state.preferences.fontWeight = null; state.preferences.hyphens = null;
  await saveReaderState(f.root, f.editionId, f.publication, state);
  assert.deepEqual((await loadReaderState(f.root, f.editionId, f.publication)).state.preferences, state.preferences);
});

test("advanced preference validation rejects wrong types and accepts absent legacy values", () => {
  const {validateState, emptyState} = require("../src/reader-state.cjs");
  const id = "a".repeat(64), publication = {manifest: [{path: "chapter.xhtml"}]};
  const legacy = emptyState(id);
  assert.deepEqual(validateState(legacy, id, publication).preferences, legacy.preferences);
  for (const [key, value] of [["scroll", 1], ["scroll", null], ["fontWeight", true], ["fontWeight", 99], ["fontWeight", 1001], ["fontWeight", Infinity], ["textAlign", "center"], ["hyphens", 0], ["letterSpacing", true], ["letterSpacing", -0.1], ["wordSpacing", 1.1], ["wordSpacing", NaN], ["columns", "three"]]) {
    const state = structuredClone(legacy); state.preferences[key] = value;
    assert.throws(() => validateState(state, id, publication), /Invalid/, key);
  }
  const unknown = structuredClone(legacy); unknown.preferences.untrustedCSS = "url(https://example.invalid)";
  assert.equal(validateState(unknown, id, publication).preferences.untrustedCSS, undefined);
});
