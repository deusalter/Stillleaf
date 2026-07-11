import "@fontsource/instrument-serif/latin-400.css";
import "@fontsource/dm-sans/latin-400.css";
import "@fontsource/dm-sans/latin-500.css";
import "@fontsource/dm-sans/latin-700.css";
import "./style.css";
import "./showcase.css";
import "./closing-showcase.css";
import { releases, getDownload } from "./releases.js";
import { createScrollMotion } from "./scroll-motion.js";
import { createProductShowcase } from "./showcase.js";
import { createClosingShowcase } from "./closing-showcase.js";

const previewData = {
  today: {
    file: "today.webp",
    alt: "Native Stillleaf Mac journal showing daily pages and yearly books goals with sample data.",
    description:
      "A daily goal, at your pace. Choose pages or minutes, and see your reading take shape.",
  },
  library: {
    file: "library.webp",
    alt: "Native Stillleaf Mac Library with a bookshelf of sample books and reading statistics.",
    description:
      "The books you’re spending time with, gathered in your own Library.",
  },
  reviews: {
    file: "reviews.webp",
    alt: "Native Stillleaf Mac personal review editor with a sample written book review.",
    description:
      "Leave a few words for your future self. Personal reviews live alongside your reading.",
  },
};

document.querySelector(".preview-controls").hidden = false;

const previewImage = document.querySelector("#app-screenshot");
const previewDescription = document.querySelector("#preview-description");
const previewButtons = [...document.querySelectorAll("[data-preview]")];
previewButtons.forEach((button) => {
  button.addEventListener("click", () => {
    const preview = previewData[button.dataset.preview];
    previewButtons.forEach((candidate) => {
      const selected = candidate === button;
      candidate.classList.toggle("is-active", selected);
      candidate.setAttribute("aria-pressed", String(selected));
    });
    previewImage.src = `${import.meta.env.BASE_URL}screenshots/${preview.file}`;
    previewImage.alt = preview.alt;
    previewDescription.textContent = preview.description;
  });
});

const platformIcons = {
  macos:
    '<rect x="3" y="4" width="26" height="18" rx="2"/><path d="M12 27h8m-4-5v5"/>',
  windows:
    '<path d="M3 5 15 3v12H3V5Zm15-2 12-2v14H18V3ZM3 18h12v12L3 28V18Zm15 0h12v14l-12-2V18Z"/>',
};

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text) node.textContent = text;
  return node;
}

const releaseGrid = document.querySelector("#release-grid");
releaseGrid.replaceChildren(
  ...releases.map((release) => {
    const card = element("article", "release-card");
    const download = getDownload(release);
    const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    icon.setAttribute("class", "platform-icon");
    icon.setAttribute("viewBox", "0 0 34 34");
    icon.setAttribute("aria-hidden", "true");
    icon.setAttribute("fill", "none");
    icon.setAttribute("stroke", "currentColor");
    icon.setAttribute("stroke-width", "1.5");
    icon.innerHTML = platformIcons[release.id];
    card.append(
      icon,
      element(
        "span",
        "platform-stage",
        download ? "Available" : "In development",
      ),
    );
    card.append(
      element("h3", "", `Stillleaf for ${release.name}`),
      element("p", "", release.summary),
    );
    const requirements = element("ul");
    release.requirements.forEach((requirement) =>
      requirements.append(element("li", "", requirement)),
    );
    card.append(requirements);
    if (download) {
      const link = element("a", "button button-primary", download.label);
      link.href = download.url;
      card.append(link);
    } else {
      card.append(element("p", "release-state", "Download not yet available"));
    }
    return card;
  }),
);

// Motion is optional decoration. System/accessibility and resource constraints
// take precedence over a previously saved preference to animate.
const hero = document.querySelector(".hero");
const motionButtons = [
  ...document.querySelectorAll("#motion-toggle,[data-motion-toggle]"),
];
const books = [...document.querySelectorAll(".book-position")];
const productShowcase = createProductShowcase();
const closingShowcase = createClosingShowcase();
const scrollMotion = createScrollMotion({
  hero,
  scenes: [...productShowcase.scenes, ...closingShowcase.scenes],
});
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
const compactViewport = matchMedia("(max-width: 900px)");
const shortViewport = matchMedia("(max-height: 700px)");
const finePointer = matchMedia("(pointer: fine)");
const connection = navigator.connection;
const constrainedDevice =
  (navigator.hardwareConcurrency && navigator.hardwareConcurrency <= 4) ||
  (navigator.deviceMemory && navigator.deviceMemory <= 4);
