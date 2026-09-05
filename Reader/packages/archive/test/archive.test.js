import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { deflateRawSync } from "node:zlib";
import { createRequire } from "node:module";
import {
  exportArchive,
  inspectArchive,
  exportPreservedArchive,
  stageImport,
} from "../index.js";
import { exportNodeJournal } from "../node-journal.js";
const require = createRequire(import.meta.url),
  { JournalStore } = require("../../../desktop/src/journal/store.cjs");
const digest = (b) => createHash("sha256").update(b).digest("hex");
const native = {
  version: 1,
  exportedAt: 1700000000123,
  books: [],
  intervals: [],
  corrections: [{ id: "correction", unknown: ["keep", null] }],
  goals: [],
  events: [{ kind: "futureClear", evidence: null }],
  progress: [],
  merges: [{ active: false, sourceID: "old", targetID: "new" }],
  future: { authority: "preserve exactly" },
};
const producer = { host: "test", version: "0.1" };
const files = [
  {
    path: "journals/native.json",
    sourcePath: "history.json",
    role: "journal",
    format: "native-history-json",
    schemaVersion: 1,
  },
];
async function fixture(t) {
  const dir = await fs.mkdtemp(
    path.join(await fs.realpath(os.tmpdir()), "stillleaf-archive-"),
  );
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  await fs.writeFile(
    path.join(dir, "history.json"),
    JSON.stringify(native, null, 3) + "\n",
  );
  return dir;
}
async function exported(t) {
  const dir = await fixture(t),
    file = path.join(dir, "library.zip");
  await exportArchive({ sourceRoot: dir, files, producer }, file);
  return { dir, file };
}
const ct = Array.from({ length: 256 }, (_, n) => {
  for (let i = 0; i < 8; i++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1;
  return n >>> 0;
});
function crc(b) {
  let n = 0xffffffff;
  for (const v of b) n = ct[(n ^ v) & 255] ^ (n >>> 8);
  return (n ^ 0xffffffff) >>> 0;
}
// Independent hostile ZIP fixture builder, with deflate and Unix special-file support.
function zip(entries) {
  let offset = 0;
  const local = [],
    central = [];
  for (const [name, bytes, o = {}] of entries) {
    const n = Buffer.from(name),
      b = o.deflate ? deflateRawSync(bytes) : bytes,
      h = Buffer.alloc(30),
      c = Buffer.alloc(46);
    h.writeUInt32LE(0x04034b50);
    h.writeUInt16LE(20, 4);
    h.writeUInt16LE(0x800, 6);
    h.writeUInt16LE(o.deflate ? 8 : 0, 8);
    h.writeUInt32LE(crc(bytes), 14);
    h.writeUInt32LE(b.length, 18);
    h.writeUInt32LE(bytes.length, 22);
    h.writeUInt16LE(n.length, 26);
    c.writeUInt32LE(0x02014b50);
    c.writeUInt16LE(0x314, 4);
    c.writeUInt16LE(20, 6);
    c.writeUInt16LE(0x800, 8);
    c.writeUInt16LE(o.deflate ? 8 : 0, 10);
    c.writeUInt32LE(crc(bytes), 16);
    c.writeUInt32LE(b.length, 20);
    c.writeUInt32LE(bytes.length, 24);
    c.writeUInt16LE(n.length, 28);
    c.writeUInt32LE(((o.mode ?? 0o100600) << 16) >>> 0, 38);
    c.writeUInt32LE(offset, 42);
    local.push(h, n, b);
    central.push(c, n);
    offset += h.length + n.length + b.length;
  }
  const cd = Buffer.concat(central),
    end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(cd.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, cd, end]);
}
async function rewrite(t, change) {
  const { dir, file } = await exported(t),
    p = await inspectArchive(file),
    m = JSON.parse(JSON.stringify(p.manifest));
  let e = [
    ["manifest.json", Buffer.from(JSON.stringify(m))],
    ["journals/native.json", await fs.readFile(path.join(dir, "history.json"))],
  ];
  const result = change(m, e);
  if (result) e = result;
  else e[0][1] = Buffer.from(JSON.stringify(m));
  const target = path.join(dir, "changed.zip");
  await fs.writeFile(target, zip(e));
  return { dir, target };
}

