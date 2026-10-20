import test from "node:test";
import assert from "node:assert/strict";
import { site, validateSite } from "../src/site-config.js";
import {
  fillTokens,
  headTags,
  iosCard,
  isIndexable,
  publicPath,
  robotsTxt,
  sitemapXML,
} from "../src/site-build.js";
import { releases } from "../src/releases.js";
import { appcastXML, latestJSON, updateFeedFiles } from "../src/update-feed.js";

const approved = { approved: true };
const local = { approved: false };
const configured = {
  ...site,
  origin: "https://stillleaf.app",
  contactEmail: "hello@stillleaf.app",
  legal: { publisher: "Sample Publisher", effectiveDate: "2026-11-02" },
};

test("checked-in site config is valid, local, and frozen", () => {
  assert.deepEqual(validateSite(site), []);
  assert.ok(Object.isFrozen(site) && Object.isFrozen(site.legal));
  assert.equal(site.origin, null);
  assert.equal(site.ios.state, "coming-soon");
  assert.equal(site.ios.appStoreURL, null);
  assert.equal(isIndexable(site), false);
});

test("publication requires every open decision to be made", () => {
  const errors = validateSite(site, { requirePublication: true });
  for (const needle of ["origin", "contact", "publisher", "effective date"])
    assert.ok(
      errors.some((error) => error.toLowerCase().includes(needle)),
      `missing ${needle}`,
    );
  assert.deepEqual(validateSite(configured, { requirePublication: true }), []);
});

test("site values fail closed on placeholders and malformed input", () => {
  for (const origin of [
    "http://stillleaf.app",
    "https://stillleaf.app/",
    "https://stillleaf.app/path",
    "https://example.com",
    "https://localhost",
    "https://127.0.0.1",
    "stillleaf.app",
    " https://stillleaf.app",
  ])
    assert.ok(validateSite({ ...site, origin }).length > 0, origin);
  for (const contactEmail of ["", "hello", "hello@example.com", "a b@c.de"])
    assert.ok(validateSite({ ...site, contactEmail }).length > 0, contactEmail);
  for (const effectiveDate of ["2026-02-30", "11/02/2026", "soon"])
    assert.ok(
      validateSite({ ...site, legal: { publisher: null, effectiveDate } })
        .length > 0,
      effectiveDate,
    );
  assert.ok(validateSite(null).length > 0);
  assert.ok(
    validateSite({ ...site, updates: { feedPath: "updates.xml", jsonPath: "/x.json" } })
      .length > 0,
  );
});

test("iOS state switches between hidden, coming soon, and the App Store", () => {
  assert.equal(iosCard({ state: "hidden", appStoreURL: null }), "");
  const soon = iosCard({ state: "coming-soon", appStoreURL: null });
  assert.match(soon, /Coming soon/);
  assert.doesNotMatch(soon, /apps\.apple\.com|<a /);
  const url = "https://apps.apple.com/app/stillleaf/id1234567890";
  const live = iosCard({ state: "available", appStoreURL: url });
  assert.match(live, new RegExp(`href="${url}"`));
  assert.match(live, /alt="Download on the App Store"/);

  const ios = (state, appStoreURL) => validateSite({ ...site, ios: { state, appStoreURL } });
  assert.deepEqual(ios("available", url), []);
  assert.ok(ios("available", null).length > 0);
  assert.ok(ios("available", "https://apps.apple.com/app/stillleaf").length > 0);
  assert.ok(ios("available", "https://example.com/id1234567890").length > 0);
  assert.ok(ios("coming-soon", url).length > 0, "no store link before launch");
  assert.ok(ios("beta", null).length > 0);
});

test("pages stay noindex until publication is approved and an origin exists", () => {
  const robots = (tags) => tags.find((tag) => tag.attrs.name === "robots").attrs.content;
  assert.equal(robots(headTags("/", site, approved)), "noindex, nofollow");
  assert.equal(robots(headTags("/", configured, local)), "noindex, nofollow");
  assert.equal(robots(headTags("/", configured, approved)), "index, follow");
  assert.equal(robots(headTags("/404.html", configured, approved)), "noindex, nofollow");
  assert.equal(robotsTxt(configured, local), "User-agent: *\nDisallow: /\n");
  assert.match(robotsTxt(configured, approved), /Sitemap: https:\/\/stillleaf\.app\/sitemap\.xml/);
  assert.equal(sitemapXML(configured, local), null);
  const sitemap = sitemapXML(configured, approved);
  for (const path of ["/", "/privacy/", "/support/", "/about/", "/terms/"])
    assert.ok(sitemap.includes(`<loc>https://stillleaf.app${path}</loc>`), path);
});

