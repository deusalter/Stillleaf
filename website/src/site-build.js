import { publication } from "./releases.js";

/**
 * Pure helpers the Vite plugin uses to finish each HTML page at build time.
 * Every page is written with tokens such as {{contact}}; nothing here reads the
 * network or the user's machine.
 */

/** Built pages and their public paths. Keep in sync with vite.config.js inputs. */
export const pages = Object.freeze([
  Object.freeze({ file: "index.html", path: "/" }),
  Object.freeze({ file: "privacy/index.html", path: "/privacy/" }),
  Object.freeze({ file: "support/index.html", path: "/support/" }),
  Object.freeze({ file: "about/index.html", path: "/about/" }),
  Object.freeze({ file: "terms/index.html", path: "/terms/" }),
]);

/** @param {string} value */
export function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

/**
 * Search engines may index the site only after publication is approved and a
 * public origin exists. Until then every page says noindex.
 * @param {{origin: string|null}} site
 * @param {{approved: boolean}} [gate]
 */
export function isIndexable(site, gate = publication) {
  return gate.approved === true && typeof site.origin === "string";
}

/** Map a Vite HTML path ("/privacy/index.html") to its public path ("/privacy/"). */
export function publicPath(htmlPath) {
  const path = `/${String(htmlPath).replace(/^\/+/, "")}`;
  return path.endsWith("index.html") ? path.slice(0, -"index.html".length) : path;
}

/** @param {string} isoDate YYYY-MM-DD */
export function formatDate(isoDate) {
  return new Date(`${isoDate}T12:00:00Z`).toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });
}

/** Visible marker for a decision that must be made before launch. */
function pending(text) {
  return `<span class="pending-config">${escapeHTML(text)}</span>`;
}

/**
 * Replace page tokens with configured values or visible "pending" markers.
 * @param {string} html
 * @param {import("./site-config.js").SiteConfig} site
 */
export function fillTokens(html, site, gate = publication) {
  const email = site.contactEmail;
  const values = {
    contact: email
      ? `<a href="mailto:${escapeHTML(email)}">${escapeHTML(email)}</a>`
      : pending("Contact address added before launch"),
    "contact-email": email ? escapeHTML(email) : "",
    publisher: site.legal.publisher
      ? escapeHTML(site.legal.publisher)
      : pending("Publisher name added before launch"),
    "effective-date": site.legal.effectiveDate
      ? `<time datetime="${site.legal.effectiveDate}">${formatDate(site.legal.effectiveDate)}</time>`
      : pending("Date set at publication"),
    "site-header": siteHeader,
    "site-footer": siteFooter,
    ios: iosCard(site.ios),
    "release-note":
      gate.approved === true
        ? "Each download is the exact build we verified, with its SHA-256 checksum listed here."
        : "This is a preview of the Stillleaf website. No downloads are published yet.",
    "feed-path": escapeHTML(site.updates.feedPath),
    "json-path": escapeHTML(site.updates.jsonPath),
  };
  return html.replace(/\{\{([a-z-]+)\}\}/g, (match, key) =>
    Object.hasOwn(values, key) ? values[key] : match,
  );
}

const leafMark =
  '<svg class="brand-mark" viewBox="0 0 100 100" fill="currentColor" aria-hidden="true"><use href="/leaf.svg#pageleaf" /></svg>';

/** Shared header. Links are root-relative so they work from every page. */
export const siteHeader = `<a class="skip-link" href="#main">Skip to content</a>
    <header class="site-header">
      <a class="wordmark" href="/" aria-label="Stillleaf home">
        ${leafMark}
        <span>Stillleaf</span>
      </a>
      <nav aria-label="Main navigation">
        <a href="/#next-chapter">Reader</a>
        <a href="/#your-reading">Journal</a>
        <a href="/#privacy">Privacy</a>
        <a class="nav-release" href="/#downloads"
          >Get Stillleaf <span aria-hidden="true">↓</span></a
        >
      </nav>
    </header>`;

/** Shared footer with the pages an app listing needs. */
export const siteFooter = `<footer class="site-footer section-wrap">
      <a class="wordmark" href="/" aria-label="Stillleaf home"
        ><img src="/leaf.svg" alt="" width="30" height="32" /><span
          >Stillleaf</span
        ></a
      >
      <p>A little space for a life with books.</p>
      <nav class="footer-links" aria-label="Footer">
        <a href="/support/">Support</a>
        <a href="/privacy/">Privacy</a>
        <a href="/terms/">Terms</a>
        <a href="/about/">About and press</a>
      </nav>
    </footer>`;

