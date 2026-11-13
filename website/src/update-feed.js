import { getDownload } from "./releases.js";

/**
 * The Mac app's update feed, generated at build time from `releases.js` and
 * written to `site.updates.feedPath` (/updates/macos.json). Its format is the
 * one the app parses (Sources/BooksCore/UpdateFeed.swift) and the release
 * scripts write (scripts/release/make-update-feed.py); the shared example is
 * Tests/Fixtures/update-feed/macos.json. The feed does not exist until a Mac
 * release passes every gate in `getDownload` and the site has a public origin.
 * An absent feed means "no update available".
 */

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
 * @param {{origin: string, updates: {bundleIdentifier: string}}} site
 * @returns {string}
 */
export function macUpdateFeed(release, site) {
  const a = release.artifact;
  const body = {
    schemaVersion: 1,
    bundleIdentifier: site.updates.bundleIdentifier,
    latest: {
      version: a.version,
      build: a.build,
      minimumSystemVersion: a.minimumSystemVersion,
      publishedAt: a.publishedAt,
      url: a.url,
      sha256: a.sha256.toLowerCase(),
      size: a.size,
      // The app opens this page from "Open Download Page"; it lists the checksum and requirements.
      releaseNotesURL: `${site.origin}/#downloads`,
    },
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
    { fileName: site.updates.feedPath.slice(1), source: macUpdateFeed(release, site) },
  ];
}