test("canonical and Open Graph URLs are absolute once the origin is known", () => {
  const attrs = (tags, key, value) => tags.find((tag) => tag.attrs[key] === value)?.attrs;
  const preview = headTags("/privacy/", site, local);
  assert.equal(attrs(preview, "rel", "canonical"), undefined);
  assert.equal(attrs(preview, "property", "og:image").content, "/og-image.jpg");
  const live = headTags("/privacy/", configured, approved, { csp: true });
  assert.equal(attrs(live, "rel", "canonical").href, "https://stillleaf.app/privacy/");
  assert.equal(attrs(live, "property", "og:url").content, "https://stillleaf.app/privacy/");
  assert.equal(attrs(live, "property", "og:image").content, "https://stillleaf.app/og-image.jpg");
  const csp = live.find((tag) => tag.attrs["http-equiv"]);
  assert.equal(csp.injectTo, "head-prepend");
  assert.match(csp.attrs.content, /script-src 'self'/);
  assert.doesNotMatch(csp.attrs.content, /script-src[^;]*unsafe/);
  assert.equal(publicPath("/privacy/index.html"), "/privacy/");
  assert.equal(publicPath("index.html"), "/");
  assert.equal(publicPath("/404.html"), "/404.html");
});

test("tokens fill from config, show pending markers, and escape values", () => {
  const html = "{{contact}} {{publisher}} {{effective-date}} {{feed-path}} {{unknown}}";
  const pending = fillTokens(html, site, local);
  assert.equal((pending.match(/class="pending-config"/g) ?? []).length, 3);
  assert.match(pending, /\/updates\/appcast\.xml/);
  assert.match(pending, /\{\{unknown\}\}/, "unknown tokens are left visible");
  const filled = fillTokens(html, configured, approved);
  assert.match(filled, /href="mailto:hello@stillleaf\.app"/);
  assert.match(filled, /<time datetime="2026-11-02">November 2, 2026<\/time>/);
  assert.doesNotMatch(filled, /pending-config/);
  const hostile = fillTokens("{{publisher}}", {
    ...configured,
    legal: { ...configured.legal, publisher: '<script>"x"</script>' },
  });
  assert.doesNotMatch(hostile, /<script>/);
  assert.match(fillTokens("{{release-note}}", site, local), /No downloads are published yet/);
});

const publishedMac = {
  ...releases[0],
  state: "available",
  artifact: {
    url: "https://releases.stillleaf.app/Stillleaf-2.0.0.dmg",
    version: "2.0.0",
    build: "24",
    minimumSystemVersion: "13.0",
    length: 18204331,
    publishedAt: "2026-11-02T17:00:00Z",
    sha256: "0123456789ABCDEF".repeat(4),
    edSignature: `${"A".repeat(86)}==`,
    verified: true,
  },
};

test("no update feed is published from the checked-in configuration", () => {
  assert.deepEqual(updateFeedFiles(releases, site), []);
  assert.deepEqual(updateFeedFiles(releases, configured), []);
  // Even a complete release stays unpublished while publication.approved is false.
  assert.deepEqual(updateFeedFiles([publishedMac, releases[1]], configured), []);
});

test("appcast and JSON feed describe the exact verified Mac artifact", () => {
  const xml = appcastXML(publishedMac, configured);
  for (const fragment of [
    'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"',
    "<sparkle:version>24</sparkle:version>",
    "<sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>",
    "<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>",
    "<pubDate>Mon, 02 Nov 2026 17:00:00 GMT</pubDate>",
    'url="https://releases.stillleaf.app/Stillleaf-2.0.0.dmg" length="18204331"',
    `sparkle:edSignature="${"A".repeat(86)}=="`,
  ])
    assert.ok(xml.includes(fragment), fragment);
  const json = JSON.parse(latestJSON(publishedMac, configured));
  assert.deepEqual(json, {
    schemaVersion: 1,
    platform: "macos",
    version: "2.0.0",
    build: "24",
    minimumSystemVersion: "13.0",
    publishedAt: "2026-11-02T17:00:00Z",
    url: "https://releases.stillleaf.app/Stillleaf-2.0.0.dmg",
    length: 18204331,
    sha256: "0123456789abcdef".repeat(4),
    edSignature: `${"A".repeat(86)}==`,
    downloadPage: "https://stillleaf.app/#downloads",
  });
  const unsigned = { ...publishedMac, artifact: { ...publishedMac.artifact } };
  delete unsigned.artifact.edSignature;
  assert.doesNotMatch(appcastXML(unsigned, configured), /edSignature/);
  assert.equal("edSignature" in JSON.parse(latestJSON(unsigned, configured)), false);
});
