import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { importEPUB, inspectEPUB } from "../index.js";
import { zip, epub } from "./fixtures.js";
import { Readable } from "node:stream";
import { decodeFont } from "../font-obfuscation.js";

const encryption = (uri = "EPUB/font.otf", algorithm = "http://www.idpf.org/2008/embedding") => `<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:e="http://www.w3.org/2001/04/xmlenc#"><e:EncryptedData><e:EncryptionMethod Algorithm="${algorithm}"/><e:CipherData><e:CipherReference URI="${uri}"/></e:CipherData></e:EncryptedData></encryption>`;
// Published SHA-1 test vector for UTF-8 "abc", independent from implementation.
const key = Buffer.from("a9993e364706816aba3e25717850c26c9cd0d89d", "hex");
function fixture({ bytes = Buffer.alloc(2000, 0x45), xml = encryption(), identifier = "a b\n c\t", mime = "font/otf", transform = x => x } = {}) {
  const encoded = Buffer.from(bytes);
  for (let i = 0; i < Math.min(1040, encoded.length); i++) encoded[i] ^= key[i % 20];
  return zip(epub({ extra: [{ name: "EPUB/font.otf", data: encoded }, { name: "META-INF/encryption.xml", data: xml }],
    opfTransform: opf => transform(opf.replace("synthetic</dc:identifier>", identifier + "</dc:identifier>").replace("</manifest>", `<item id="font" href="font.otf" media-type="${mime}"/></manifest>`)) }));
}
async function setup(t, bytes) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "stillleaf-font-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const source = path.join(root, "book.epub"); await fs.writeFile(source, bytes);
  return { source, root };
}
for (const length of [8, 1040, 2000]) test(`IDPF decodes ${length}-byte extracted font and preserves exact original`, async t => {
  const raw = Buffer.alloc(length); for (let i = 0; i < length; i++) raw[i] = i % 251;
  const archive = fixture({ bytes: raw }), { source, root } = await setup(t, archive);
  const result = await importEPUB(source, path.join(root, "library"));
  assert.deepEqual(await fs.readFile(path.join(result.directory, "resources/EPUB/font.otf")), raw);
  assert.deepEqual(await fs.readFile(path.join(result.directory, "original.epub")), archive);
  assert.deepEqual(await fs.readFile(source), archive);
  assert.equal((await importEPUB(source, path.join(root, "library"))).status, "duplicate");
  assert.ok(!(await fs.readFile(path.join(result.directory, "publication.json"), "utf8")).includes(key.toString("hex")));
});
const invalid = {
  "directory-slash font URI": { xml: encryption("EPUB/font.otf/") },
  "non-whitespace encryption text": { xml: encryption().replace('</encryption>', 'unexpected</encryption>') },
  "encryption CDATA": { xml: encryption().replace('</e:CipherData>', '<![CDATA[unexpected]]></e:CipherData>') },
  "ambiguous font manifest": { transform: x => x.replace('</manifest>', '<item id="font2" href="font.otf" media-type="font/otf"/></manifest>') },
  "XML base": { xml: encryption().replace('<encryption ', '<encryption xml:base="https://example.invalid/" ') },
  "identifier outside metadata": { transform: x => x.replace('<dc:identifier id="uid">a b\n c\t</dc:identifier>', '').replace('</metadata>', '</metadata><dc:identifier id="uid">abc</dc:identifier>') },
  "extra algorithm attribute": { xml: encryption().replace('Algorithm="', 'unexpected="true" Algorithm="') },
  "unknown encryption": { xml: encryption("EPUB/font.otf", "urn:unsupported") },
  "non-font resource": { xml: encryption("EPUB/chapter.xhtml") },
  "non-font media type": { mime: "application/octet-stream" },
  "missing unique identifier": { transform: x => x.replace('unique-identifier="uid"', 'unique-identifier="missing"') },
  "empty unique identifier": { identifier: " \t\n " },
  "duplicate identifier": { transform: x => x.replace("</metadata>", '<dc:identifier id="uid">abc</dc:identifier></metadata>') },
  "traversal": { xml: encryption("../EPUB/font.otf") },
  "encoded traversal": { xml: encryption("%2e%2e/EPUB/font.otf") },
  "remote reference": { xml: encryption("https://example.invalid/font.otf") },
  "fragment": { xml: encryption("EPUB/font.otf#x") },
  "missing resource": { xml: encryption("EPUB/missing.otf") },
  "duplicate reference": { xml: encryption().replace("</encryption>", encryption().match(/<e:EncryptedData>.*<\/e:EncryptedData>/)[0] + "</encryption>") },
  "unexpected transform": { xml: encryption().replace('<e:CipherReference URI="EPUB/font.otf"/>', '<e:CipherReference URI="EPUB/font.otf"><e:Transforms/></e:CipherReference>') },
  "DTD": { xml: '<!DOCTYPE encryption [<!ENTITY x "foo">]>' + encryption() },
};
for (const [name, options] of Object.entries(invalid)) test(`font obfuscation rejects ${name}`, async t => {
  const { source } = await setup(t, fixture(options)); await assert.rejects(inspectEPUB(source));
});
test("font transform keeps XOR position across stream chunk boundaries", async () => {
  const raw = Buffer.alloc(2000, 0x64), encoded = Buffer.from(raw);
  for (let i = 0; i < 1040; i++) encoded[i] ^= key[i % 20];
  const stream = Readable.from([encoded.subarray(0, 7), encoded.subarray(7, 1038), encoded.subarray(1038, 1045), encoded.subarray(1045)]).pipe(decodeFont(key));
  const chunks = []; for await (const chunk of stream) chunks.push(chunk);
  assert.deepEqual(Buffer.concat(chunks), raw);
});
