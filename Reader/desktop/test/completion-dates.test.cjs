"use strict";
const { test } = require("node:test"),
  assert = require("node:assert/strict"),
  { execFileSync } = require("node:child_process"),
  path = require("node:path");
const helper = path.resolve(__dirname, "../src/completion-dates.cjs");
function resolve(zone, selected, original, now = "2026-09-24T20:00:00Z") {
  return JSON.parse(
    execFileSync(
      process.execPath,
      [
        "-e",
        `const {selectLocalDay}=require(${JSON.stringify(helper)});process.stdout.write(JSON.stringify(selectLocalDay(...JSON.parse(process.argv[1]))))`,
        JSON.stringify([selected, original, now]),
      ],
      {
        env: { ...process.env, TZ: zone },
        encoding: "utf8",
        stdio: ["pipe", "pipe", "pipe"],
      },
    ),
  );
}
test("same local calendar date preserves exact instant and milliseconds; null stays unknown", () => {
  assert.equal(
    resolve("America/Los_Angeles", "2026-09-01", "2026-09-01T20:42:13.678Z"),
    "2026-09-01T20:42:13.678Z",
  );
  assert.equal(resolve("America/Los_Angeles", null, null), null);
  assert.equal(
    resolve("America/Los_Angeles", null, "2026-09-01T20:42:13.678Z"),
    null,
  );
});
test("new civil days preserve wall clock across DST; unknown starts at local day start", () => {
  assert.equal(
    resolve("America/Los_Angeles", "2026-03-09", "2026-03-07T20:42:13.678Z"),
    "2026-03-09T19:42:13.000Z",
  );
  assert.equal(
    resolve("America/Los_Angeles", "2026-03-08", null),
    "2026-03-08T08:00:00.000Z",
  );
});
test("DST gap chooses next valid clock; overlap chooses first; half-hour gap supported", () => {
  assert.equal(
    resolve("America/Los_Angeles", "2026-03-08", "2026-03-07T10:30:00Z"),
    "2026-03-08T10:00:00.000Z",
  );
  assert.equal(
    resolve("America/Los_Angeles", "2025-11-02", "2025-11-01T08:30:00Z"),
    "2025-11-02T08:30:00.000Z",
  );
  assert.equal(
    resolve("Australia/Lord_Howe", "2025-10-05", "2025-10-03T15:45:00Z"),
    "2025-10-04T15:30:00.000Z",
  );
});
test("today clamps retained later clock to actual now; invalid future and missing days rejected", () => {
  assert.equal(
    resolve("America/Los_Angeles", "2026-09-24", "2026-09-01T23:00:00Z"),
    "2026-09-24T20:00:00.000Z",
  );
  assert.throws(
    () => resolve("America/Los_Angeles", "2026-09-25", null),
    /future/,
  );
  assert.throws(
    () => resolve("Pacific/Apia", "2011-12-30", null),
    /does not exist/,
  );
  assert.throws(
    () => resolve("UTC", "2026-02-30", null),
    /Invalid reading day/,
  );
});
