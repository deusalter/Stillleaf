import { getDownload } from "./releases.js";

/**
 * The Mac app's update feed, generated at build time from `releases.js`.
 * Two equivalent files are written next to the site:
 * - `site.updates.feedPath` (default /updates/appcast.xml): a Sparkle 2 appcast.
 * - `site.updates.jsonPath` (default /updates/latest.json): the same facts as JSON
 *   for a custom updater.
 * Neither file exists until a Mac release passes every gate in `getDownload`
 * and the site has a public origin. An absent feed means "no update available".
 */

/** @param {string} value */
function xml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

/**
 * The releasable Mac entry, or null when no feed should be published.
 * @param {readonly import("./releases.js").Release[]} releases
 * @param {{origin: string|null}} site
 */
export function publishedMacRelease(releases, site) {
  if (!site?.origin) return null;
  const mac = releases.find((release) => release?.id === "macos");
  return mac && getDownload(mac) ? mac : null;
}

/**
 * @param {import("./releases.js").Release} release A release that passed `getDownload`.
 * @param {{origin: string}} site
 * @returns {string}
 */
export function appcastXML(release, site) {
  const a = release.artifact;
  const signature = a.edSignature
    ? ` sparkle:edSignature="${xml(a.edSignature)}"`
    : "";
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Stillleaf for Mac</title>
    <link>${xml(site.origin)}/</link>
    <description>Stillleaf for Mac releases</description>
    <language>en</language>
    <item>
      <title>Stillleaf ${xml(a.version)}</title>
      <pubDate>${xml(new Date(a.publishedAt).toUTCString())}</pubDate>
      <sparkle:version>${xml(a.build)}</sparkle:version>
      <sparkle:shortVersionString>${xml(a.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${xml(a.minimumSystemVersion)}</sparkle:minimumSystemVersion>
      <link>${xml(site.origin)}/#downloads</link>
      <enclosure url="${xml(a.url)}" length="${a.length}" type="application/octet-stream"${signature}/>
    </item>
  </channel>
</rss>
`;
}

/**
 * @param {import("./releases.js").Release} release
 * @param {{origin: string}} site
 * @returns {string}
 */
export function latestJSON(release, site) {
  const a = release.artifact;
  const body = {
    schemaVersion: 1,
    platform: "macos",
    version: a.version,
    build: a.build,
    minimumSystemVersion: a.minimumSystemVersion,
    publishedAt: a.publishedAt,
    url: a.url,
    length: a.length,
    sha256: a.sha256.toLowerCase(),
    ...(a.edSignature ? { edSignature: a.edSignature } : {}),
    downloadPage: `${site.origin}/#downloads`,
  };
  return `${JSON.stringify(body, null, 2)}\n`;
}

/**
 * Files to emit, relative to the site root. Empty while nothing is published.
 * @param {readonly import("./releases.js").Release[]} releases
 * @param {import("./site-config.js").SiteConfig} site
 * @returns {{fileName: string, source: string}[]}
 */
export function updateFeedFiles(releases, site) {
  const release = publishedMacRelease(releases, site);
  if (!release) return [];
  return [
    { fileName: site.updates.feedPath.slice(1), source: appcastXML(release, site) },
    { fileName: site.updates.jsonPath.slice(1), source: latestJSON(release, site) },
  ];
}
