/**
 * Pure state for the website's scroll story. The reader presets mirror real
 * page colours from the Mac reader; the daily goal is sample data. No reading
 * activity or app preferences are recorded here.
 */

/**
 * Return a finite progress value between 0 and 1. Invalid input starts the story.
 * @param {unknown} value
 * @returns {number}
 */
export function clampProgress(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return 0;
  return Math.min(1, Math.max(0, value));
}

/**
 * Measure progress over the section's scrollable distance. Its top reaches the
 * viewport top at 0, and its bottom reaches the viewport bottom at 1.
 * A section that fits inside the viewport has no scroll story to advance.
 * @param {unknown} top Section top relative to the viewport, in pixels.
 * @param {unknown} sectionHeight
 * @param {unknown} viewportHeight
 * @returns {number}
 */
export function storyProgress(top, sectionHeight, viewportHeight) {
  if (
    ![top, sectionHeight, viewportHeight].every(
      (value) => typeof value === "number" && Number.isFinite(value),
    )
  )
    return 0;
  if (viewportHeight <= 0 || sectionHeight <= viewportHeight) return 0;
  const distance = sectionHeight - viewportHeight;
  if (top >= 0) return 0;
  if (-top >= distance) return 1;
  return clampProgress(-top / distance);
}

/**
 * Coordinate the daily goal, shared-stage handoff, and reader on one timeline.
 * This is derived state: reversing scroll restores the same composition.
 * @param {unknown} progress
 * @returns {{progress: number, dailyProgress: number, readerProgress: number, blend: number, night: number, dailyCopy: number, readerCopy: number, activeScene: 'daily'|'reader'}}
 */
export function journeyState(progress) {
  const p = clampProgress(progress);
  return {
    progress: p,
    dailyProgress: clampProgress(p / 0.38),
    readerProgress: clampProgress((p - 0.56) / 0.44),
    blend: clampProgress((p - 0.4) / 0.2),
    night: clampProgress((p - 0.75) / 0.25),
    dailyCopy: clampProgress((0.5 - p) / 0.075),
    // Pale reader copy waits for the dark background, so it never sits on a
    // mid-blend green with too little contrast (WCAG 1.4.3).
    readerCopy: clampProgress((p - 0.585) / 0.075),
    activeScene: p < 0.5 ? "daily" : "reader",
  };
}

/**
 * Where the reader and its copy are fully shown, just before the first
 * page-colour change. The reader link's scroll anchor in showcase.css sits at
 * this fraction of the shared stage's scroll distance.
 */
export const readerSettledProgress = 0.662;

/**
 * Illustrative daily reading, counting complete pages only. Rounding down avoids
 * announcing completion while the scroll story still has distance remaining.
 * @param {unknown} progress
 * @returns {{pages: number, goal: number, fraction: number, phase: 'beginning'|'building'|'complete'}}
 */
export function dailyReading(progress) {
  const goal = 24;
  const pages = Math.floor(clampProgress(progress) * goal);
  return {
    pages,
    goal,
    fraction: pages / goal,
    phase: pages === 0 ? "beginning" : pages === goal ? "complete" : "building",
  };
}

/**
 * @typedef {Object} ReaderPreset
 * @property {string} id
 * @property {string} label
 * @property {string} description
 * @property {string} fontLabel
 * @property {string} spacingLabel
 * @property {string} themeColor
 * @property {'newyork'|'georgia'|'sans'} fontFamily
 * @property {number} lineHeight
 */

/**
 * Four of the Mac reader's page colours, with the same names and colours as
 * `THEMES` in Reader/desktop/reader/src/appearance.js. Typefaces are a subset
 * of its `FONTS`; the website shows them with the visitor's closest system font.
 * @type {readonly Readonly<ReaderPreset>[]}
 */
export const readerPresets = Object.freeze([
  Object.freeze({
    id: "stillleaf",
    label: "Stillleaf",
    description: "Soft green paper and dark ink, Stillleaf’s own page.",
    fontLabel: "New York",
    spacingLabel: "Open spacing",
    themeColor: "#f0f7f3",
    fontFamily: "newyork",
    lineHeight: 1.8,
  }),
  Object.freeze({
    id: "warm",
    label: "Warm",
    description: "Warm paper and a familiar serif for a quiet afternoon.",
    fontLabel: "Georgia",
    spacingLabel: "Balanced spacing",
    themeColor: "#f6f1e3",
    fontFamily: "georgia",
    lineHeight: 1.65,
  }),
  Object.freeze({
    id: "dusk",
    label: "Dusk",
    description: "Muted plum and clean letterforms as the room grows dim.",
    fontLabel: "San Francisco",
    spacingLabel: "Easy spacing",
    themeColor: "#25212e",
    fontFamily: "sans",
    lineHeight: 1.75,
  }),
  Object.freeze({
    id: "night",
    label: "Night",
    description: "True black with bright text, for dark rooms and OLED screens.",
    fontLabel: "New York",
    spacingLabel: "Generous spacing",
    themeColor: "#000000",
    fontFamily: "newyork",
    lineHeight: 1.9,
  }),
]);

/**
 * Four equal progress bands; progress 1 stays on the final preset.
 * @param {unknown} progress
 * @returns {Readonly<ReaderPreset>}
 */
export function readerPresetAt(progress) {
  const index = Math.min(
    readerPresets.length - 1,
    Math.floor(clampProgress(progress) * readerPresets.length),
  );
  return readerPresets[index];
}
