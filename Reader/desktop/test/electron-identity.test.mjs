import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { createRequire } from "node:module";
import { _electron } from "playwright";

const require = createRequire(import.meta.url);
const project = path.resolve(import.meta.dirname, "..");

test("Library Pageleaf renders at its real file URL under the shipped CSP", async (t) => {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), "stillleaf-identity-"));
  let app;
  t.after(async () => {
    await app?.close();
    await fs.rm(temp, { recursive: true, force: true });
  });
  app = await _electron.launch({
    executablePath: require("electron"),
    args: [project],
    env: { ...process.env, STILLLEAF_TEST_DATA: path.join(temp, "data") },
  });
  const page = await app.firstWindow();
  const errors = [];
  const failed = [];
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(message.text());
  });
  page.on("requestfailed", (request) => failed.push(request.url()));
  await page.addInitScript(() => {
    window.identityViolations = [];
    document.addEventListener("securitypolicyviolation", (event) => {
      window.identityViolations.push({ uri: event.blockedURI, directive: event.effectiveDirective });
    });
  });
  // Reload after installing listeners so file-origin and CSP errors cannot be missed.
  await page.reload({ waitUntil: "load" });
  await page.waitForFunction(() => Boolean(window.stillleafLibrary));
  assert.equal(page.url(), pathToFileURL(path.join(project, "src/index.html")).href);
  const result = await page.locator(".pageleaf-brand").evaluate((svg) => {
    const bounds = svg.getBBox();
    return { width: bounds.width, height: bounds.height, path: svg.querySelector("path")?.getAttribute("d"), uses: svg.querySelectorAll("use").length };
  });
  assert.ok(result.width > 0 && result.height > 0, "The real Library mark must have painted geometry");
  assert.equal(result.uses, 0, "The Library must not depend on external SVG use at a file origin");
  const exported = await fs.readFile(path.join(project, "src/pageleaf.svg"), "utf8");
  assert.equal(result.path, exported.match(/<path[^>]+d="([^"]+)"/)[1], "Inline mark matches generated shared geometry");
  const favicon = await page.evaluate(async () => {
    const href = document.querySelector('link[rel="icon"]').href;
    const image = new Image();
    image.src = href;
    await image.decode(); // Exercises the protocol and the document's img-src policy.
    return { href, width: image.naturalWidth, height: image.naturalHeight };
  });
  assert.equal(favicon.href, "stillleaf-app://identity/pageleaf.svg");
  assert.ok(favicon.width > 0 && favicon.height > 0, "Favicon decodes through the permitted resource protocol");
  assert.deepEqual(await page.evaluate(() => window.identityViolations), []);
  assert.deepEqual(errors.filter((message) => /pageleaf|unsafe attempt|content security policy/i.test(message)), []);
  assert.deepEqual(failed.filter((url) => /pageleaf/i.test(url)), []);
  if (process.env.STILLLEAF_IDENTITY_PREVIEW) {
    await page.screenshot({ path: process.env.STILLLEAF_IDENTITY_PREVIEW });
  }
});
