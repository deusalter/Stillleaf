/**
 * A release is an explicit publishing decision, not merely a URL.
 * Keep approval false until the combined reader release is ready and authorized.
 * Artifact verification records a human release check; this module makes no
 * network requests and cannot prove that a remote binary is available or safe.
 */
export const publication = Object.freeze({ approved: false });

/**
 * @typedef {Object} ReleaseArtifact
 * @property {string} url Permanent public HTTPS download URL.
 * @property {string} version Version of the exact verified binary.
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
      "The Mac reading journal exists today. Its built-in EPUB reader is in development; a download will follow when the next release is ready.",
    requirements: Object.freeze([
      "The current Mac tracker requires macOS 13 or later.",
      "Requirements for the next release will be confirmed before download.",
    ]),
    artifact: null,
  }),
  Object.freeze({
    id: "windows",
    name: "Windows",
    state: "development",
    summary:
      "We’re bringing the reading journal and built-in EPUB reader to Windows. A tested release is still ahead.",
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
const versionPattern =
  /^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$/;

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

  const { url, version, sha256, verified } = release.artifact;
  if (!isPublicArtifactURL(url)) {
    errors.push(
      `${label} artifact needs a public HTTPS file URL without credentials, fragments, local hosts, or placeholder domains/paths.`,
    );
  }
  if (typeof version !== "string" || !versionPattern.test(version)) {
    errors.push(`${label} artifact needs a version such as 1.5.0.`);
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