test("native exact bytes, correction/merge/unknown fields survive stage and exact re-export", async (t) => {
  const { dir, file } = await exported(t),
    p = await inspectArchive(file);
  assert.equal(p.activation, "preservation-only");
  assert.equal(p.journalProjectionApplied, false);
  assert.ok(Object.isFrozen(p.manifest.entries));
  const r = await stageImport(p, path.join(dir, "stage"));
  assert.equal(r.state, "preserved");
  assert.deepEqual(
    await fs.readFile(path.join(dir, "stage/payloads/journals/native.json")),
    await fs.readFile(path.join(dir, "history.json")),
  );
  const copy = path.join(dir, "copy.zip");
  await exportPreservedArchive(p, copy);
  assert.deepEqual(await fs.readFile(copy), await fs.readFile(file));
  assert.equal(
    JSON.parse(await fs.readFile(path.join(dir, "stage/READY.json")))
      .activation,
    "preservation-only",
  );
});

test("missing EPUB keeps state pending, conflict preview preserves local state", async (t) => {
  const dir = await fixture(t),
    id = "a".repeat(64),
    state = Buffer.from(
      JSON.stringify({
        schemaVersion: 1,
        editionId: id,
        revision: 5,
        position: { href: "c.xhtml", unknown: "keep" },
        preferences: { color: "night" },
        bookmarks: [],
        annotations: [{ note: "原文", future: true }],
      }),
    );
  await fs.writeFile(path.join(dir, "state.json"), state);
  await exportArchive(
    {
      sourceRoot: dir,
      producer,
      files: [
        ...files,
        {
          path: "states/a.json",
          sourcePath: "state.json",
          role: "reader-state",
          editionId: id,
          bookId: "original-book",
        },
      ],
    },
    path.join(dir, "a.zip"),
  );
  const p = await inspectArchive(path.join(dir, "a.zip"), {
    existingEntries: {
      "states/a.json": "different",
      "journals/native.json": digest(
        await fs.readFile(path.join(dir, "history.json")),
      ),
    },
  });
  assert.deepEqual(p.pendingReaderStates, [id]);
  assert.equal(p.entries[0].status, "identical");
  assert.equal(p.entries[1].status, "conflict");
  await stageImport(p, path.join(dir, "pending"));
  assert.deepEqual(
    await fs.readFile(path.join(dir, "pending/payloads/states/a.json")),
    state,
  );
});

test("unchanged originals and edition digest identity retained", async (t) => {
  const dir = await fixture(t),
    b = zip([["mimetype", Buffer.from("application/epub+zip")]]),
    id = digest(b);
  await fs.writeFile(path.join(dir, "original.epub"), b);
  const descriptor = {
    path: "epubs/book.epub",
    sourcePath: "original.epub",
    role: "epub",
    editionId: id,
  };
  await exportArchive(
    { sourceRoot: dir, producer, files: [...files, descriptor] },
    path.join(dir, "a.zip"),
  );
  const p = await inspectArchive(path.join(dir, "a.zip"));
  await stageImport(p, path.join(dir, "out"));
  assert.deepEqual(
    await fs.readFile(path.join(dir, "out/payloads/epubs/book.epub")),
    b,
  );
  await assert.rejects(
    exportArchive(
      {
        sourceRoot: dir,
        producer,
        files: [...files, { ...descriptor, editionId: "a".repeat(64) }],
      },
      path.join(dir, "bad.zip"),
    ),
    /edition identity/,
  );
});

test("no overwrite; inspected bytes remain fixed after source mutation", async (t) => {
  const { dir, file } = await exported(t),
    b = await fs.readFile(file),
    p = await inspectArchive(file);
  await assert.rejects(
    exportArchive({ sourceRoot: dir, files, producer }, file),
    /EEXIST/,
  );
  assert.deepEqual(await fs.readFile(file), b);
  await fs.writeFile(file, "changed");
  await exportPreservedArchive(p, path.join(dir, "held.zip"));
  assert.deepEqual(await fs.readFile(path.join(dir, "held.zip")), b);
  await stageImport(p, path.join(dir, "out"));
  await assert.rejects(stageImport(p, path.join(dir, "out")), /EEXIST/);
  await assert.rejects(
    stageImport({ ...p }, path.join(dir, "forged")),
    /Inspect/,
  );
});

