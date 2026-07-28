import { DOMParser } from "@xmldom/xmldom";
import { fail } from "./errors.js";
import { canonicalArchivePath, resolveResource } from "./path-policy.js";
export function xml(bytes) {
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    fail("XML", "Metadata must be UTF-8");
  }
  // Real books carry a plain DOCTYPE (XHTML nav, NCX); only an internal subset
  // or entity declaration can expand, so those stay forbidden.
  const doctypes = [...text.matchAll(/<!\s*DOCTYPE/giu)];
  if (/<!\s*ENTITY/iu.test(text) || doctypes.length > 1 || /\x00/u.test(text))
    fail("XML", "DTD/entity declarations forbidden");
  if (doctypes.length) {
    const end = text.indexOf(">", doctypes[0].index);
    if (end === -1 || text.slice(doctypes[0].index, end).includes("["))
      fail("XML", "DTD/entity declarations forbidden");
  }
  // Bound structure before DOM allocation; honor quoted > and Unicode names.
  let depth = 0,
    tags = 0,
    cursor = 0;
  while ((cursor = text.indexOf("<", cursor)) !== -1) {
    let terminator;
    if (text.startsWith("<!--", cursor)) terminator = "-->";
    else if (text.startsWith("<![CDATA[", cursor)) terminator = "]]>";
    else if (text.startsWith("<?", cursor)) terminator = "?>";
    if (terminator) {
      const end = text.indexOf(terminator, cursor + 2);
      if (end === -1) fail("XML", "Unterminated XML construct");
      cursor = end + terminator.length;
      continue;
    }
    let end = cursor + 1,
      quote = null;
    for (; end < text.length; end++) {
      const char = text[end];
      if (quote) {
        if (char === quote) quote = null;
      } else if (char === '"' || char === "'") quote = char;
      else if (char === ">") break;
    }
    if (end === text.length) fail("XML", "Unterminated XML tag");
    const token = text.slice(cursor + 1, end).trim();
    if (++tags > 20000) fail("XML", "Too many XML tags");
    if (token.startsWith("/")) depth--;
    else if (!token.startsWith("!") && !token.endsWith("/")) depth++;
    if (depth > 128 || depth < 0)
      fail("XML", "XML nesting exceeds budget or is malformed");
    cursor = end + 1;
  }
  let doc;
  try {
    doc = new DOMParser({
      onError: (_level, message) => {
        throw new Error(message);
      },
    }).parseFromString(text, "application/xml");
  } catch (error) {
    fail("XML", `Invalid XML: ${error.message}`);
  }
  return doc;
}
const elements = (node, namespace, name) =>
  Array.from(node.getElementsByTagNameNS(namespace, name));
const OPF = "http://www.idpf.org/2007/opf",
  DC = "http://purl.org/dc/elements/1.1/",
  CONTAINER = "urn:oasis:names:tc:opendocument:xmlns:container";
const XHTML = "http://www.w3.org/1999/xhtml",
  EPUB = "http://www.idpf.org/2007/ops",
  NCX = "http://www.daisy.org/z3986/2005/ncx/";
const children = (node, namespace, name) =>
  Array.from(node.childNodes ?? []).filter(
    (n) =>
      n.nodeType === 1 && n.namespaceURI === namespace && n.localName === name,
  );
