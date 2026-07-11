/**
 * Pure state for the website's illustrative scroll story.
 * These presets are original presentation examples, not a catalog of shipped
 * app themes. No reading activity or app preferences are recorded here.
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
    readerCopy: clampProgress((p - 0.49) / 0.075),
    activeScene: p < 0.5 ? "daily" : "reader",
  };
}

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
 * @property {'literary'|'classic'|'modern'} fontFamily
 * @property {number} lineHeight
 */

/** @type {readonly Readonly<ReaderPreset>[]} */
export const readerPresets = Object.freeze([
  Object.freeze({
    id: "sea-glass",
    label: "Sea glass",
    description: "Soft green light, with room for each line to breathe.",
    fontLabel: "Literary serif",
    spacingLabel: "Open spacing",
    themeColor: "#dce9e0",
    fontFamily: "literary",
    lineHeight: 1.8,
  }),
  Object.freeze({
    id: "paper",
    label: "Paper",
    description: "Warm paper and a familiar serif for a quiet afternoon.",
    fontLabel: "Classic serif",
    spacingLabel: "Balanced spacing",
    themeColor: "#f2e9d8",
    fontFamily: "classic",
    lineHeight: 1.65,
  }),
  Object.freeze({
    id: "dusk",
    label: "Dusk",
    description: "Muted plum and clean letterforms as the room grows dim.",
    fontLabel: "Modern sans",
    spacingLabel: "Easy spacing",
    themeColor: "#49414d",
    fontFamily: "modern",
    lineHeight: 1.75,
  }),
  Object.freeze({
    id: "midnight",
    label: "Midnight",
    description: "Deep green, pale type, and one more chapter before sleep.",
    fontLabel: "Literary serif",
    spacingLabel: "Generous spacing",
    themeColor: "#142923",
    fontFamily: "literary",
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
