// Captures screenshots of the dynamic-motion mockups, headless.
// Run from Reader/desktop/reader so Playwright resolves from its node_modules:
//   cd Reader/desktop/reader && node ../../../design/dynamic-motion/capture.mjs [only]
// `only` limits the run to shot names containing that text.
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import fs from "node:fs";

const require = createRequire(path.join(process.cwd(), "package.json"));
const { chromium } = require("playwright");
const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, "shots");
fs.mkdirSync(out, { recursive: true });
const page0 = pathToFileURL(path.join(here, "index.html")).href;
const only = process.argv[2] || "";
const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const browser = await chromium.launch({ headless: true, executablePath: fs.existsSync(chrome) ? chrome : undefined });
const ctx = await browser.newContext({ viewport: { width: 1384, height: 2000 }, deviceScaleFactor: 2 });
const page = await ctx.newPage();
const errors = [];
page.on("pageerror", e => errors.push(String(e)));
page.on("console", m => { if (m.type() === "error") errors.push(m.text()); });

const wait = ms => page.waitForTimeout(ms);
async function open(q) {
  await page.goto(`${page0}?${new URLSearchParams(q)}`);
  await page.waitForFunction(() => window.mock);
  await wait(900);
}
async function shotStage(name) {
  // Directions, controls and all three windows in one frame.
  const scroll = await page.evaluate(() => scrollY);
  const top = await page.locator(".dirs").boundingBox();
  const bottom = await page.locator(".row2").boundingBox();
  top.y += scroll; bottom.y += scroll;
  await page.screenshot({ path: path.join(out, name + ".png"), fullPage: true, clip: { x: 0, y: top.y - 16, width: 1384, height: bottom.y + bottom.height - top.y + 32 } });
}
async function shotEl(sel, name) { await page.locator(sel).screenshot({ path: path.join(out, name + ".png") }); }
const want = n => !only || n.includes(only);

const plans = [
  // name, query, frames: [delay ms before each frame]
  { name: "living", q: { dir: "living", theme: "dark" }, frames: [1500, 2200, 2200] },
  { name: "reactive", q: { dir: "reactive", theme: "dark" }, frames: [1800, 4500, 4500, 4500] },
  { name: "weather", q: { dir: "weather", theme: "dark" }, frames: [4600, 9000, 6000, 26000] },
  { name: "quiet", q: { dir: "quiet", theme: "dark" }, frames: [500, 1800, 2500, 2500] },
];

for (const p of plans) {
  if (!want(p.name)) continue;
  await open(p.q);
  let i = 0;
  for (const d of p.frames) {
    await wait(d);
    if (p.name === "quiet") {
      // Send a ripple through each garden so a still frame catches one mid-spread.
      await page.evaluate(() => { mock.ripple("dash", 980, 470); mock.ripple("panel", 160, 560); mock.ripple("reader", 120, 420); });
      await wait(320);
    }
    i++;
    await shotStage(`${p.name}-frame${i}`);
    if (p.name === "quiet") { await page.evaluate(() => mock.ripple("dash", 980, 470)); await wait(320); }
    await shotEl("#dash", `${p.name}-dash-${i}`);
  }
  if (p.name === "quiet") {
    // Element screenshots take longer than a ripple lives, so read the garden canvas
    // itself 380 ms after a click in the open garden.
    const url = await page.evaluate(async () => {
      mock.wins[0].ripples = [];
      mock.ripple("dash", 980, 470);
      await new Promise(r => setTimeout(r, 380));
      const c = document.querySelector("#dash-garden"), d = c.width / c.clientWidth, o = document.createElement("canvas");
      o.width = 520 * d; o.height = 300 * d;
      const x = o.getContext("2d"); x.fillStyle = getComputedStyle(document.body).getPropertyValue("--canvas"); x.fillRect(0, 0, o.width, o.height);
      x.drawImage(c, 720 * d, 320 * d, 520 * d, 300 * d, 0, 0, o.width, o.height);
      return o.toDataURL("image/png");
    });
    fs.writeFileSync(path.join(out, "quiet-ripple.png"), Buffer.from(url.split(",")[1], "base64"));
  }
  await shotEl("#desk", `${p.name}-panel`);
  await shotEl("#reader", `${p.name}-reader`);
  await shotEl(`.spec[data-spec="${p.name}"]`, `${p.name}-spec`);
}

if (want("light")) {
  for (const dir of ["living", "reactive", "weather", "quiet"]) {
    await open({ dir, theme: "light" });
    await wait(dir === "weather" ? 15000 : 3000);
    await shotStage(`light-${dir}`);
  }
}
if (want("tod")) {
  for (const tod of ["dawn", "day", "dusk", "night"]) {
    await open({ dir: "reactive", theme: "dark", tod });
    await wait(1500);
    await shotEl("#dash", `tod-${tod}`);
  }
}
if (want("tiers")) {
  for (const tier of ["calm", "still", "hidden"]) {
    await open({ dir: "living", theme: "dark", tier });
    await wait(2500);
    await shotStage(`tier-${tier}`);
  }
}
if (want("page")) {
  await open({ dir: "living", theme: "dark" });
  await wait(2000);
  await page.screenshot({ path: path.join(out, "page-full.png"), fullPage: true });
}
const meter = await page.locator("#meter").textContent().catch(() => "");
console.log("meter:", meter);
console.log(errors.length ? "ERRORS:\n" + errors.join("\n") : "no page errors");
await Promise.race([browser.close(), new Promise(r => setTimeout(r, 5000))]);
process.exit(errors.length ? 1 : 0);