const bytes = (value) => Buffer.byteLength(value, "utf8");
function navigationTarget(source, href, manifest) {
  if (
    typeof href !== "string" ||
    !href ||
    bytes(href) > 8192 ||
    /[?:\\\x00-\x1f\x7f]/u.test(href) ||
    href.startsWith("/")
  )
    fail("NAVIGATION", "Unsafe navigation target");
  const hash = href.indexOf("#"),
    raw = hash < 0 ? href : href.slice(0, hash),
    fragment = hash < 0 ? null : href.slice(hash + 1);
  const target = raw
    ? resolveResource(source, raw)
    : canonicalArchivePath(source);
  if (!manifest.has(target))
    fail("NAVIGATION", "Navigation references missing manifest resource");
  if (fragment !== null) {
    let decoded;
    try {
      decoded = decodeURIComponent(fragment);
    } catch {
      fail("NAVIGATION", "Malformed navigation fragment");
    }
    if (bytes(fragment) > 4096 || /[\x00-\x1f\x7f]/u.test(decoded))
      fail("NAVIGATION", "Unsafe navigation fragment");
  }
  return target + (fragment === null ? "" : "#" + fragment);
}
async function navigationMetadata(doc, opfPath, items, readResource, limits) {
  const manifest = new Set([...items.values()].map((item) => item.path));
  const navItems = [...items.values()].filter((item) =>
    item.properties.includes("nav"),
  );
  if (navItems.length > 1) fail("NAVIGATION", "Ambiguous navigation documents");
  const output = {};
  let count = 0;
  const link = (source, href, title, nested = []) => {
    if (++count > 10000 || bytes(title) > 16384)
      fail("NAVIGATION", "Navigation exceeds limits");
    return {
      href: navigationTarget(source, href, manifest),
      title: title.trim().replace(/\s+/gu, " "),
      ...(nested.length ? { children: nested } : {}),
    };
  };
  if (navItems.length) {
    const item = navItems[0];
    if (item.mediaType !== "application/xhtml+xml")
      fail("NAVIGATION", "Navigation must be XHTML");
    const navDoc = xml(
      await readResource(item.path, Math.min(limits.xmlBytes, 2 * 1024 * 1024)),
    );
    if (
      navDoc.documentElement.namespaceURI !== XHTML ||
      navDoc.documentElement.localName !== "html"
    )
      fail("NAVIGATION", "Invalid navigation document root");
    const list = (ol, depth = 0) => {
      if (depth > 32) fail("NAVIGATION", "Navigation nesting exceeds limits");
      return children(ol, XHTML, "li").flatMap((li) => {
        const anchor = children(li, XHTML, "a")[0];
        const nested = children(li, XHTML, "ol").flatMap((child) =>
          list(child, depth + 1),
        );
        return anchor
          ? [
              link(
                item.path,
                anchor.getAttribute("href"),
                anchor.textContent,
                nested,
              ),
            ]
          : nested;
      });
    };
    for (const nav of elements(navDoc, XHTML, "nav")) {
      const kinds = (nav.getAttributeNS(EPUB, "type") || "").split(/\s+/u);
      for (const [kind, key] of [
        ["toc", "toc"],
        ["landmarks", "landmarks"],
        ["page-list", "pageList"],
      ])
        if (kinds.includes(kind)) {
          const links = children(nav, XHTML, "ol").flatMap((ol) => list(ol));
          if (output[key]) fail("NAVIGATION", "Duplicate navigation section");
          output[key] = links;
        }
    }
  } else {
    const tocID = elements(doc, OPF, "spine")[0]?.getAttribute("toc");
    const ncxItems = [...items.values()].filter(
      (item) => item.mediaType === "application/x-dtbncx+xml",
    );
    const ncx = tocID
      ? items.get(tocID)
      : ncxItems.length === 1
        ? ncxItems[0]
        : undefined;
    if (tocID && (!ncx || ncx.mediaType !== "application/x-dtbncx+xml"))
      fail("NAVIGATION", "Unknown NCX navigation reference");
    if (!tocID && ncxItems.length > 1)
      fail("NAVIGATION", "Ambiguous NCX navigation documents");
    if (ncx) {
      const ncxDoc = xml(
        await readResource(
          ncx.path,
          Math.min(limits.xmlBytes, 2 * 1024 * 1024),
        ),
      );
      if (
        ncxDoc.documentElement.namespaceURI !== NCX ||
        ncxDoc.documentElement.localName !== "ncx"
      )
        fail("NAVIGATION", "Invalid NCX root");
      const list = (parent, nodeName, depth = 0) => {
        if (depth > 32) fail("NAVIGATION", "Navigation nesting exceeds limits");
        return children(parent, NCX, nodeName).flatMap((node) => {
          const content = children(node, NCX, "content")[0];
          const title =
            children(children(node, NCX, "navLabel")[0] ?? {}, NCX, "text")[0]
              ?.textContent ?? "";
          const nested = list(node, nodeName, depth + 1);
          return content
            ? [link(ncx.path, content.getAttribute("src"), title, nested)]
            : nested;
        });
      };
      for (const [name, node, key] of [
        ["navMap", "navPoint", "toc"],
        ["pageList", "pageTarget", "pageList"],
      ]) {
        const sections = elements(ncxDoc, NCX, name);
        if (sections.length > 1) fail("NAVIGATION", "Duplicate NCX section");
        if (sections.length) output[key] = list(sections[0], node);
      }
    }
  }
  if (!output.landmarks) {
    const guide = elements(doc, OPF, "guide").flatMap((node) =>
      children(node, OPF, "reference"),
    );
    if (guide.length)
      output.landmarks = guide.map((node) =>
        link(
          opfPath,
          node.getAttribute("href"),
          node.getAttribute("title") || node.getAttribute("type") || "",
        ),
      );
  }
  return output;
}
export async function readPublicationMetadata(
  readResource,
  availablePaths,
  limits,
) {
  const container = xml(
    await readResource("META-INF/container.xml", limits.xmlBytes),
  );
  if (
    container.documentElement.namespaceURI !== CONTAINER ||
    container.documentElement.localName !== "container"
  )
    fail("CONTAINER", "Invalid container root");
  const roots = elements(container, CONTAINER, "rootfile").filter(
    (e) => e.getAttribute("media-type") === "application/oebps-package+xml",
  );
  if (roots.length !== 1)
    fail("CONTAINER", "Exactly one supported rootfile required");
  const opfPath = canonicalArchivePath(
    roots[0].getAttribute("full-path"),
    limits,
  );
  const doc = xml(await readResource(opfPath, limits.xmlBytes));
  const pkg = doc.documentElement;
  if (pkg.namespaceURI !== OPF || pkg.localName !== "package")
    fail("OPF", "Invalid package root");
  const version = pkg.getAttribute("version");
  if (!/^[23](?:\.|$)/u.test(version)) fail("OPF", "Only EPUB 2/3 supported");
  const metadataNodes = elements(doc, OPF, "meta");
  let fixedLayout = metadataNodes.some(
    (node) =>
      (node.getAttribute("property") === "rendition:layout" &&
        node.textContent.trim() === "pre-paginated") ||
      (node.getAttribute("name") === "fixed-layout" &&
        node.getAttribute("content") === "true"),
  );
  if (availablePaths.has("META-INF/com.apple.ibooks.display-options.xml")) {
    const display = xml(
      await readResource(
        "META-INF/com.apple.ibooks.display-options.xml",
        limits.xmlBytes,
      ),
    );
    fixedLayout ||= Array.from(display.getElementsByTagName("option")).some(
      (node) =>
        node.getAttribute("name") === "fixed-layout" &&
        node.textContent.trim() === "true",
    );
  }
  fixedLayout ||= elements(doc, OPF, "itemref").some((node) =>
    (node.getAttribute("properties") || "")
      .split(/\s+/u)
      .includes("rendition:layout-pre-paginated"),
  );
  const items = new Map();
  for (const node of elements(doc, OPF, "item")) {
    const id = node.getAttribute("id");
    if (!id || items.has(id)) fail("OPF", "Missing/duplicate manifest id");
    const resource = resolveResource(opfPath, node.getAttribute("href"));
    if (!availablePaths.has(resource))
      fail("MISSING", `Manifest resource missing: ${resource}`);
    items.set(id, {
      id,
      path: resource,
      mediaType: node.getAttribute("media-type"),
      properties: (node.getAttribute("properties") || "").split(/\s+/u),
    });
  }
  const spine = elements(doc, OPF, "itemref").map((node) => {
    const item = items.get(node.getAttribute("idref"));
    if (!item) fail("OPF", "Spine references unknown id");
    if (!["application/xhtml+xml", "image/svg+xml"].includes(item.mediaType))
      fail("OPF", "Unsupported spine media type");
    return { ...item, linear: node.getAttribute("linear") !== "no" };
  });
  if (!spine.length) fail("OPF", "Missing spine");
  let covers = [...items.values()].filter((item) =>
    item.properties.includes("cover-image"),
  );
  if (!covers.length) {
    const ids = elements(doc, OPF, "meta")
      .filter((node) => node.getAttribute("name") === "cover")
      .map((node) => node.getAttribute("content"));
    covers = ids.map((id) => {
      if (!items.has(id)) fail("OPF", "Cover references unknown id");
      return items.get(id);
    });
  }
  if (covers.length > 1) fail("OPF", "Ambiguous cover declarations");
  const cover = covers[0] ?? null;
  if (
    cover &&
    ![
      "image/jpeg",
      "image/png",
      "image/svg+xml",
      "image/webp",
      "image/gif",
    ].includes(cover.mediaType)
  )
    fail("OPF", "Unsupported declared cover type");
  const navigation = await navigationMetadata(
    doc,
    opfPath,
    items,
    readResource,
    limits,
  );
  const readingProgression = elements(doc, OPF, "spine")[0]?.getAttribute(
    "page-progression-direction",
  );
  if (
    readingProgression &&
    !["ltr", "rtl", "default"].includes(readingProgression)
  )
    fail("OPF", "Invalid reading progression");
  return {
    ...navigation,
    ...(readingProgression ? { readingProgression } : {}),
    formatVersion: 1,
    layout: fixedLayout ? "pre-paginated" : "reflowable",
    epubVersion: version,
    title: elements(doc, DC, "title")[0]?.textContent.trim() || null,
    creators: elements(doc, DC, "creator").map((n) => n.textContent.trim()),
    identifiers: elements(doc, DC, "identifier").map((n) =>
      n.textContent.trim(),
    ),
    languages: elements(doc, DC, "language").map((n) => n.textContent.trim()),
    opfPath,
    spine,
    manifest: [...items.values()],
    cover: cover
      ? {
          path: cover.path,
          mediaType: cover.mediaType,
          provenance: "epub-metadata",
        }
      : null,
  };
}
