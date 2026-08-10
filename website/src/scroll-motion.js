import { storyProgress } from "./showcase-model.js";

/** Native scrolling drives visible art and product samples; text is never hidden. */
export function createScrollMotion({ hero, scenes = [] }) {
  let enabled = false;
  let frame = 0;
  const visible = new Set();
  const pending = new Set();
  const sceneByElement = new Map(scenes.map((scene) => [scene.element, scene]));
  const clamp = (value) => Math.max(0, Math.min(1, value));

  function render() {
    frame = 0;
    if (!enabled) return;
    const targets = new Set([...visible, ...pending]);
    pending.clear();
    // Read geometry together before writing. Exiting scenes settle even after a
    // large scroll jump, so forward/back and direct anchors cannot leave stale state.
    const measurements = [...targets].map((element) => ({
      element,
      rect: element.getBoundingClientRect(),
    }));
    const height = window.innerHeight;
    for (const { element, rect } of measurements) {
      if (element === hero) {
        const progress = clamp(-rect.top / Math.max(1, rect.height));
        hero.style.setProperty("--hero-travel", progress.toFixed(4));
        hero.style.setProperty(
          "--scroll-lift",
          `${(-24 * progress).toFixed(2)}px`,
        );
        hero.style.setProperty(
          "--scroll-depth",
          `${(-48 * progress).toFixed(2)}px`,
        );
      } else {
        sceneByElement
          .get(element)
          ?.render(storyProgress(rect.top, rect.height, height), {
            entry: clamp((height - rect.top) / (height * 0.85)),
            exit: clamp((height - rect.bottom) / height),
            travel: clamp((height - rect.top) / (height + rect.height)),
          });
      }
    }
  }
  function schedule() {
    if (enabled && (visible.size || pending.size) && !frame)
      frame = requestAnimationFrame(render);
  }
  const observer = new IntersectionObserver((entries) => {
    if (!enabled) return;
    for (const entry of entries) {
      if (entry.isIntersecting) visible.add(entry.target);
      else visible.delete(entry.target);
      entry.target.classList.toggle("scene-in-view", entry.isIntersecting);
      pending.add(entry.target);
    }
    schedule();
  });
  return {
    setEnabled(next) {
      if (enabled === next) return;
      enabled = next;
      if (enabled) {
        observer.observe(hero);
        scenes.forEach((scene) => observer.observe(scene.element));
        window.addEventListener("scroll", schedule, { passive: true });
        window.addEventListener("resize", schedule, { passive: true });
      } else {
        observer.disconnect();
        visible.clear();
        pending.clear();
        window.removeEventListener("scroll", schedule);
        window.removeEventListener("resize", schedule);
        cancelAnimationFrame(frame);
        frame = 0;
        hero.style.removeProperty("--scroll-lift");
        hero.style.removeProperty("--scroll-depth");
        hero.style.removeProperty("--hero-travel");
        // Pausing before a scene enters must still leave its content fully visible.
        scenes.forEach(({ element }) => {
          for (const property of [
            "--scene-entry",
            "--scene-exit",
            "--scene-travel",
          ])
            element.style.removeProperty(property);
        });
      }
    },
  };
}
