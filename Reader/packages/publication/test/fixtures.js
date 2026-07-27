import { deflateRawSync } from "node:zlib";
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let i = 0; i < 8; i++)
      crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  }
  return (crc ^ 0xffffffff) >>> 0;
}
export function zip(entries) {
  const locals = [],
    centrals = [];
  let offset = 0;
  for (const e of entries) {
    const name = Buffer.from(e.name),
      localName = Buffer.from(e.localName ?? e.name),
      data = Buffer.from(e.data ?? ""),
      method = e.method ?? 0,
      compressed = method === 8 ? deflateRawSync(data) : data,
      crc = e.crc ?? crc32(data),
      size = e.size ?? data.length,
      flags = e.flags ?? 0x800;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(flags, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(size, 22);
    local.writeUInt16LE(localName.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50);
    central.writeUInt16LE(0x314, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(flags, 8);
    central.writeUInt16LE(method, 10);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(compressed.length, 20);
    central.writeUInt32LE(size, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(e.attrs ?? 0, 38);
    central.writeUInt32LE(offset, 42);
    locals.push(local, localName, compressed);
    centrals.push(central, name);
    offset += local.length + localName.length + compressed.length;
  }
  const directory = Buffer.concat(centrals),
    end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}
export function epub({
  cover = true,
  legacy = false,
  href = "chapter.xhtml",
  extra = [],
  opfTransform = (x) => x,
} = {}) {
  const opf = `<package xmlns="http://www.idpf.org/2007/opf" version="${legacy ? "2.0" : "3.0"}" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">synthetic</dc:identifier><dc:title>Fixture</dc:title><dc:creator>Tester</dc:creator><dc:language>en</dc:language>${cover && legacy ? '<meta name="cover" content="art"/>' : ""}</metadata><manifest><item id="chapter" href="${href}" media-type="application/xhtml+xml"/><item id="art" href="cover.png" media-type="image/png" ${cover && !legacy ? 'properties="cover-image"' : ""}/></manifest><spine><itemref idref="chapter"/></spine></package>`;
  return [
    { name: "mimetype", data: "application/epub+zip" },
    {
      name: "META-INF/container.xml",
      data: '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
    },
    { name: "EPUB/package.opf", data: opfTransform(opf) },
    {
      name: "EPUB/chapter.xhtml",
      data: '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Synthetic reading.</p></body></html>',
    },
    { name: "EPUB/cover.png", data: "synthetic non-decoded image" },
    ...extra,
  ];
}
