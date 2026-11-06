import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { pages, siteFooter, siteHeader } from "../src/site-build.js";
import { site } from "../src/site-config.js";

const root = new URL("../", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");
const sources = [...pages.map((page) => page.file), "404.html"];

test("every page has the shared header, footer, and essential head tags", () => {
  for (const file of sources) {
    const html = read(file);
    assert.match(html, /<html lang="en">/, file);
    assert.match(html, /<meta name="viewport"/, file);
    assert.match(html, /<title>[^<]+Stillleaf|<title>Stillleaf/, file);
    assert.ok(html.includes("{{site-header}}") && html.includes("{{site-footer}}"), file);
    assert.match(html, /<main id="main"/, file);
    assert.equal((html.match(/<h1[\s>]/g) ?? []).length, 1, `${file} has one h1`);
    assert.doesNotMatch(html, /name="robots"/, `${file}: robots come from config`);
    if (file !== "404.html") {
      assert.match(html, /<meta\s+name="description"\s+content="[^"]{60,}"/, file);
      assert.match(html, /property="og:title"/, file);
    }
  }
  assert.match(siteHeader, /class="skip-link" href="#main"/);
});

test("internal links point at pages, files, or anchors that exist", () => {
  const ids = Object.fromEntries(
    sources.map((file) => [
      file,
      new Set([...read(file).matchAll(/\sid="([^"]+)"/g)].map((match) => match[1])),
    ]),
  );
  const home = ids["index.html"];
  home.add("reader-transition");
  const links = sources.flatMap((file) =>
    [...(read(file) + siteHeader + siteFooter).matchAll(/href="([^"]+)"/g)].map(
      (match) => [file, match[1]],
    ),
  );
  for (const [file, href] of links) {
    if (/^(https?:|mailto:)/.test(href)) continue;
    const [path, hash] = href.split("#");
    if (!path) {
      assert.ok(ids[file].has(hash) || hash === "main", `${file}: #${hash}`);
      continue;
    }
    if (path === "/") {
      if (hash) assert.ok(home.has(hash), `${file}: /#${hash}`);
      continue;
    }
    const page = pages.find((candidate) => candidate.path === path);
    const asset = existsSync(new URL(`public${path}`, root)) || existsSync(new URL(path.slice(1), root));
    assert.ok(page || asset, `${file}: ${href} has no page or file`);
  }
});

test("the privacy policy and statement name every host the Mac app can contact", () => {
  // Drift guard: a new network destination in the app must be disclosed in both documents.
  const sourcesDir = new URL("../Sources/", root);
  const hosts = new Set();
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const url = new URL(entry.name + (entry.isDirectory() ? "/" : ""), dir);
      if (entry.isDirectory()) {
        if (entry.name !== "DevTools") walk(url);
      } else if (entry.name.endsWith(".swift")) {
        const swift = readFileSync(url, "utf8");
        for (const match of swift.matchAll(/components\.host = "([^"]+)"/g)) hosts.add(match[1]);
        for (const match of swift.matchAll(/URL\(string: "https:\/\/([^/"]+)/g)) hosts.add(match[1]);
      }
    }
  };
  if (!existsSync(sourcesDir)) return; // Website-only checkout.
  walk(sourcesDir);
  const policy = read("privacy/index.html");
  const statement = readFileSync(new URL("../docs/PRIVACY.md", root), "utf8");
  // Links the user opens in their browser are not app network requests.
  const browserLinks = new Set(["discord.com"]);
  assert.ok(hosts.size >= 2, `found hosts: ${[...hosts]}`);
  for (const host of hosts) {
    if (browserLinks.has(host)) continue;
    assert.ok(policy.includes(host), `privacy policy does not mention ${host}`);
    assert.ok(statement.includes(host), `docs/PRIVACY.md does not mention ${host}`);
  }
  // The update host comes from packaging, not source, so the feed itself is checked by name.
  assert.match(policy, /\{\{feed-path\}\}/);
  assert.ok(statement.includes(site.updates.feedPath), "docs/PRIVACY.md names the update feed");
  for (const document of [policy, statement])
    assert.match(document.replace(/\s+/g, " "), /Check automatically\W+\(off by default\)/);
  // Facts both documents must state the same way.
  const facts = [/on by default/, /Accessibility/, /PageMaps/, /Trash/];
  for (const fact of facts) {
    assert.match(policy, fact, `privacy policy: ${fact}`);
    assert.match(statement, fact, `docs/PRIVACY.md: ${fact}`);
  }
});

test("the privacy policy's Apple Books default matches the app", () => {
  const model = fileURLToPath(new URL("../Sources/BooksPresence/AppModel.swift", root));
  if (!existsSync(model)) return; // Website-only checkout.
  assert.match(
    readFileSync(model, "utf8"),
    /forKey: "syncAppleBooksHistoryEnabled"\) as\? Bool \?\? true/,
    "if this default changes, update the privacy policy and docs/PRIVACY.md",
  );
});

test("reader presets use the Mac reader's own page colours", () => {
  const appearance = fileURLToPath(new URL("../Reader/desktop/reader/src/appearance.js", root));
  if (!existsSync(appearance)) return; // Website-only checkout.
  const css = read("src/showcase.css");
  const themes = readFileSync(appearance, "utf8");
  for (const [site, app] of [["stillleaf", "paper"], ["warm", "sepia"], ["dusk", "dusk"], ["night", "night"]]) {
    const theme = themes.match(new RegExp(`\\{id:'${app}'[^}]*\\}`))?.[0];
    assert.ok(theme, `app theme ${app}`);
    const background = theme.match(/background:'(#[0-9A-F]{6})'/i)[1].toLowerCase();
    const text = theme.match(/text:'(#[0-9A-F]{6})'/i)[1].toLowerCase();
    const short = (hex) => (/^#(.)\1(.)\2(.)\3$/.test(hex) ? `#${hex[1]}${hex[3]}${hex[5]}` : hex);
    const block =
      site === "stillleaf"
        ? css.match(/\.reader-window \{[^}]*\}/)[0]
        : css.match(new RegExp(`\\[data-reader-theme="${site}"\\] \\{[^}]*\\}`))[0];
    assert.ok(
      block.toLowerCase().includes(background) || block.toLowerCase().includes(short(background)),
      `${site} background ${background}`,
    );
    assert.ok(block.toLowerCase().includes(text), `${site} text ${text}`);
  }
});
