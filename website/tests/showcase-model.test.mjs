import test from "node:test";
import assert from "node:assert/strict";
import {
  clampProgress,
  dailyReading,
  journeyState,
  readerPresetAt,
  readerPresets,
  storyProgress,
} from "../src/showcase-model.js";

const invalidInputs = [
  NaN,
  Infinity,
  -Infinity,
  undefined,
  null,
  "",
  "0.5",
  true,
  {},
  [],
];

test("progress clamps finite numbers and rejects nonfinite or coercible input", () => {
  for (const [input, expected] of [
    [-5, 0],
    [-0, 0],
    [0, 0],
    [0.4, 0.4],
    [1, 1],
    [10, 1],
  ]) {
    assert.equal(clampProgress(input), expected);
  }
  for (const input of invalidInputs) assert.equal(clampProgress(input), 0);
});

test("story progress follows actual section travel and clamps outside it", () => {
  const positions = [500, 0, -400, -800, -1200, -1600, -2400];
  const expected = [0, 0, 0.25, 0.5, 0.75, 1, 1];
  assert.deepEqual(
    positions.map((top) => storyProgress(top, 2400, 800)),
    expected,
  );
  assert.deepEqual(
    [...positions].reverse().map((top) => storyProgress(top, 2400, 800)),
    [...expected].reverse(),
  );
  assert.equal(storyProgress(-250, 1250, 750), 0.5);
});

test("story progress remains finite for invalid or non-scrollable geometry", () => {
  for (const input of invalidInputs) {
    assert.equal(storyProgress(input, 2400, 800), 0);
    assert.equal(storyProgress(-800, input, 800), 0);
    assert.equal(storyProgress(-800, 2400, input), 0);
  }
  for (const [section, viewport] of [
    [800, 800],
    [400, 800],
    [0, 800],
    [-100, 800],
    [2400, 0],
    [2400, -1],
  ]) {
    assert.equal(storyProgress(-100, section, viewport), 0);
  }
  // Compare the endpoints before division, so a large coordinate over a tiny
  // travel distance reaches the end instead of overflowing into invalid input.
  assert.equal(storyProgress(-Number.MAX_VALUE, 1 + Number.EPSILON, 1), 1);
});

test("journey completes the daily goal before handing off to reader presets", () => {
  const start = journeyState(0);
  assert.deepEqual(start, {
    progress: 0,
    dailyProgress: 0,
    readerProgress: 0,
    blend: 0,
    night: 0,
    dailyCopy: 1,
    readerCopy: 0,
    activeScene: "daily",
  });
  assert.equal(dailyReading(journeyState(0.19).dailyProgress).pages, 12);
  const completed = journeyState(0.38);
  assert.equal(dailyReading(completed.dailyProgress).phase, "complete");
  assert.equal(completed.blend, 0);
  assert.equal(completed.readerProgress, 0);
  assert.equal(completed.activeScene, "daily");
  assert.equal(journeyState(0.5 - Number.EPSILON).activeScene, "daily");
  const handoff = journeyState(0.5);
  assert.equal(handoff.activeScene, "reader");
  assert.ok(Math.abs(handoff.blend - 0.5) < 1e-12);
  assert.equal(handoff.dailyCopy, 0);
  assert.equal(handoff.readerProgress, 0);
  assert.deepEqual(
    [0.56, 0.7, 0.8, 0.95, 1].map(
      (progress) => readerPresetAt(journeyState(progress).readerProgress).id,
    ),
    ["sea-glass", "paper", "dusk", "midnight", "midnight"],
  );
  const end = journeyState(1);
  assert.equal(end.activeScene, "reader");
  assert.equal(end.dailyCopy, 0);
  for (const field of [
    "progress",
    "dailyProgress",
    "readerProgress",
    "blend",
    "night",
    "readerCopy",
  ])
    assert.ok(
      Math.abs(end[field] - 1) < 1e-12,
      `${field} reaches its endpoint`,
    );
});

test("journey visual channels stay bounded and continuous through transition edges", () => {
  const delta = 1e-7;
  // Include the beginning/end of each fade and the discrete active-scene handoff.
  for (const edge of [
    0, 0.38, 0.4, 0.425, 0.49, 0.5, 0.56, 0.565, 0.6, 0.75, 1,
  ]) {
    const before = journeyState(edge - delta);
    const after = journeyState(edge + delta);
    for (const field of Object.keys(before).filter(
      (key) => key !== "activeScene",
    )) {
      assert.ok(
        Number.isFinite(before[field]) && Number.isFinite(after[field]),
      );
      assert.ok(before[field] >= 0 && before[field] <= 1);
      assert.ok(after[field] >= 0 && after[field] <= 1);
      // The shortest fade spans 7.5% of the journey: no visual channel jumps.
      assert.ok(
        Math.abs(after[field] - before[field]) <= (2 * delta) / 0.075 + 1e-12,
        `${field} remains continuous around ${edge}`,
      );
    }
  }
});

