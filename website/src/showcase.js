import {
  clampProgress,
  dailyReading,
  journeyState,
  readerPresets,
  readerPresetAt,
} from "./showcase-model.js";

/** Interactive samples and scroll scenes share one state; no reading is recorded. */
export function createProductShowcase() {
  const journey = document.querySelector(".reading-journey");
  const daily = document.querySelector(".daily-story");
  const reader = document.querySelector(".customization-story");
  const arc = document.querySelector("#daily-arc");
  const progressbar = document.querySelector(".goal-arc");
  const pageCount = document.querySelector("#daily-pages");
  const goalTitle = document.querySelector("#daily-goal-title");
  const badge = document.querySelector("#daily-badge");
  const dailyRange = document.querySelector("#daily-range");
  const dailyOutput = document.querySelector("#daily-range-value");
  const readerWindow = document.querySelector(".reader-window");
  const passage = document.querySelector(".reader-passage");
  const fontControl = document.querySelector("#reader-font");
  const spacingControl = document.querySelector("#reader-spacing");
  const spacingOutput = document.querySelector("#reader-spacing-value");
  const themeButtons = [...document.querySelectorAll("[data-theme-choice]")];
  const follow = { daily: true, reader: true };
  const manualAt = { daily: 0, reader: 0 };
  let motion = false;
  let readingPages = -1;
  let selectedPreset = readerPresets[0];
  let pageAnimation;
  let windowAnimation;

  // Match DottedReadingArc in ReadingProgress.swift, including partial leading dots.
  const activeDots = [];
  const fragment = document.createDocumentFragment();
  for (const [row, count] of [37, 31].entries()) {
    for (let index = 0; index < count; index++) {
      const position = index / (count - 1);
      const angle = ((140 + position * 260) * Math.PI) / 180;
      const radius = 114.3 - row * 16;
      const attributes = {
        cx: 127 + Math.cos(angle) * radius,
        cy: 132.5 + Math.sin(angle) * radius,
        r: row === 0 ? 4 : 3,
      };
      for (const active of [false, true]) {
        const dot = document.createElementNS(
          "http://www.w3.org/2000/svg",
          "circle",
        );
        for (const [key, value] of Object.entries(attributes))
          dot.setAttribute(key, value.toFixed(3));
        dot.setAttribute(
          "fill",
          active ? (position < 0.58 ? "#087d65" : "#18998a") : "#c7ded3",
        );
        dot.setAttribute("opacity", active ? "0" : row === 0 ? "1" : ".65");
        fragment.append(dot);
        if (active)
          activeDots.push({
            dot,
            count,
            index,
            opacity: row === 0 ? 1 : 0.7,
            previous: "",
          });
      }
    }
  }
  arc.replaceChildren(fragment);

  function renderDaily(progress) {
    const fraction = clampProgress(progress);
    const state = dailyReading(fraction);
    for (const dot of activeDots) {
      const opacity = (
        clampProgress(fraction * dot.count - dot.index) * dot.opacity
      ).toFixed(3);
      if (opacity !== dot.previous) {
        dot.dot.setAttribute("opacity", opacity);
        dot.previous = opacity;
      }
    }
    if (state.pages === readingPages) return;
    readingPages = state.pages;
    pageCount.textContent = state.pages;
    goalTitle.textContent =
      state.phase === "complete"
        ? "Your daily goal, complete."
        : `${state.goal - state.pages} ${state.goal - state.pages === 1 ? "page" : "pages"} to your goal.`;
    badge.textContent =
      state.phase === "complete" ? "✓ Goal complete" : "⌑ Your daily reading";
    progressbar.setAttribute("aria-valuenow", state.pages);
    progressbar.setAttribute(
      "aria-valuetext",
      `${state.pages} of ${state.goal} sample pages`,
    );
    dailyRange.value = state.pages;
    dailyOutput.textContent = `${state.pages} / ${state.goal} pages`;
    daily.dataset.phase = state.phase;
  }

  function updateTypeLabels() {
    const spacing = String(Number(spacingControl.value));
    spacingOutput.value = spacing;
    document.querySelector("#reader-look-detail").textContent =
      `${fontControl.selectedOptions[0].textContent} · ${spacing} spacing`;
  }

  function animatePassage() {
    pageAnimation?.cancel();
    windowAnimation?.cancel();
    if (!motion || typeof passage.animate !== "function") return;
    windowAnimation = readerWindow.animate(
      [
        {
          transform:
            "perspective(1200px) rotateY(-7deg) translateX(18px) scale(.98)",
        },
        { transform: "perspective(1200px) rotateY(0) translateX(0) scale(1)" },
      ],
      { duration: 620, easing: "cubic-bezier(.22,.61,.36,1)" },
    );
    pageAnimation = passage.animate(
      [
        { opacity: 0.86, transform: "translateY(6px)" },
        { opacity: 1, transform: "translateY(0)" },
      ],
      { duration: 380, easing: "cubic-bezier(.22,.61,.36,1)" },
    );
  }

  function renderPreset(preset, animate = true) {
    selectedPreset = preset;
    readerWindow.dataset.readerTheme = preset.id;
    readerWindow.dataset.readerFont = preset.fontFamily;
    readerWindow.style.setProperty("--reader-leading", preset.lineHeight);
    fontControl.value = preset.fontFamily;
    spacingControl.value = preset.lineHeight;
    themeButtons.forEach((button) =>
      button.setAttribute(
        "aria-pressed",
        String(button.dataset.themeChoice === preset.id),
      ),
    );
    document.querySelector("#reader-look-name").textContent = preset.label;
    document.querySelector("#reader-mood-description").textContent =
      preset.description;
    updateTypeLabels();
    if (animate) animatePassage();
  }

  function takeControl(scene) {
    follow[scene] = false;
    manualAt[scene] = window.scrollY;
  }
  function resumedByScroll(scene) {
    if (follow[scene] || Math.abs(window.scrollY - manualAt[scene]) <= 32)
      return false;
    follow[scene] = true;
    return true;
  }

  dailyRange.addEventListener("input", () => {
    takeControl("daily");
    renderDaily(dailyRange.valueAsNumber / 24);
  });
  themeButtons.forEach((button) =>
    button.addEventListener("click", () => {
      takeControl("reader");
      renderPreset(
        readerPresets.find(
          (preset) => preset.id === button.dataset.themeChoice,
        ),
      );
    }),
  );
  fontControl.addEventListener("change", () => {
    takeControl("reader");
    readerWindow.dataset.readerFont = fontControl.value;
    updateTypeLabels();
    document.querySelector("#reader-mood-description").textContent =
      `Your choice of type and spacing, with ${selectedPreset.label} colors.`;
    animatePassage();
  });
  spacingControl.addEventListener("input", () => {
    takeControl("reader");
    readerWindow.style.setProperty(
      "--reader-leading",
      spacingControl.valueAsNumber,
    );
    updateTypeLabels();
    document.querySelector("#reader-mood-description").textContent =
      `Your choice of type and spacing, with ${selectedPreset.label} colors.`;
  });

  function choreograph(element, geometry) {
    if (!geometry) return;
    element.style.setProperty("--scene-entry", geometry.entry.toFixed(4));
    element.style.setProperty("--scene-exit", geometry.exit.toFixed(4));
    element.style.setProperty("--scene-travel", geometry.travel.toFixed(4));
  }
  let journeyProgress = 0;
  function syncActiveScene(progress) {
    daily.inert = progress >= 0.5;
    reader.inert = progress < 0.5;
  }
  const scenes = [
    {
      element: journey,
      render(progress, geometry) {
        const state = journeyState(progress);
        journeyProgress = state.progress;
        choreograph(journey, geometry);
        journey.style.setProperty("--journey-blend", state.blend.toFixed(4));
        journey.style.setProperty("--journey-night", state.night.toFixed(4));
        journey.style.setProperty("--daily-copy", state.dailyCopy.toFixed(4));
        journey.style.setProperty("--reader-copy", state.readerCopy.toFixed(4));
        syncActiveScene(state.progress);
        resumedByScroll("daily");
        if (follow.daily) renderDaily(state.dailyProgress);
        const preset = readerPresetAt(state.readerProgress);
        const resumed = resumedByScroll("reader");
        if (follow.reader && (resumed || preset.id !== selectedPreset.id))
          renderPreset(preset);
      },
    },
  ];

  document
    .querySelectorAll(".daily-preview-input,.reader-options")
    .forEach((control) => {
      control.hidden = false;
    });
  renderDaily(0.5);
  renderPreset(readerPresets[0], false);

  return {
    scenes,
    setMotion({ enabled, eligible, layoutActive }) {
      const wasRunning = document.body.classList.contains("journey-running");
      const rect = journey.getBoundingClientRect();
      const changingLayout = wasRunning !== layoutActive;
      const inside = rect.top < window.innerHeight && rect.bottom > 0;
      if (changingLayout && layoutActive && inside) {
        const readerTop = reader.getBoundingClientRect().top;
        const inReader =
          reader.contains(document.activeElement) ||
          readerTop < window.innerHeight * 0.55;
        journeyProgress = inReader
          ? Math.max(0.62, journeyProgress)
          : Math.min(0.38, journeyProgress);
      }
      const active = journeyProgress < 0.5 ? daily : reader;
      const after = document.querySelector(".journal-proof");
      const afterTop = after.getBoundingClientRect().top;
      motion = enabled;
      document.body.classList.toggle("showcase-enhanced", eligible);
      document.body.classList.toggle("journey-running", layoutActive);
      document.body.classList.toggle("showcase-animating", enabled);
      if (layoutActive) syncActiveScene(journeyProgress);
      else {
        daily.inert = false;
        reader.inert = false;
      }
      document
        .querySelectorAll(
          'a[href="#next-chapter"],a[href="#reader-transition"]',
        )
        .forEach((link) => {
          link.setAttribute(
            "href",
            layoutActive ? "#reader-transition" : "#next-chapter",
          );
        });
      if (!enabled) {
        pageAnimation?.cancel();
        windowAnimation?.cancel();
      }
      // Keep the current reading section in view when pause or viewport size
      // switches between the shared stage and ordinary stacked content.
      if (changingLayout && inside && rect.top < 0) {
        const top = layoutActive
          ? journey.getBoundingClientRect().top +
            journeyProgress * (journey.offsetHeight - window.innerHeight)
          : active.getBoundingClientRect().top;
        window.scrollBy({ top, behavior: "instant" });
      } else if (changingLayout && rect.bottom <= 0) {
        window.scrollBy({
          top: after.getBoundingClientRect().top - afterTop,
          behavior: "instant",
        });
      }
    },
  };
}
