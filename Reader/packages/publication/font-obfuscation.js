import { createHash } from "node:crypto";
import { Transform } from "node:stream";
import { xml } from "./metadata.js";
import { canonicalArchivePath } from "./path-policy.js";
import { fail } from "./errors.js";

const CONTAINER = "urn:oasis:names:tc:opendocument:xmlns:container";
const ENC = "http://www.w3.org/2001/04/xmlenc#";
const IDPF = "http://www.idpf.org/2008/embedding";
const ADOBE = "http://ns.adobe.com/pdf/enc#RC";
const FONT_TYPES = new Set(["font/otf", "font/ttf", "font/woff", "font/woff2", "font/sfnt", "font/opentype", "font/truetype",
  "application/vnd.ms-opentype", "application/font-sfnt", "application/font-woff", "application/x-font-ttf", "application/x-font-otf",
  "application/x-font-opentype", "application/x-font-truetype", "application/x-font-woff", "application/font-ttf", "application/font-otf"]);
const children = node => Array.from(node.childNodes).filter(n => n.nodeType === 1);
const is = (node, name, ns = ENC) => node?.namespaceURI === ns && node.localName === name;
const onlyAttribute = (node, name) => Array.from(node.attributes).filter(a => a.namespaceURI !== "http://www.w3.org/2000/xmlns/").every(a => !a.namespaceURI && a.name === name);
const reject = () => fail("PROTECTED", "Only IDPF or Adobe font obfuscation is supported; invalid or encrypted resources were not imported");

/** The key is transient, never written to a receipt or the original EPUB. */
export async function fontObfuscationPlan(read, publication, paths, limits) {
  const plan = new Map();
  if (!paths.has("META-INF/encryption.xml")) return plan;
  const root = xml(await read("META-INF/encryption.xml", limits.xmlBytes)).documentElement;
  if (!is(root, "encryption", CONTAINER) || !onlyAttribute(root, null)) reject();
  const pending = [root];
  while (pending.length) {
    for (const node of Array.from(pending.pop().childNodes)) {
      if (node.nodeType === 1) pending.push(node);
      else if ([3, 4].includes(node.nodeType) && /[^\u0020\u0009\u000d\u000a]/u.test(node.data)) reject();
    }
  }
  const entries = children(root);
  if (!entries.length || entries.length > limits.entries) reject();
  const pkg = xml(await read(publication.opfPath, limits.xmlBytes)).documentElement;
  const uid = pkg.getAttribute("unique-identifier");
  const identifiers = children(pkg).filter(n => is(n, "metadata", "http://www.idpf.org/2007/opf"))
    .flatMap(children).filter(n => is(n, "identifier", "http://purl.org/dc/elements/1.1/"));
  const ids = identifiers.filter(n => n.getAttribute("id") === uid);
  let idpf, adobe;
  // IDPF: SHA-1 of the unique identifier, which must be unambiguous.
  const idpfKey = () => {
    if (idpf) return idpf;
    if (!uid || ids.length !== 1 || children(ids[0]).length) reject();
    const identifier = ids[0].textContent.replace(/[\u0020\u0009\u000d\u000a]/gu, "");
    if (!identifier || Buffer.byteLength(identifier) > 16384) reject();
    return idpf = { key: createHash("sha1").update(identifier, "utf8").digest(), length: 1040 };
  };
  // Adobe: the 16 bytes of a urn:uuid identifier, preferring the unique one.
  const adobeKey = () => {
    if (adobe) return adobe;
    for (const node of [...ids, ...identifiers.filter(n => !ids.includes(n))].slice(0, 32)) {
      if (children(node).length) continue;
      const hex = node.textContent.trim().replace(/^urn:uuid:/iu, "").replaceAll("-", "");
      if (/^[0-9a-f]{32}$/iu.test(hex)) return adobe = { key: Buffer.from(hex, "hex"), length: 1024, verify: true };
    }
    reject();
  };
  for (const entry of entries) {
    const parts = children(entry);
    if (!is(entry, "EncryptedData") || parts.length !== 2 || !onlyAttribute(entry, null)) reject();
    const method = parts.find(n => is(n, "EncryptionMethod")), data = parts.find(n => is(n, "CipherData"));
    if (!method || !data || !onlyAttribute(data, null) || ![IDPF, ADOBE].includes(method.getAttribute("Algorithm")) || children(method).length || !onlyAttribute(method, "Algorithm")) reject();
    const refs = children(data);
    if (refs.length !== 1 || !is(refs[0], "CipherReference") || children(refs[0]).length || !onlyAttribute(refs[0], "URI")) reject();
    const uri = refs[0].getAttribute("URI");
    if (!uri || /[?#:\\\u0000-\u0020]/u.test(uri)) reject();
    let decoded;
    try { decoded = decodeURIComponent(uri); } catch { reject(); }
    const target = canonicalArchivePath(decoded, limits);
    if (target !== decoded) reject();
    const manifest = publication.manifest.filter(item => item.path === target);
    if (!paths.has(target) || manifest.length !== 1 || !FONT_TYPES.has(manifest[0].mediaType.toLowerCase()) || plan.has(target)) reject();
    plan.set(target, method.getAttribute("Algorithm") === IDPF ? idpfKey() : adobeKey());
  }
  return plan;
}

const FONT_SIGNATURES = ["00010000", "4f54544f", "74727565", "74797031", "74746366", "774f4646", "774f4632"];
/** Applied after the ZIP CRC/size guard so archive integrity checks original bytes.
 *  `verify` (Adobe) keeps the stored bytes when de-obfuscation does not yield a font
 *  signature: some tools list fonts in encryption.xml without obfuscating them. */
export function decodeFont({ key, length = 1040, verify = false }) {
  let offset = 0, held = [], passthrough = false;
  const xor = chunk => {
    const result = Buffer.from(chunk);
    for (let i = 0; i < result.length && offset + i < length; i++) result[i] ^= key[(offset + i) % key.length];
    offset += result.length;
    return result;
  };
  return new Transform({
    transform(chunk, _encoding, done) {
      if (passthrough) return done(null, chunk);
      if (!verify || offset >= 4) return done(null, xor(chunk));
      held.push(Buffer.from(chunk));
      const pending = Buffer.concat(held);
      if (pending.length < 4) return done();
      held = [];
      const decoded = xor(pending);
      if (FONT_SIGNATURES.includes(decoded.subarray(0, 4).toString("hex"))) return done(null, decoded);
      passthrough = true;
      done(null, pending);
    },
    flush(done) { done(null, held.length ? (verify ? Buffer.concat(held) : xor(Buffer.concat(held))) : undefined); },
  });
}
