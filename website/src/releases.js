/**
 * A release is an explicit publishing decision, not merely a URL.
 * Keep approval false until the combined reader release is ready and authorized.
 * Artifact verification records a human release check; this module makes no
 * network requests and cannot prove that a remote binary is available or safe.
 */
export const publication = Object.freeze({ approved: false });

/**
 * @typedef {Object} ReleaseArtifact
 * @property {string} url Permanent public HTTPS download URL (the notarized DMG on Mac).
 * @property {string} version Marketing version of the exact verified binary (CFBundleShortVersionString).
 * @property {number} build Build number of that binary (CFBundleVersion, a positive integer); the app compares this.
 * @property {string} minimumSystemVersion Lowest supported OS version, such as "13.0".
 * @property {number} size Size of the download in bytes.
 * @property {string} publishedAt Release date and time, ISO 8601 with a timezone.
 * @property {string} sha256 SHA-256 digest of that binary (64 hexadecimal digits).
 * @property {boolean} verified True only after checking the exact release artifact.
 *
 * @typedef {Object} Release
 * @property {'macos'|'windows'} id
 * @property {string} name
 * @property {'development'|'available'} state
 * @property {string} summary
 * @property {readonly string[]} requirements
 * @property {ReleaseArtifact|null} artifact
 */

/** @type {readonly Release[]} */
export const releases = Object.freeze([
  Object.freeze({
    id: "macos",
    name: "Mac",
    state: "development",
    summary:
      "The menu-bar reading journal with its built-in EPUB reader. The notarized download will appear here when the release is ready.",
    requirements: Object.freeze([
      "macOS 13 Ventura or later.",
      "Optional Apple Books tracking needs Accessibility permission.",
      "Optional Discord presence needs the Discord desktop app.",
    ]),
    artifact: null,
  }),
  Object.freeze({
    id: "windows",
    name: "Windows",
    state: "development",
    summary:
      "The journal and reader are being brought to Windows. There is no tested release or date yet.",
    requirements: Object.freeze([
      "Supported Windows versions and hardware requirements will be confirmed with the release.",
    ]),
    artifact: null,
  }),
]);

const platforms = new Set(["macos", "windows"]);
const placeholderHosts =
  /(^|\.)(example\.(com|net|org)|example|invalid|localhost|local|test)$/i;
const placeholderSegments =
  /^(?:your[-_](?:org|user|username|domain)|placeholder|todo|changeme)$/i;
const systemVersionPattern = /^\d+\.\d+(?:\.\d+)?$/;
// The Mac app reads only MAJOR.MINOR.PATCH from its update feed (UpdateFeed.swift).
const versionPattern = /^\d+\.\d+\.\d+$/;

/** @param {unknown} value @returns {value is Record<string, unknown>} */
function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** @param {unknown} value @returns {value is string} */
function hasText(value) {
  return typeof value === "string" && value.trim().length > 0;
}

/** @param {unknown} value @returns {boolean} */
function isPublicArtifactURL(value) {
  if (!hasText(value) || value !== value.trim()) return false;
  try {
    const url = new URL(value);
    const hostname = url.hostname.toLowerCase().replace(/\.$/, "");
    const segments = decodeURIComponent(url.pathname).split("/");
    return (
      url.protocol === "https:" &&
      !url.username &&
      !url.password &&
      !url.hash &&
      (url.port === "" || url.port === "443") &&
      hostname.includes(".") &&
      !hostname.includes(":") &&
      !/^\d+(?:\.\d+){3}$/.test(hostname) &&
      !placeholderHosts.test(hostname) &&
      url.pathname !== "/" &&
      !segments.some((segment) => placeholderSegments.test(segment))
    );
  } catch {
    return false;
  }
}