const phoneIcon =
  '<svg viewBox="0 0 24 32" fill="none" aria-hidden="true"><rect x="4" y="1" width="16" height="29" rx="3" stroke="currentColor" stroke-width="1.3"/><path d="M9 5h6M10 26h4" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>';

/**
 * The iPhone and iPad card. "available" links to the App Store with Apple's
 * official badge, which must be added as public/badges/app-store.svg first
 * (see ASSETS.md); the build fails rather than inventing badge artwork.
 * @param {{state: string, appStoreURL: string|null}} ios
 */
export function iosCard(ios) {
  if (ios.state === "hidden") return "";
  const available = ios.state === "available";
  const status = available
    ? `<a class="app-store-badge" href="${escapeHTML(ios.appStoreURL)}"><img src="/badges/app-store.svg" alt="Download on the App Store" width="120" height="40" /></a>`
    : '<span class="mobile-status">Coming soon</span>';
  const detail = available
    ? "Your journal, in your pocket."
    : "In development. No release date announced yet.";
  return `<div class="mobile-roadmap closing-mobile" data-ios-state="${escapeHTML(ios.state)}">
              ${phoneIcon}
              <div>
                <h3>Stillleaf for iPhone and iPad</h3>
                <p>${detail}</p>
              </div>
              ${status}
            </div>`;
}

/**
 * Head tags that depend on configuration, as Vite tag descriptors.
 * @param {string} path Public page path.
 * @param {import("./site-config.js").SiteConfig} site
 * @param {{approved: boolean}} [gate]
 */
export function headTags(path, site, gate = publication, { csp = false } = {}) {
  const indexable = isIndexable(site, gate) && path !== "/404.html";
  const tags = [
    {
      tag: "meta",
      attrs: {
        name: "robots",
        content: indexable ? "index, follow" : "noindex, nofollow",
      },
    },
  ];
  if (csp)
    tags.unshift({
      tag: "meta",
      attrs: { "http-equiv": "Content-Security-Policy", content: contentSecurityPolicy },
    });
  const image = `${site.origin ?? ""}/og-image.jpg`;
  tags.push(
    { tag: "meta", attrs: { property: "og:image", content: image } },
    { tag: "meta", attrs: { property: "og:image:width", content: "1200" } },
    { tag: "meta", attrs: { property: "og:image:height", content: "630" } },
    {
      tag: "meta",
      attrs: {
        property: "og:image:alt",
        content: "Stillleaf: Make room for reading. Floating books beside the Pageleaf mark.",
      },
    },
    { tag: "meta", attrs: { name: "twitter:image", content: image } },
  );
  if (site.origin) {
    const url = `${site.origin}${path}`;
    tags.push(
      { tag: "link", attrs: { rel: "canonical", href: url } },
      { tag: "meta", attrs: { property: "og:url", content: url } },
    );
  }
  return tags.map((tag) => ({
    ...tag,
    // The policy must precede everything it governs.
    injectTo: tag.attrs["http-equiv"] ? "head-prepend" : "head",
  }));
}

/**
 * Everything is served from this site: no third-party scripts, fonts, frames,
 * or form targets. Inline style attributes remain allowed for CSS variables.
 * Hosts that support headers should also send it (see DEPLOY.md).
 */
export const contentSecurityPolicy = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self'",
  "connect-src 'self'",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'none'",
  "upgrade-insecure-requests",
].join("; ");

/** @param {import("./site-config.js").SiteConfig} site @param {{approved: boolean}} [gate] */
export function robotsTxt(site, gate = publication) {
  if (!isIndexable(site, gate)) return "User-agent: *\nDisallow: /\n";
  return `User-agent: *\nAllow: /\n\nSitemap: ${site.origin}/sitemap.xml\n`;
}

/** @param {import("./site-config.js").SiteConfig} site @param {{approved: boolean}} [gate] */
export function sitemapXML(site, gate = publication) {
  if (!isIndexable(site, gate)) return null;
  const urls = pages
    .map((page) => `  <url><loc>${escapeHTML(site.origin + page.path)}</loc></url>`)
    .join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`;
}
