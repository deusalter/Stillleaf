import { clampProgress } from "./showcase-model.js";

/**
 * The journal and release area share one scroll coordinate. Decorative books
 * descend through the margins; reading, controls, and release states stay put.
 * The existing scroll controller owns scheduling and the global motion gate.
 */
export function createClosingShowcase() {
  const scenes = [...document.querySelectorAll("[data-closing-scene]")].map(
    (element) => ({
      element,
      render(progress, geometry) {
        const travel = clampProgress(geometry?.travel ?? progress);
        const entry = clampProgress(geometry?.entry ?? 1);
        const previous = element.dataset.closingTravel;
        const current = travel.toFixed(4);
        if (
          previous === current &&
          element.dataset.closingEntry === entry.toFixed(4)
        )
          return;
        element.dataset.closingTravel = current;
        element.dataset.closingEntry = entry.toFixed(4);
        element.style.setProperty("--closing-travel", current);
        element.style.setProperty("--closing-entry", entry.toFixed(4));
        element.style.setProperty(
          "--book-descent",
          `${(-220 + travel * 620).toFixed(2)}px`,
        );
        element.style.setProperty(
          "--book-turn",
          `${(-26 + travel * 54).toFixed(2)}deg`,
        );
        element.style.setProperty(
          "--book-depth",
          `${(-70 + travel * 170).toFixed(2)}px`,
        );
        element.style.setProperty(
          "--book-outward",
          `${(Math.sin(travel * Math.PI) * 54).toFixed(2)}px`,
        );
      },
    }),
  );
  return { scenes };
}
