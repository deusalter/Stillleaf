import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import {
  importEPUB,
  inspectEPUB,
  canonicalArchivePath,
  resolveResource,
} from "../index.js";
import { zip, epub } from "./fixtures.js";
async function fixture(t, entries = epub()) {
  const dir = await fs.mkdtemp(
    path.join(os.tmpdir(), "stillleaf-publication-"),
  );
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const source = path.join(dir, "input.epub"),
    root = path.join(dir, "managed");
  await fs.writeFile(source, zip(entries));
  return { source, root, dir };
}
test("valid EPUB imported atomically, SHA256 identity, original intact, duplicate outcome", async (t) => {
  const { source, root } = await fixture(t);
  const before = await fs.readFile(source);
  const result = await importEPUB(source, root);
  assert.equal(result.status, "imported");
  assert.equal(
    result.editionId,
    createHash("sha256").update(before).digest("hex"),
  );
  assert.equal(result.publication.cover.path, "EPUB/cover.png");
  assert.equal(result.publication.title, "Fixture");
  assert.deepEqual(await fs.readFile(source), before);
  assert.deepEqual(
    await fs.readFile(path.join(result.directory, "original.epub")),
    before,
  );
  assert.equal((await importEPUB(source, root)).status, "duplicate");
  assert.deepEqual(await fs.readdir(path.join(root, ".staging")), []);
  assert.deepEqual(await fs.readdir(path.join(root, ".locks")), []);
});
test("EPUB2 explicit cover and no arbitrary-image fallback", async (t) => {
  const a = await fixture(t, epub({ legacy: true }));
  assert.equal((await inspectEPUB(a.source)).cover.path, "EPUB/cover.png");
  const b = await fixture(t, epub({ cover: false }));
  assert.equal((await inspectEPUB(b.source)).cover, null);
});
for (const name of [
  "../escape",
  "/absolute",
  "C:/drive",
  "EPUB/..%2fescape",
  "EPUB/%2e%2e/escape",
  "EPUB/a\\b",
  "EPUB/con.txt",
  "EPUB/a.",
  "EPUB/a//b",
  "EPUB/./a",
])
  test(`reject archive path ${name}`, async (t) => {
    const { source } = await fixture(
      t,
      epub({ extra: [{ name, data: "bad" }] }),
    );
    await assert.rejects(inspectEPUB(source), (error) => error.code === "PATH");
  });
for (const extra of [
  [{ name: "EPUB/chapter.xhtml", data: "duplicate" }],
  [{ name: "epub/CHAPTER.xhtml", data: "case duplicate" }],
  [{ name: "EPUB", data: "parent conflict" }],
])
  test("duplicate/colliding entry or file-parent conflict", async (t) => {
    const { source } = await fixture(t, epub({ extra }));
    await assert.rejects(inspectEPUB(source), (error) =>
      ["DUPLICATE_ENTRY", "PATH"].includes(error.code),
    );
  });
for (const [label, entry, code] of [
  [
    "symlink",
    { name: "EPUB/link", attrs: (0xa1ff << 16) >>> 0, data: "../escape" },
    "FILE_TYPE",
  ],
  [
    "encrypted",
    { name: "EPUB/encrypted", flags: 0x801, method: 8, data: "x" },
    "PROTECTED",
  ],
  [
    "DRM",
    { name: "META-INF/encryption.xml", data: "<encryption/>" },
    "PROTECTED",
  ],
  [
    "local mismatch",
    { name: "EPUB/ok", localName: "EPUB/no", data: "x" },
    "HEADER",
  ],
  ["bomb", { name: "EPUB/bomb", method: 8, data: "x".repeat(100000) }, "RATIO"],
])
  test(`reject ${label}`, async (t) => {
    const { source } = await fixture(t, epub({ extra: [entry] }));
    await assert.rejects(inspectEPUB(source), (error) => error.code === code);
  });
for (const href of [
  "../../escape.xhtml",
  "https://example.invalid/chapter",
  "%2e%2e/chapter.xhtml",
  "missing.xhtml",
  "chapter.xhtml?query",
])
  test(`reject unsafe/missing OPF href ${href}`, async (t) => {
    const { source } = await fixture(t, epub({ href }));
    await assert.rejects(inspectEPUB(source));
  });