/** @param {unknown} release @param {string} label @returns {string[]} */
function validateRelease(release, label) {
  if (!isRecord(release)) return [`${label} must be a release object.`];

  const errors = [];
  if (!platforms.has(release.id))
    errors.push(`${label} has an unsupported platform id.`);
  if (!hasText(release.name)) errors.push(`${label} needs a platform name.`);
  if (!hasText(release.summary))
    errors.push(`${label} needs an honest availability summary.`);
  if (
    !Array.isArray(release.requirements) ||
    release.requirements.length === 0 ||
    !release.requirements.every(hasText)
  ) {
    errors.push(
      `${label} needs at least one requirement or an explicit unconfirmed-requirements statement.`,
    );
  }
  if (release.state !== "development" && release.state !== "available") {
    errors.push(`${label} state must be development or available.`);
    return errors;
  }
  if (release.state === "development") {
    if (release.artifact !== null)
      errors.push(`${label} must keep artifact null while in development.`);
    return errors;
  }
  if (!isRecord(release.artifact)) {
    errors.push(
      `${label} requires a verified artifact before becoming available.`,
    );
    return errors;
  }

  const {
    url,
    version,
    build,
    minimumSystemVersion,
    size,
    publishedAt,
    sha256,
    verified,
  } = release.artifact;
  if (!isPublicArtifactURL(url)) {
    errors.push(
      `${label} artifact needs a public HTTPS file URL without credentials, fragments, local hosts, or placeholder domains/paths.`,
    );
  }
  if (typeof version !== "string" || !versionPattern.test(version)) {
    errors.push(`${label} artifact needs a version such as 1.5.0.`);
  }
  if (!Number.isSafeInteger(build) || build <= 0) {
    errors.push(`${label} artifact needs its build number, such as 18.`);
  }
  if (
    typeof minimumSystemVersion !== "string" ||
    !systemVersionPattern.test(minimumSystemVersion)
  ) {
    errors.push(
      `${label} artifact needs a minimum system version, such as 13.0.`,
    );
  }
  if (!Number.isSafeInteger(size) || size <= 0) {
    errors.push(`${label} artifact needs its download size in bytes.`);
  }
  if (
    typeof publishedAt !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(
      publishedAt,
    ) ||
    Number.isNaN(Date.parse(publishedAt))
  ) {
    errors.push(
      `${label} artifact needs a publication time such as 2026-11-02T17:00:00Z.`,
    );
  }
  if (
    typeof sha256 !== "string" ||
    !/^[a-f\d]{64}$/i.test(sha256) ||
    /^(.)\1{63}$/.test(sha256)
  ) {
    errors.push(
      `${label} artifact needs the exact binary's SHA-256 checksum, not a placeholder.`,
    );
  }
  if (verified !== true)
    errors.push(
      `${label} artifact must explicitly set verified to true after release verification.`,
    );
  return errors;
}

/**
 * Validate config without contacting a server or enabling a download.
 * Publication checks are opt-in so the unfinished website can build locally.
 *
 * @param {unknown} list
 * @param {{requirePublicationApproval?: boolean}} [options]
 * @returns {string[]}
 */
export function validateReleases(
  list,
  { requirePublicationApproval = false } = {},
) {
  const errors = [];
  if (!Array.isArray(list)) return ["Releases must be an array."];
  const seen = new Set();
  list.forEach((release, index) => {
    errors.push(...validateRelease(release, `Release ${index + 1}`));
    if (isRecord(release) && platforms.has(release.id)) {
      if (seen.has(release.id))
        errors.push(`Duplicate platform: ${release.id}.`);
      seen.add(release.id);
    }
  });
  for (const id of platforms) {
    if (!seen.has(id)) errors.push(`Missing platform: ${id}.`);
  }
  if (requirePublicationApproval) {
    if (publication.approved !== true)
      errors.push("Publication is not approved. Keep this website local.");
    if (
      !list.some(
        (release) =>
          isRecord(release) &&
          release.state === "available" &&
          validateRelease(release, "Release").length === 0,
      )
    ) {
      errors.push(
        "Publication requires at least one available, verified release.",
      );
    }
  }
  return errors;
}

/**
 * The UI must use this helper instead of reading artifact.url directly.
 * Neither a URL nor an available flag alone can enable a download button.
 *
 * @param {Release} release
 * @returns {{url: string, label: string}|null}
 */
export function getDownload(release) {
  if (
    publication.approved !== true ||
    !isRecord(release) ||
    release.state !== "available" ||
    validateRelease(release, "Release").length > 0
  ) {
    return null;
  }
  return { url: release.artifact.url, label: `Download for ${release.name}` };
}
