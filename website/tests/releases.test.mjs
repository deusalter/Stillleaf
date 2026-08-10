import test from "node:test";
import assert from "node:assert/strict";
import {
  getDownload,
  publication,
  releases,
  validateReleases,
} from "../src/releases.js";

// Synthetic inputs test policy only. They are never offered as real downloads.
const sampleArtifact = {
  url: "https://releases.stillleaf.app/Stillleaf-2.0.0.dmg",
  version: "2.0.0",
  sha256: "0123456789abcdef".repeat(4),
  verified: true,
};

function availableRelease(artifact = sampleArtifact) {
  return { ...releases[0], state: "available", artifact: { ...artifact } };
}

function errorsFor(release) {
  return validateReleases([release, releases[1]]);
}

test("checked-in state is valid, local, unavailable, and immutable", () => {
  assert.deepEqual(validateReleases(releases), []);
  assert.equal(publication.approved, false);
  assert.ok(Object.isFrozen(publication));
  assert.ok(Object.isFrozen(releases));
  assert.deepEqual(
    releases.map(({ id }) => id),
    ["macos", "windows"],
  );
  for (const release of releases) {
    assert.ok(Object.isFrozen(release));
    assert.ok(Object.isFrozen(release.requirements));
    assert.equal(release.state, "development");
    assert.equal(release.artifact, null);
    assert.equal(getDownload(release), null);
  }
});

test("publication gate keeps even a complete available candidate unclickable", () => {
  const candidate = availableRelease();
  assert.deepEqual(errorsFor(candidate), []);
  assert.equal(getDownload(candidate), null);
  assert.ok(
    validateReleases([candidate, releases[1]], {
      requirePublicationApproval: true,
    }).some((error) => error.includes("not approved")),
  );
});

test("publication checks reject the current local-only configuration", () => {
  const errors = validateReleases(releases, {
    requirePublicationApproval: true,
  });
  assert.ok(errors.some((error) => error.includes("not approved")));
  assert.ok(errors.some((error) => error.includes("at least one available")));
});

test("adding only a URL cannot advertise an available release", () => {
  const development = { ...releases[0], artifact: { url: sampleArtifact.url } };
  assert.ok(
    errorsFor(development).some((error) => error.includes("artifact null")),
  );
  assert.equal(getDownload(development), null);
  const candidate = availableRelease({ url: sampleArtifact.url });
  const errors = errorsFor(candidate);
  assert.equal(errors.length, 3);
  assert.ok(errors.some((error) => error.includes("version")));
  assert.ok(errors.some((error) => error.includes("SHA-256")));
  assert.ok(errors.some((error) => error.includes("verified")));
});

test("available release requires version, exact checksum, and explicit verification", () => {
  for (const [key, value] of [
    ["version", "latest"],
    ["version", ""],
    ["sha256", ""],
    ["sha256", "0".repeat(64)],
    ["sha256", "a".repeat(64)],
    ["sha256", "not-a-checksum"],
    ["verified", false],
    ["verified", "true"],
    ["verified", 1],
  ]) {
    assert.ok(
      errorsFor(availableRelease({ ...sampleArtifact, [key]: value })).length >
        0,
      `${key}=${String(value)} must fail`,
    );
  }
  assert.ok(errorsFor({ ...availableRelease(), artifact: null }).length > 0);
});

test("unsafe, local, placeholder, and incomplete artifact URLs fail closed", () => {
  const rejected = [
    "http://releases.stillleaf.app/Stillleaf.dmg",
    "javascript:alert(1)",
    "/downloads/Stillleaf.dmg",
    "#download",
    "",
    "https://example.com/Stillleaf.dmg",
    "https://cdn.example.org/Stillleaf.dmg",
    "https://releases.example/Stillleaf.dmg",
    "https://releases.invalid/Stillleaf.dmg",
    "https://localhost/Stillleaf.dmg",
    "https://reader.local/Stillleaf.dmg",
    "https://downloads.test/Stillleaf.dmg",
    "https://127.0.0.1/Stillleaf.dmg",
    "https://192.168.1.1/Stillleaf.dmg",
    "https://[::1]/Stillleaf.dmg",
    "https://user:password@releases.stillleaf.app/Stillleaf.dmg",
    "https://releases.stillleaf.app:8443/Stillleaf.dmg",
    "https://releases.stillleaf.app/",
    "https://releases.stillleaf.app/Stillleaf.dmg#todo",
    "https://github.com/your-org/stillleaf/releases/download/v2.0.0/Stillleaf.dmg",
    "https://releases.stillleaf.app/%70laceholder/Stillleaf.dmg",
    " https://releases.stillleaf.app/Stillleaf.dmg",
  ];
  for (const url of rejected) {
    assert.ok(
      errorsFor(availableRelease({ ...sampleArtifact, url })).some((error) =>
        error.includes("HTTPS"),
      ),
      `Should reject ${url}`,
    );
  }
});

test("both platform entries, unique identifiers, and clear copy are required", () => {
  assert.ok(validateReleases(null).length > 0);
  assert.ok(
    validateReleases([]).some((error) => error.includes("Missing platform")),
  );
  assert.ok(validateReleases([null, releases[1]]).length > 0);
  assert.ok(
    validateReleases([releases[0], releases[0], releases[1]]).some((error) =>
      error.includes("Duplicate platform"),
    ),
  );
  for (const patch of [
    { id: "linux" },
    { name: "" },
    { summary: "" },
    { requirements: [] },
    { requirements: [""] },
    { requirements: null },
    { state: "released" },
  ])
    assert.ok(errorsFor({ ...releases[0], ...patch }).length > 0);
});

test("download helper safely rejects missing or malformed input", () => {
  for (const release of [null, undefined, {}, [], { state: "available" }]) {
    assert.equal(getDownload(release), null);
  }
});