let userPaused = false;
let sceneVisible = true;
let pointerFrame = 0;
try {
  userPaused = localStorage.getItem("stillleaf-motion-paused") === "true";
} catch {
  /* Storage is optional. */
}

function motionAllowed() {
  return (
    !reducedMotion.matches &&
    !compactViewport.matches &&
    !shortViewport.matches &&
    !connection?.saveData &&
    !constrainedDevice
  );
}
function ambientAllowed() {
  return (
    !reducedMotion.matches &&
    (!compactViewport.matches || finePointer.matches) &&
    !connection?.saveData &&
    !(navigator.hardwareConcurrency && navigator.hardwareConcurrency <= 2)
  );
}
function isAnimating() {
  return ambientAllowed() && !userPaused && !document.hidden && sceneVisible;
}
function motionEnabled() {
  return motionAllowed() && !userPaused && !document.hidden;
}
function resetParallax() {
  if (pointerFrame) cancelAnimationFrame(pointerFrame);
  pointerFrame = 0;
  books.forEach((book) => {
    book.style.removeProperty("--px");
    book.style.removeProperty("--py");
  });
}
function syncMotion() {
  const allowed = motionAllowed();
  document.body.classList.toggle("motion-paused", !isAnimating());
  for (const motionButton of motionButtons) {
    motionButton.hidden = !(allowed || ambientAllowed());
    motionButton.setAttribute("aria-pressed", String(userPaused));
    motionButton.querySelector("span").textContent = userPaused
      ? "Resume animation"
      : "Pause animation";
    motionButton.title = userPaused ? "Resume animation" : "Pause animation";
    motionButton
      .querySelector("svg path")
      .setAttribute("d", userPaused ? "M5 3.5 12 8 5 12.5Z" : "M5 4v8M11 4v8");
  }
  if (!isAnimating()) resetParallax();
  productShowcase.setMotion({
    enabled: motionEnabled(),
    eligible: allowed,
    layoutActive: allowed && !userPaused,
  });
  scrollMotion.setEnabled(motionEnabled());
}
motionButtons.forEach((motionButton) =>
  motionButton.addEventListener("click", () => {
    userPaused = !userPaused;
    try {
      localStorage.setItem("stillleaf-motion-paused", String(userPaused));
    } catch {
      /* Continue without persistence. */
    }
    syncMotion();
  }),
);
reducedMotion.addEventListener("change", syncMotion);
compactViewport.addEventListener("change", syncMotion);
shortViewport.addEventListener("change", syncMotion);
finePointer.addEventListener("change", () => {
  resetParallax();
  syncMotion();
});
connection?.addEventListener("change", syncMotion);
document.addEventListener("visibilitychange", syncMotion);
const observer = new IntersectionObserver(
  ([entry]) => {
    sceneVisible = entry.isIntersecting;
    syncMotion();
  },
  { threshold: 0 },
);
observer.observe(hero);
hero.addEventListener(
  "pointermove",
  (event) => {
    if (
      !motionEnabled() ||
      !isAnimating() ||
      !finePointer.matches ||
      pointerFrame
    )
      return;
    const { clientX, clientY } = event;
    pointerFrame = requestAnimationFrame(() => {
      pointerFrame = 0;
      if (!isAnimating()) return;
      const rect = hero.getBoundingClientRect();
      const x = (clientX - rect.left) / rect.width - 0.5;
      const y = (clientY - rect.top) / rect.height - 0.5;
      books.forEach((book, index) => {
        const depth = [10, 14, 22, 18, 6][index];
        book.style.setProperty("--px", `${(x * depth).toFixed(2)}px`);
        book.style.setProperty("--py", `${(y * depth).toFixed(2)}px`);
      });
    });
  },
  { passive: true },
);
hero.addEventListener("pointerleave", resetParallax);
syncMotion();
