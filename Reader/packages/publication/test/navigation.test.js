import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { inspectEPUB, importEPUB } from "../index.js";
import { epub, zip } from "./fixtures.js";
const { readerInput } = createRequire(import.meta.url)(
  "../../../desktop/src/library-store.cjs",
);
const nav = (body) =>
  `<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>${body}</body></html>`;
const toc = (href = "chapter.xhtml#section") =>
  nav(
    `<nav epub:type="toc"><ol><li><a href="${href}">Opening</a><ol><li><a href="chapter.xhtml#detail">A detail</a></li></ol></li></ol></nav><nav epub:type="landmarks"><ol><li><a href="chapter.xhtml">Start</a></li></ol></nav><nav epub:type="page-list"><ol><li><a href="chapter.xhtml#p12">12</a></li></ol></nav>`,
  );
function withNav(data = toc(), extra = []) {
  return epub({
    extra: [{ name: "EPUB/nav.xhtml", data }, ...extra],
    opfTransform: (x) =>
      x
        .replace(
          "</manifest>",
          '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>',
        )
        .replace("<spine>", '<spine page-progression-direction="rtl">'),
  });
}
async function fixture(t, entries) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "stillleaf-nav-"));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const source = path.join(dir, "input.epub");
  await fs.writeFile(source, zip(entries));
  return { source, root: path.join(dir, "managed") };
}
test("EPUB3 nested toc, landmarks, page list, rtl survive import and desktop input", async (t) => {
  const { source, root } = await fixture(t, withNav());
  const result = await importEPUB(source, root);
  const p = result.publication;
  assert.deepEqual(p.toc, [
    {
      href: "EPUB/chapter.xhtml#section",
      title: "Opening",
      children: [{ href: "EPUB/chapter.xhtml#detail", title: "A detail" }],
    },
  ]);
  assert.deepEqual(p.landmarks, [
    { href: "EPUB/chapter.xhtml", title: "Start" },
  ]);
  assert.deepEqual(p.pageList, [
    { href: "EPUB/chapter.xhtml#p12", title: "12" },
  ]);
  assert.equal(p.readingProgression, "rtl");
  const input = await readerInput(root, result.editionId);
  for (const key of [
    "toc",
    "landmarks",
    "pageList",
    "readingProgression",
    "languages",
  ])
    assert.deepEqual(input[key], p[key]);
});
test("EPUB2 NCX nested navMap/pageList and OPF guide", async (t) => {
  const ncx =
    '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap><navPoint><navLabel><text>First</text></navLabel><content src="chapter.xhtml#one"/><navPoint><navLabel><text>Nested</text></navLabel><content src="chapter.xhtml#two"/></navPoint></navPoint></navMap><pageList><pageTarget><navLabel><text>9</text></navLabel><content src="chapter.xhtml#nine"/></pageTarget></pageList></ncx>';
  const { source } = await fixture(
    t,
    epub({
      legacy: true,
      extra: [{ name: "EPUB/toc.ncx", data: ncx }],
      opfTransform: (x) =>
        x
          .replace(
            "</manifest>",
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>',
          )
          .replace(
            "<spine>",
            '<spine toc="ncx" page-progression-direction="ltr">',
          )
          .replace(
            "</package>",
            '<guide><reference type="text" title="Begin" href="chapter.xhtml#one"/></guide></package>',
          ),
    }),
  );
  const p = await inspectEPUB(source);
  assert.equal(p.toc[0].children[0].href, "EPUB/chapter.xhtml#two");
  assert.deepEqual(p.pageList, [
    { href: "EPUB/chapter.xhtml#nine", title: "9" },
  ]);
  assert.deepEqual(p.landmarks, [
    { href: "EPUB/chapter.xhtml#one", title: "Begin" },
  ]);
  assert.equal(p.readingProgression, "ltr");
});
test("legacy no-navigation receipts remain readable", async (t) => {
  const { source, root } = await fixture(t, epub());
  const imported = await importEPUB(source, root);
  for (const key of ["toc", "landmarks", "pageList", "readingProgression"])
    assert.equal(imported.publication[key], undefined);
  const input = await readerInput(root, imported.editionId);
  assert.equal(input.toc, undefined);
  assert.equal(input.readingOrder.length, 1);
});
for (const href of [
  "https://example.invalid/a",
  "//example.invalid/a",
  "../../escape.xhtml",
  "%2e%2e/chapter.xhtml",
  "chapter.xhtml?x=1",
  "missing.xhtml",
  "#bad%00",
  "chapter.xhtml#bad%zz",
])
  test("reject unsafe navigation " + href, async (t) => {
    const { source } = await fixture(t, withNav(toc(href)));
    await assert.rejects(inspectEPUB(source), (error) =>
      ["NAVIGATION", "REFERENCE", "PATH"].includes(error.code),
    );
  });