test("safe relative canonical references and encoded spaces", () => {
  assert.equal(
    resolveResource("EPUB/package.opf", "../Images/a%20b.png"),
    "Images/a b.png",
  );
  assert.equal(
    canonicalArchivePath("EPUB/chapter.xhtml"),
    "EPUB/chapter.xhtml",
  );
});
test("preinflation entry/total/archive limits", async (t) => {
  const { source } = await fixture(t);
  for (const limits of [
    { entries: 1 },
    { entryBytes: 8 },
    { totalBytes: 10 },
    { archiveBytes: 10 },
  ])
    await assert.rejects(inspectEPUB(source, { limits }));
});
test("DTD and malformed XML rejected, ambiguous cover rejected", async (t) => {
  for (const opfTransform of [
    (x) => '<!DOCTYPE package [<!ENTITY x SYSTEM "file:///etc/passwd">]>' + x,
    (x) => x.replace("</package>", ""),
    (x) => x.replace('id="chapter"', 'properties="cover-image" id="chapter"'),
  ]) {
    const { source } = await fixture(t, epub({ opfTransform }));
    await assert.rejects(inspectEPUB(source));
  }
});
test("corruption late in extraction removes staged partial output and preserves source", async (t) => {
  const { source, root } = await fixture(
    t,
    epub({ extra: [{ name: "EPUB/bad.bin", data: "bad CRC", crc: 1 }] }),
  );
  const original = await fs.readFile(source);
  await assert.rejects(importEPUB(source, root), (e) => e.code === "CHECKSUM");
  assert.deepEqual(await fs.readdir(path.join(root, ".staging")), []);
  assert.deepEqual(await fs.readdir(path.join(root, "editions")), []);
  assert.deepEqual(await fs.readdir(path.join(root, ".locks")), []);
  assert.deepEqual(await fs.readFile(source), original);
});
test("cancelled import does not publish", async (t) => {
  const { source, root } = await fixture(t);
  const signal = AbortSignal.abort(new Error("cancel"));
  await assert.rejects(importEPUB(source, root, { signal }), /cancel/);
  await assert.rejects(fs.stat(root), (e) => e.code === "ENOENT");
});
test("managed directory symlinks rejected", async (t) => {
  const { source, root, dir } = await fixture(t);
  await fs.mkdir(root);
  await fs.symlink(dir, path.join(root, "editions"), "dir");
  await assert.rejects(importEPUB(source, root), (e) => e.code === "STORAGE");
});
test("preflight refuses bomb before malformed metadata could inflate", async (t) => {
  const { source } = await fixture(
    t,
    epub({
      opfTransform: () => "<broken",
      extra: [{ name: "EPUB/bomb", method: 8, data: "x".repeat(100000) }],
    }),
  );
  await assert.rejects(inspectEPUB(source), (e) => e.code === "RATIO");
});
test("lying deflate size rejected and partial output cleaned", async (t) => {
  const { source, root } = await fixture(
    t,
    epub({
      extra: [
        { name: "EPUB/lie", method: 8, data: "abc".repeat(1000), size: 1 },
      ],
    }),
  );
  await assert.rejects(importEPUB(source, root));
  assert.deepEqual(await fs.readdir(path.join(root, "editions")), []);
  assert.deepEqual(await fs.readdir(path.join(root, ".staging")), []);
});
test("incomplete existing edition is not overwritten", async (t) => {
  const { source, root } = await fixture(t);
  const hash = createHash("sha256")
    .update(await fs.readFile(source))
    .digest("hex");
  const destination = path.join(root, "editions", hash);
  await fs.mkdir(destination, { recursive: true });
  await fs.writeFile(path.join(destination, "preserve"), "untouched");
  await assert.rejects(importEPUB(source, root), (e) => e.code === "STORAGE");
  assert.equal(
    await fs.readFile(path.join(destination, "preserve"), "utf8"),
    "untouched",
  );
});
test("existing edition symlink is not followed", async (t) => {
  const { source, root, dir } = await fixture(t);
  const hash = createHash("sha256")
    .update(await fs.readFile(source))
    .digest("hex");
  await fs.mkdir(path.join(root, "editions"), { recursive: true });
  await fs.symlink(dir, path.join(root, "editions", hash), "dir");
  await assert.rejects(importEPUB(source, root), (e) => e.code === "STORAGE");
});
test("Unicode names and quoted angle brackets cannot evade XML depth limit", async (t) => {
  const { source } = await fixture(
    t,
    epub({
      opfTransform: (x) =>
        x.replace(
          "<metadata ",
          "<extra>" +
            '<深 x="/>">'.repeat(130) +
            "</深>".repeat(130) +
            "</extra><metadata ",
        ),
    }),
  );
  await assert.rejects(inspectEPUB(source), (e) => e.code === "XML");
});
test("damaged managed original is rejected as duplicate without replacing either copy", async (t) => {
  const { source, root } = await fixture(t);
  const before = await fs.readFile(source);
  const first = await importEPUB(source, root);
  const managedOriginal = path.join(first.directory, "original.epub");
  const damaged = Buffer.from("damaged managed EPUB");
  await fs.writeFile(managedOriginal, damaged);
  await assert.rejects(
    importEPUB(source, root),
    (error) => error.code === "STORAGE" && /digest/.test(error.message),
  );
  assert.deepEqual(await fs.readFile(source), before);
  assert.deepEqual(await fs.readFile(managedOriginal), damaged);
  assert.deepEqual(await fs.readdir(path.join(root, ".staging")), []);
  assert.deepEqual(await fs.readdir(path.join(root, ".locks")), []);
});
test("fixed layout declarations survive metadata extraction for explicit renderer rejection", async (t) => {
  for (const entries of [
    epub({
      opfTransform: (x) =>
        x.replace(
          "</metadata>",
          '<meta property="rendition:layout">pre-paginated</meta></metadata>',
        ),
    }),
    epub({
      opfTransform: (x) =>
        x.replace(
          "<itemref ",
          '<itemref properties="rendition:layout-pre-paginated" ',
        ),
    }),
    epub({
      legacy: true,
      opfTransform: (x) =>
        x.replace(
          "</metadata>",
          '<meta name="fixed-layout" content="true"/></metadata>',
        ),
    }),
    epub({
      legacy: true,
      extra: [
        {
          name: "META-INF/com.apple.ibooks.display-options.xml",
          data: '<display_options><platform name="*"><option name="fixed-layout">true</option></platform></display_options>',
        },
      ],
    }),
  ]) {
    const { source } = await fixture(t, entries);
    assert.equal((await inspectEPUB(source)).layout, "pre-paginated");
  }
  const { source } = await fixture(t);
  assert.equal((await inspectEPUB(source)).layout, "reflowable");
});
