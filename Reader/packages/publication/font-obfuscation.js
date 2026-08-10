import { createHash } from "node:crypto";
import { Transform } from "node:stream";
import { xml } from "./metadata.js";
import { canonicalArchivePath } from "./path-policy.js";
import { fail } from "./errors.js";

const CONTAINER = "urn:oasis:names:tc:opendocument:xmlns:container";
const ENC = "http://www.w3.org/2001/04/xmlenc#";
const IDPF = "http://www.idpf.org/2008/embedding";
const FONT_TYPES = new Set(["font/otf", "font/ttf", "font/woff", "font/woff2", "application/vnd.ms-opentype", "application/font-sfnt", "application/font-woff"]);
const children = node => Array.from(node.childNodes).filter(n => n.nodeType === 1);
const is = (node, name, ns = ENC) => node?.namespaceURI === ns && node.localName === name;
const onlyAttribute = (node, name) => Array.from(node.attributes).filter(a => a.namespaceURI !== "http://www.w3.org/2000/xmlns/").every(a => !a.namespaceURI && a.name === name);
const reject = () => fail("PROTECTED", "Only standard IDPF font obfuscation is supported; invalid or encrypted resources were not imported");

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
  const ids = children(pkg).filter(n => is(n, "metadata", "http://www.idpf.org/2007/opf"))
    .flatMap(children).filter(n => is(n, "identifier", "http://purl.org/dc/elements/1.1/") && n.getAttribute("id") === uid);
  if (!uid || ids.length !== 1 || children(ids[0]).length) reject();
  const identifier = ids[0].textContent.replace(/[\u0020\u0009\u000d\u000a]/gu, "");
  if (!identifier || Buffer.byteLength(identifier) > 16384) reject();
  const key = createHash("sha1").update(identifier, "utf8").digest();
  for (const entry of entries) {
    const parts = children(entry);
    if (!is(entry, "EncryptedData") || parts.length !== 2 || !onlyAttribute(entry, null)) reject();
    const method = parts.find(n => is(n, "EncryptionMethod")), data = parts.find(n => is(n, "CipherData"));
    if (!method || !data || !onlyAttribute(data, null) || method.getAttribute("Algorithm") !== IDPF || children(method).length || !onlyAttribute(method, "Algorithm")) reject();
    const refs = children(data);
    if (refs.length !== 1 || !is(refs[0], "CipherReference") || children(refs[0]).length || !onlyAttribute(refs[0], "URI")) reject();
    const uri = refs[0].getAttribute("URI");
    if (!uri || /[?#:\\\u0000-\u0020]/u.test(uri)) reject();
    let decoded;
    try { decoded = decodeURIComponent(uri); } catch { reject(); }
    const target = canonicalArchivePath(decoded, limits);
    if (target !== decoded) reject();
    const manifest = publication.manifest.filter(item => item.path === target);
    if (!paths.has(target) || manifest.length !== 1 || !FONT_TYPES.has(manifest[0].mediaType) || plan.has(target)) reject();
    plan.set(target, key);
  }
  return plan;
}

/** Applied after the ZIP CRC/size guard so archive integrity checks original bytes. */
export function decodeFont(key) {
  let offset = 0;
  return new Transform({ transform(chunk, _encoding, done) {
    const result = Buffer.from(chunk);
    for (let i = 0; i < result.length && offset + i < 1040; i++) result[i] ^= key[(offset + i) % key.length];
    offset += result.length;
    done(null, result);
  } });
}