test("source traversal/symlink and ZIP case/traversal/device/ambiguous names rejected", async (t) => {
  const dir = await fixture(t);
  await fs.symlink(path.join(dir, "history.json"), path.join(dir, "link.json"));
  for (const sourcePath of ["../history.json", "/history.json", "link.json"])
    await assert.rejects(
      exportArchive(
        { sourceRoot: dir, producer, files: [{ ...files[0], sourcePath }] },
        path.join(dir, "bad.zip"),
      ),
    );
  for (const name of [
    "../bad",
    "/bad",
    "x\\y",
    "CON.json",
    "bad%2fpath",
    "bad./file",
  ]) {
    const file = path.join(dir, "malicious.zip");
    await fs.writeFile(file, zip([[name, Buffer.from("x")]]));
    await assert.rejects(inspectArchive(file));
  }
  const file = path.join(dir, "case.zip");
  await fs.writeFile(
    file,
    zip([
      ["A", Buffer.from("x")],
      ["a", Buffer.from("x")],
    ]),
  );
  await assert.rejects(inspectArchive(file), /colliding/);
});

test("new versions and required capabilities fail before any staging", async (t) => {
  for (const mutate of [
    (m) => {
      m.version = 2;
    },
    (m) => {
      m.requiredCapabilities.push("execute-import");
    },
    (m) => {
      m.entries[0].schemaVersion = 2;
    },
  ]) {
    const { dir, target } = await rewrite(t, mutate);
    await assert.rejects(inspectArchive(target));
    await assert.rejects(fs.stat(path.join(dir, "active")), { code: "ENOENT" });
  }
});

test("digest mismatch, unlisted/missing assets, ZIP symlink and zipbomb rejected", async (t) => {
  for (const change of [
    (m, e) => {
      m.entries[0].sha256 = "0".repeat(64);
    },
    (m, e) => [...e, ["unlisted", Buffer.from("x")]],
    (m, e) => e.slice(0, 1),
    (m, e) => [e[0], [e[1][0], e[1][1], { mode: 0o120777 }]],
    (m, e) => [...e, ["bomb", Buffer.alloc(1024 * 1024), { deflate: true }]],
  ]) {
    const { target } = await rewrite(t, change);
    await assert.rejects(inspectArchive(target));
  }
});

test("CRC/local-header corruption and tightened budgets rejected", async (t) => {
  const { dir, file } = await exported(t),
    b = await fs.readFile(file),
    corrupt = Buffer.from(b);
  corrupt[30 + corrupt.readUInt16LE(26)] ^= 1;
  await fs.writeFile(path.join(dir, "crc.zip"), corrupt);
  await assert.rejects(inspectArchive(path.join(dir, "crc.zip")), /checksum/);
  const header = Buffer.from(b);
  header[30] ^= 1;
  await fs.writeFile(path.join(dir, "header.zip"), header);
  await assert.rejects(inspectArchive(path.join(dir, "header.zip")), /header/);
  await assert.rejects(
    inspectArchive(file, { limits: { archiveBytes: 30 } }),
    /bounded/,
  );
  await assert.rejects(
    inspectArchive(file, { limits: { entries: 1 } }),
    /entry count/,
  );
  await assert.rejects(
    inspectArchive(file, { limits: { archiveBytes: 1e12 } }),
    /tighten/,
  );
});

test("unknown optional manifest fields survive exact re-export", async (t) => {
  const { dir, target } = await rewrite(t, (m) => {
    m.futureOptional = { nested: ["retain", 123] };
  });
  const p = await inspectArchive(target);
  assert.deepEqual(p.manifest.futureOptional, { nested: ["retain", 123] });
  await exportPreservedArchive(p, path.join(dir, "roundtrip.zip"));
  assert.deepEqual(
    await fs.readFile(target),
    await fs.readFile(path.join(dir, "roundtrip.zip")),
  );
});