test("unmanifested archive resource cannot be a navigation target", async (t) => {
  const { source } = await fixture(
    t,
    withNav(toc("extra.xhtml"), [{ name: "EPUB/extra.xhtml", data: "extra" }]),
  );
  await assert.rejects(inspectEPUB(source), { code: "NAVIGATION" });
});
test("plain DOCTYPE declarations in nav and NCX are accepted", async (t) => {
  const { source } = await fixture(t, withNav("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n" + toc()));
  assert.equal((await inspectEPUB(source)).toc[0].title, "Opening");
  const ncx =
    '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd"><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap><navPoint><navLabel><text>First</text></navLabel><content src="chapter.xhtml#one"/></navPoint></navMap></ncx>';
  const legacy = await fixture(
    t,
    epub({
      legacy: true,
      extra: [{ name: "EPUB/toc.ncx", data: ncx }],
      opfTransform: (x) =>
        x
          .replace("</manifest>", '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>')
          .replace("<spine>", '<spine toc="ncx">'),
    }),
  );
  assert.equal((await inspectEPUB(legacy.source)).toc[0].title, "First");
});
test("navigation DTD and structural budgets reuse XML safety", async (t) => {
  for (const data of [
    '<!DOCTYPE html [<!ATTLIST html x CDATA "y">]>' + toc(),
    "<!DOCTYPE html><!DOCTYPE html>" + toc(),
    nav(
      '<nav epub:type="toc">' +
        "<ol><li>".repeat(34) +
        '<a href="chapter.xhtml">Deep</a>' +
        "</li></ol>".repeat(34) +
        "</nav>",
    ),
  ]) {
    const { source } = await fixture(t, withNav(data));
    await assert.rejects(inspectEPUB(source), (error) =>
      ["XML", "NAVIGATION"].includes(error.code),
    );
  }
});
test("heading-only nav groups flatten and fragment-only local target resolves", async (t) => {
  const { source } = await fixture(
    t,
    withNav(
      nav(
        '<nav epub:type="toc"><ol><li><span>Part</span><ol><li><a href="#local">Local</a></li></ol></li></ol></nav>',
      ),
    ),
  );
  assert.deepEqual((await inspectEPUB(source)).toc, [
    { href: "EPUB/nav.xhtml#local", title: "Local" },
  ]);
});
test("invalid page progression and ambiguous nav documents reject", async (t) => {
  for (const entries of [
    epub({
      opfTransform: (x) =>
        x.replace("<spine>", '<spine page-progression-direction="sideways">'),
    }),
    withNav().map((item) =>
      item.name === "EPUB/package.opf"
        ? {
            ...item,
            data: item.data.replace(
              "</manifest>",
              '<item id="nav2" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>',
            ),
          }
        : item,
    ),
  ]) {
    const { source } = await fixture(t, entries);
    await assert.rejects(inspectEPUB(source), (error) =>
      ["OPF", "NAVIGATION"].includes(error.code),
    );
  }
});

test("NCX and guide targets receive the same local-only policy", async (t) => {
  for (const entries of [
    epub({
      legacy: true,
      extra: [
        {
          name: "EPUB/toc.ncx",
          data: '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap><navPoint><navLabel><text>Bad</text></navLabel><content src="https://example.invalid/remote"/></navPoint></navMap></ncx>',
        },
      ],
      opfTransform: (x) =>
        x
          .replace(
            "</manifest>",
            '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>',
          )
          .replace("<spine>", '<spine toc="ncx">'),
    }),
    epub({
      legacy: true,
      opfTransform: (x) =>
        x.replace(
          "</package>",
          '<guide><reference title="Bad" href="../../escape.xhtml"/></guide></package>',
        ),
    }),
    epub({
      legacy: true,
      opfTransform: (x) => x.replace("<spine>", '<spine toc="missing">'),
    }),
  ]) {
    const { source } = await fixture(t, entries);
    await assert.rejects(inspectEPUB(source), (error) =>
      ["NAVIGATION", "REFERENCE"].includes(error.code),
    );
  }
});

test("navigation title and decoded fragment controls are bounded by bytes", async (t) => {
  for (const data of [
    nav(
      '<nav epub:type="toc"><ol><li><a href="chapter.xhtml">' +
        "海".repeat(5500) +
        "</a></li></ol></nav>",
    ),
    toc("chapter.xhtml#" + "a".repeat(4097)),
    toc("chapter.xhtml#bad%0A"),
  ]) {
    const { source } = await fixture(t, withNav(data));
    await assert.rejects(inspectEPUB(source), { code: "NAVIGATION" });
  }
});