test("journey rewinds the entire composition without retaining a later scene", () => {
  const progress = [0, 0.19, 0.38, 0.45, 0.5, 0.62, 0.7, 0.8, 0.95, 1];
  const forward = progress.map(journeyState);
  assert.deepEqual(
    [...progress].reverse().map(journeyState),
    [...forward].reverse(),
  );
  assert.equal(journeyState(0.19).activeScene, "daily");
  assert.equal(dailyReading(journeyState(0.19).dailyProgress).pages, 12);
  assert.equal(
    readerPresetAt(journeyState(0.19).readerProgress).id,
    "sea-glass",
  );
});

test("journey safely normalizes invalid input and finite overscroll", () => {
  for (const input of invalidInputs)
    assert.deepEqual(journeyState(input), journeyState(0));
  assert.deepEqual(journeyState(-Number.MAX_VALUE), journeyState(0));
  assert.deepEqual(journeyState(Number.MAX_VALUE), journeyState(1));
});

test("daily reading uses whole pages and reaches its goal only at the end", () => {
  assert.deepEqual(dailyReading(0), {
    pages: 0,
    goal: 24,
    fraction: 0,
    phase: "beginning",
  });
  assert.deepEqual(dailyReading(0.5), {
    pages: 12,
    goal: 24,
    fraction: 0.5,
    phase: "building",
  });
  assert.deepEqual(dailyReading(1), {
    pages: 24,
    goal: 24,
    fraction: 1,
    phase: "complete",
  });
  assert.equal(dailyReading(1 / 24 - Number.EPSILON).pages, 0);
  assert.equal(dailyReading(1 / 24).pages, 1);
  assert.equal(dailyReading(23.9 / 24).pages, 23);
  assert.equal(dailyReading(1 - Number.EPSILON).phase, "building");
  assert.equal(dailyReading(1 + Number.EPSILON).phase, "complete");
  assert.deepEqual(dailyReading(50), dailyReading(1));
  assert.deepEqual(dailyReading(-50), dailyReading(0));
  for (const input of invalidInputs)
    assert.deepEqual(dailyReading(input), dailyReading(0));
});

test("daily reading is bounded and reversible across every page threshold", () => {
  const progress = Array.from({ length: 241 }, (_, index) => index / 240);
  const states = progress.map(dailyReading);
  for (let index = 0; index < states.length; index += 1) {
    const state = states[index];
    assert.ok(Number.isInteger(state.pages));
    assert.ok(state.pages >= 0 && state.pages <= 24);
    assert.equal(state.fraction, state.pages / state.goal);
    assert.equal(
      state.phase,
      state.pages === 0
        ? "beginning"
        : state.pages === 24
          ? "complete"
          : "building",
    );
    if (index > 0) assert.ok(state.pages >= states[index - 1].pages);
  }
  assert.deepEqual(
    [...progress].reverse().map(dailyReading),
    [...states].reverse(),
  );
  assert.equal(dailyReading(1).phase, "complete");
  assert.equal(dailyReading(0.5).phase, "building");
  assert.equal(dailyReading(0).phase, "beginning");
});

test("illustrative reader presets have complete immutable display data", () => {
  assert.deepEqual(
    readerPresets.map(({ id }) => id),
    ["sea-glass", "paper", "dusk", "midnight"],
  );
  assert.ok(Object.isFrozen(readerPresets));
  for (const preset of readerPresets) {
    assert.ok(Object.isFrozen(preset));
    for (const field of ["label", "description", "fontLabel", "spacingLabel"]) {
      assert.equal(typeof preset[field], "string");
      assert.ok(preset[field].trim().length > 0);
    }
    assert.match(preset.themeColor, /^#[0-9a-f]{6}$/i);
    assert.ok(["literary", "classic", "modern"].includes(preset.fontFamily));
    assert.ok(
      Number.isFinite(preset.lineHeight) &&
        preset.lineHeight >= 1.4 &&
        preset.lineHeight <= 2,
    );
  }
});

test("presets switch exactly on each quarter boundary and reverse without state", () => {
  const progress = [
    -1,
    0,
    0.25 - Number.EPSILON,
    0.25,
    0.5 - Number.EPSILON,
    0.5,
    0.75 - Number.EPSILON,
    0.75,
    1 - Number.EPSILON,
    1,
    2,
  ];
  const indices = [0, 0, 0, 1, 1, 2, 2, 3, 3, 3, 3];
  const expected = indices.map((index) => readerPresets[index]);
  assert.deepEqual(progress.map(readerPresetAt), expected);
  assert.deepEqual(
    [...progress].reverse().map(readerPresetAt),
    [...expected].reverse(),
  );
  for (const input of invalidInputs)
    assert.equal(readerPresetAt(input), readerPresets[0]);
});
