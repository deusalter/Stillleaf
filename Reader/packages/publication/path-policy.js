import { fail } from "./errors.js";
/** Reject ambiguous names rather than relying on host-specific filesystem normalization. */
export function canonicalArchivePath(value, { pathBytes = 512 } = {}) {
  if (
    typeof value !== "string" ||
    !value ||
    new TextEncoder().encode(value).length > pathBytes ||
    value !== value.normalize("NFC") ||
    /[\\%\x00-\x1f\x7f:?#]/u.test(value) ||
    value.startsWith("/")
  )
    fail("PATH", "Unsafe archive name");
  const name = value.endsWith("/") ? value.slice(0, -1) : value;
  if (!name) fail("PATH", "Empty archive name");
  for (const part of name.split("/"))
    if (
      !part ||
      part === "." ||
      part === ".." ||
      /[. ]$/u.test(part) ||
      /^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(?:\.|$)/iu.test(part) ||
      /[<>"|*]/u.test(part)
    )
      fail("PATH", `Nonportable archive name: ${value}`);
  return name;
}
export function resolveResource(base, href) {
  if (
    typeof href !== "string" ||
    !href ||
    /^[a-z][a-z0-9+.-]*:/iu.test(href) ||
    href.startsWith("/") ||
    href.startsWith("\\") ||
    href.includes("?")
  )
    fail("REFERENCE", "External or malformed resource reference");
  const raw = href.split("#")[0];
  let decoded;
  try {
    decoded = decodeURIComponent(raw);
  } catch {
    fail("REFERENCE", "Invalid reference encoding");
  }
  if (
    /%(?:2e|2f|5c|25)/iu.test(raw) ||
    decoded.includes("\\") ||
    decoded.includes("%")
  )
    fail("REFERENCE", "Encoded traversal or ambiguous reference");
  const parts = base.split("/");
  parts.pop();
  for (const part of decoded.split("/")) {
    if (part === "..") {
      if (!parts.length)
        fail("REFERENCE", "Reference escapes publication root");
      parts.pop();
    } else if (part !== "." && part !== "") {
      parts.push(part);
    }
  }
  const resolved = parts.join("/");
  return canonicalArchivePath(resolved);
}