test("real Node journal snapshot preserves tables, provenance BLOBs and raw JSON strings", async (t) => {
  const dir = await fixture(t),
    store = new JournalStore(path.join(dir, "journal.sqlite"));
  t.after(() => store.close());
  store.createBook({
    id: "book",
    title: "Book",
    creators: ["A", "B"],
    source: "manual",
    recordedAt: "2026-09-25T10:00:00Z",
  });
  const original = Buffer.from('{ "unknown": [true, null], "text":"文" }\n');
  store.db
    .prepare("INSERT INTO migration_sources VALUES(?,?,?,?)")
    .run(digest(original), "fixture", "2026-09-25T10:00:00Z", original);
  store.db
    .prepare(
      "INSERT INTO events(seq,event_id,kind,book_id,recorded_at,payload) VALUES(?,?,?,?,?,?)",
    )
    .run(
      9007199254740993n,
      "event",
      "future-clear",
      "book",
      "2026-09-25T10:00:00Z",
      '{ "clear": null }',
    );
  store.db
    .prepare(
      "INSERT INTO events(event_id,kind,book_id,recorded_at,payload) VALUES(?,?,?,?,?)",
    )
    .run("deleted", "future-clear", "book", "2026-09-25T10:00:00Z", "{}");
  store.db.prepare("DELETE FROM events WHERE event_id=?").run("deleted");
  const b = exportNodeJournal(store.db, { exportedAt: "2026-09-25T10:00:00Z" }),
    v = JSON.parse(b);
  assert.equal(v.tables.books[0].creators, '["A","B"]');
  assert.deepEqual(
    Buffer.from(v.tables.migration_sources[0].original_json.base64, "base64"),
    original,
  );
  assert.equal(Object.keys(v.tables).length, 9);
  assert.deepEqual(v.tables.events[0].seq, {
    sqliteType: "integer",
    decimal: "9007199254740993",
  });
  assert.equal(v.tables.events[0].payload, '{ "clear": null }');
  assert.deepEqual(
    v.tables.sqlite_sequence.find((x) => x.name === "events").seq,
    { sqliteType: "integer", decimal: "9007199254740994" },
  );
  await fs.writeFile(path.join(dir, "node.json"), b);
  await exportArchive(
    {
      sourceRoot: dir,
      producer,
      files: [
        ...files,
        {
          path: "journals/node.json",
          sourcePath: "node.json",
          role: "journal",
          format: "node-journal-json",
          schemaVersion: 1,
        },
      ],
    },
    path.join(dir, "both.zip"),
  );
  const p = await inspectArchive(path.join(dir, "both.zip"));
  await stageImport(p, path.join(dir, "cross-host"));
  assert.deepEqual(
    await fs.readFile(path.join(dir, "cross-host/payloads/journals/node.json")),
    b,
  );
  assert.deepEqual(
    await fs.readFile(
      path.join(dir, "cross-host/payloads/journals/native.json"),
    ),
    await fs.readFile(path.join(dir, "history.json")),
  );
  store.db.exec("CREATE TABLE future_data(value TEXT)");
  assert.throws(() => exportNodeJournal(store.db), /incomplete snapshot/);
  assert.equal(store.listBooks().length, 1);
});

test("failed staging removes only its new private directory and preserves originals", async (t) => {
  const { dir, file } = await exported(t),
    p = await inspectArchive(file),
    original = await fs.readFile(file),
    originalOpen = fs.open;
  try {
    fs.open = async function (file, ...args) {
      if (String(file).includes(".stillleaf-export-"))
        throw Object.assign(Error("simulated disk full"), { code: "ENOSPC" });
      return originalOpen.call(this, file, ...args);
    };
    await assert.rejects(
      stageImport(p, path.join(dir, "failed-stage")),
      /disk full/,
    );
  } finally {
    fs.open = originalOpen;
  }
  await assert.rejects(fs.stat(path.join(dir, "failed-stage")), {
    code: "ENOENT",
  });
  assert.deepEqual(await fs.readFile(file), original);
});

test("deflated safe ZIPs are accepted; covers require an explicit portable association", async (t) => {
  const { target } = await rewrite(t, (m, e) =>
    e.map(([name, bytes]) => [name, bytes, { deflate: true }]),
  );
  assert.equal((await inspectArchive(target)).activation, "preservation-only");
  const dir = await fixture(t);
  await fs.writeFile(path.join(dir, "cover.bin"), Buffer.from([0, 1, 2, 3]));
  const cover = {
    path: "covers/book.bin",
    sourcePath: "cover.bin",
    role: "cover",
  };
  await assert.rejects(
    exportArchive(
      { sourceRoot: dir, producer, files: [...files, cover] },
      path.join(dir, "bad.zip"),
    ),
    /identify its book/,
  );
  await exportArchive(
    {
      sourceRoot: dir,
      producer,
      files: [
        ...files,
        { ...cover, bookId: "retained-book", provenance: "explicit-override" },
      ],
    },
    path.join(dir, "cover.zip"),
  );
  const p = await inspectArchive(path.join(dir, "cover.zip"));
  await stageImport(p, path.join(dir, "cover-stage"));
  assert.deepEqual(
    await fs.readFile(path.join(dir, "cover-stage/payloads/covers/book.bin")),
    Buffer.from([0, 1, 2, 3]),
  );
});
