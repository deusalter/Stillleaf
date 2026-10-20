/**
 * Site-wide publication settings. Like `releases.js`, these are explicit
 * decisions: leave a value null until the owner has chosen it. The build reads
 * this file to fill canonical URLs, contact links, legal dates, robots rules,
 * the sitemap and the iOS card. Nothing here contacts a server.
 */

/**
 * @typedef {'hidden'|'coming-soon'|'available'} IOSState
 *
 * @typedef {Object} SiteConfig
 * @property {string|null} origin Public HTTPS origin, without a trailing slash, e.g. "https://stillleaf.app".
 * @property {string|null} contactEmail Support and privacy contact address.
 * @property {{publisher: string|null, effectiveDate: string|null}} legal
 *   Publisher is the person or company responsible for the app; effectiveDate is YYYY-MM-DD.
 * @property {{state: IOSState, appStoreURL: string|null}} ios
 * @property {{feedPath: string, jsonPath: string}} updates Paths the Mac app's updater reads.
 */

/** @type {Readonly<SiteConfig>} */
export const site = Object.freeze({
  origin: null,
  contactEmail: null,
  legal: Object.freeze({ publisher: null, effectiveDate: null }),
  ios: Object.freeze({ state: "coming-soon", appStoreURL: null }),
  updates: Object.freeze({
    feedPath: "/updates/appcast.xml",
    jsonPath: "/updates/latest.json",
  }),
});

const iosStates = new Set(["hidden", "coming-soon", "available"]);
const placeholderHosts =
  /(^|\.)(example\.(com|net|org)|example|invalid|localhost|local|test)$/i;

/** @param {unknown} value @returns {value is Record<string, unknown>} */
function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** @param {unknown} value @returns {boolean} */
export function isPublicOrigin(value) {
  if (typeof value !== "string" || value !== value.trim()) return false;
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    return (
      url.protocol === "https:" &&
      url.origin === value &&
      host.includes(".") &&
      !/^\d+(?:\.\d+){3}$/.test(host) &&
      !placeholderHosts.test(host)
    );
  } catch {
    return false;
  }
}

/** @param {unknown} value @returns {boolean} */
export function isEmailAddress(value) {
  return (
    typeof value === "string" &&
    /^[^\s@<>"]+@[^\s@<>"]+\.[a-z]{2,}$/i.test(value) &&
    !placeholderHosts.test(value.split("@")[1])
  );
}

/** @param {unknown} value @returns {boolean} */
function isCalendarDate(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value))
    return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().startsWith(value);
}

/** Apple's App Store product pages live on apps.apple.com and carry a numeric id. */
export function isAppStoreURL(value) {
  if (typeof value !== "string") return false;
  try {
    const url = new URL(value);
    return (
      url.protocol === "https:" &&
      url.hostname === "apps.apple.com" &&
      /\/id\d{6,}$/.test(url.pathname)
    );
  } catch {
    return false;
  }
}

/** @param {unknown} value @returns {boolean} */
function isSitePath(value) {
  return (
    typeof value === "string" &&
    /^\/[a-z0-9/_-]+\.(xml|json)$/i.test(value) &&
    !value.includes("//")
  );
}

/**
 * Structural checks always run; completeness checks are for publication only,
 * so the local preview keeps building while decisions are pending.
 *
 * @param {unknown} config
 * @param {{requirePublication?: boolean}} [options]
 * @returns {string[]}
 */
export function validateSite(config, { requirePublication = false } = {}) {
  if (!isRecord(config)) return ["Site configuration must be an object."];
  const errors = [];
  const { origin, contactEmail, legal, ios, updates } = config;

  if (origin !== null && !isPublicOrigin(origin))
    errors.push(
      "Site origin must be null or a public HTTPS origin without a path, such as https://stillleaf.app.",
    );
  if (contactEmail !== null && !isEmailAddress(contactEmail))
    errors.push("Contact email must be null or a real address.");
  if (!isRecord(legal)) errors.push("Legal settings must be an object.");
  else {
    if (
      legal.publisher !== null &&
      !(typeof legal.publisher === "string" && legal.publisher.trim())
    )
      errors.push("Legal publisher must be null or a name.");
    if (legal.effectiveDate !== null && !isCalendarDate(legal.effectiveDate))
      errors.push("Legal effective date must be null or YYYY-MM-DD.");
  }
  if (!isRecord(ios) || !iosStates.has(ios.state))
    errors.push("iOS state must be hidden, coming-soon or available.");
  else if (ios.state === "available" && !isAppStoreURL(ios.appStoreURL))
    errors.push(
      "An available iOS app needs its apps.apple.com product URL (ending in /id followed by digits).",
    );
  else if (ios.state !== "available" && ios.appStoreURL !== null)
    errors.push("Keep the App Store URL null until the iOS app is available.");
  if (
    !isRecord(updates) ||
    !isSitePath(updates.feedPath) ||
    !isSitePath(updates.jsonPath)
  )
    errors.push("Update feed paths must be absolute site paths ending in .xml or .json.");

  if (requirePublication) {
    if (origin === null) errors.push("Publication needs the site origin (domain).");
    if (contactEmail === null)
      errors.push("Publication needs a support and privacy contact email.");
    if (!isRecord(legal) || legal.publisher === null)
      errors.push("Publication needs the legal publisher name.");
    if (!isRecord(legal) || legal.effectiveDate === null)
      errors.push("Publication needs the privacy policy and terms effective date.");
  }
  return errors;
}
