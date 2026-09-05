import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import { createServer } from "node:http";
import path from "node:path";
import { createRequire } from "node:module";
import { _electron } from "playwright";
import { epub, zip } from "../../packages/publication/test/fixtures.js";
const require = createRequire(import.meta.url);
const project = path.resolve(import.meta.dirname, "..");
test("isolated desktop import, explicit reader, offline resources and persistent receipts", async (t) => {
  const temp = await fs.mkdtemp(
    path.join(os.tmpdir(), "stillleaf-reader-electron-"),
  );
  let app;
  const pageErrors = [];
  t.after(async () => {
    await app?.close();
    await fs.rm(temp, { recursive: true, force: true });
  });
  const source = path.join(temp, "fixture.epub");
  const entries = epub({
    opfTransform: (x) =>
      x.replace(
        "</manifest>",
        '<item id="css" href="book.css" media-type="text/css"/></manifest>',
      ),
    extra: [
      {
        name: "EPUB/book.css",
        data: "body{color:rgb(11,22,33)}p{line-height:1.7;text-indent:13px}",
      },
    ],
  });
  entries.find((x) => x.name === "EPUB/chapter.xhtml").data =
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><link rel="stylesheet" href="book.css"/></head><body><h1>Quiet reading</h1><script>parent.__pwned=true</script><img src="https://example.invalid/track" onerror="parent.__pwned=true"/>' +
    Array.from(
      { length: 70 },
      (_, i) =>
        `<p>Paragraph ${i}. A small green garden waited outside the window while the reader turned the page.</p>`,
    ).join("") +
    "</body></html>";
  entries.find((x) => x.name === "EPUB/cover.png").data = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=",
    "base64",
  );
  await fs.writeFile(source, zip(entries));
  async function launch(extra = []) {
    app = await _electron.launch({
      executablePath: require("electron"),
      args: [project, ...extra],
      env: { ...process.env, STILLLEAF_TEST_DATA: path.join(temp, "data") },
    });
    app.on("window", (w) => {
      w.on("pageerror", (e) => pageErrors.push(e.message));
      w.on("console", (m) => {
        if (m.type() === "error") console.error("CONSOLE", m.text());
      });
    });
    const page = await app.firstWindow();
    await page.waitForFunction(() => Boolean(window.stillleafLibrary));
    return page;
  }
  let page = await launch([source]);
  await page.locator(".book").waitFor();
  assert.equal(await page.locator(".book").count(), 1);
  assert.equal((await app.windows()).length, 1, "Import never opens a reader");
  await page.getByRole("button", { name: "Library archive", exact: true }).click();
  await page.getByRole("dialog", { name: "Library archive", exact: true }).waitFor();
  await page.getByText("No recovery archives saved here yet.", {exact:true}).waitFor();
  await page.getByRole("dialog", { name: "Library archive", exact: true }).getByRole("button", {name:"Close",exact:true}).click();
  const cover = await page.locator(".book img").evaluate(async (img) => {
    await img.decode();
    return { src: img.src, width: img.naturalWidth };
  });
  assert.match(cover.src, /^stillleaf-app:\/\/library\/cover\/[0-9a-f-]{36}\//);
  assert.equal(cover.width, 1, "Cover is served by URL and decodes");
  assert.equal(await page.evaluate(() => typeof require), "undefined");
  await app.evaluate(
    ({ app }, file) => app.emit("open-file", { preventDefault() {} }, file),
    source,
  );
  await page.waitForFunction(() =>
    document.getElementById("summary").textContent.includes("duplicate"),
  );
  assert.equal(await page.locator(".book").count(), 1);
  assert.equal(
    await page.locator("#queue-details").evaluate((x) => x.open),
    false,
  );
  await page.locator("#queue-details > summary").click();
  assert.equal(
    await page.locator("#queue-details").evaluate((x) => x.open),
    true,
  );
  await page
    .getByRole("button", { name: "Dismiss import results", exact: true })
    .click();
  assert.equal(await page.locator("#queue").isHidden(), true);
  const beforeFinish = Date.now();
  await page.locator("#books .book-menu > summary").click();
  await page
    .getByRole("button", { name: "Mark finished", exact: true })
    .click();
  await page.waitForFunction(async () =>
    Boolean((await window.stillleafLibrary.snapshot()).books[0].completion),
  );
  const snapshot = await page.evaluate(() =>
    window.stillleafLibrary.snapshot(),
  );
  const bookId = snapshot.books[0].bookId;
  assert.ok(
    Date.parse(snapshot.books[0].completion.payload.finishedAt) >= beforeFinish,
  );
  assert.equal(snapshot.entries.length, 0);
  const repeated = await page.evaluate(
    (id) => window.stillleafLibrary.journal("finish", { bookId: id }),
    bookId,
  );
  assert.equal(repeated.created, false);
  assert.equal(repeated.celebrationToken, null);
  const spoofed = await page.evaluate(
    (id) =>
      window.stillleafLibrary.journal("finish", {
        bookId: id,
        clickedAt: "2000-01-01T00:00:00Z",
      }),
    bookId,
  );
  assert.match(spoofed.error, /field/);
  await page
    .getByRole("button", { name: "Rate & review", exact: true })
    .click();
  const rating = page.getByRole("slider", { name: "Book rating" });
  assert.equal(await rating.getAttribute("aria-valuetext"), "Not rated");
  await page
    .getByRole("button", { name: "Rate zero stars", exact: true })
    .click();
  assert.equal(await rating.getAttribute("aria-valuetext"), "0 out of 5 stars");
  await page.getByRole("button", { name: "Clear rating", exact: true }).click();
  assert.equal(await rating.getAttribute("aria-valuetext"), "Not rated");
  await rating.focus();
  await rating.press("End");
  for (let i = 0; i < 5; i++) await rating.press("ArrowLeft");
  assert.equal(await rating.getAttribute("aria-valuenow"), "3.75");
  assert.match(await rating.ariaSnapshot(), /slider "Book rating"/);
  await page
    .getByLabel("Personal review", { exact: true })
    .fill("A quiet garden, and time enough to read. 読書");
  await page.locator("#editor-cancel").click();
  await page.locator("#draft-keep").click();
  assert.match(
    await page.getByLabel("Personal review", { exact: true }).inputValue(),
    /quiet garden/,
  );
  await app.evaluate(({ BrowserWindow }) =>
    BrowserWindow.getAllWindows()
      .find((w) => w.webContents.getURL().startsWith("file:"))
      .close(),
  );
  await page.locator("#draft-keep").click();
  assert.equal(
    page.isClosed(),
    false,
    "Native window close keeps dirty journal draft",
  );
  await page.locator("#editor-cancel").click();
  await page.locator("#draft-save").click();
  await page.locator("#editor").waitFor({ state: "hidden" });

  await page.locator("#books .book-menu > summary").click();
  await page.getByRole("button", { name: "Log reading", exact: true }).click();
  await page.getByLabel("Pages read", { exact: true }).fill("0");
  await page.getByLabel("Minutes read", { exact: true }).fill("12.5");
  await page.getByLabel("Page position (optional)", { exact: true }).fill("80");
  await page.locator("#editor-save").click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  await page
    .getByRole("button", { name: "Reading goals", exact: true })
    .click();
  await page.getByLabel("Daily goal", { exact: true }).selectOption("pages");
  await page.getByLabel("Daily pages", { exact: true }).fill("15");
  await page.locator('[name="annualBooks"]').fill("12");
  await page.locator("#editor-save").click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  await page.getByRole("button", { name: "Timeline", exact: true }).click();
  assert.equal(await page.locator(".timeline-row").count(), 1);
  assert.match(
    await page.locator(".timeline-row .rating").textContent(),
    /3.75/,
  );
  assert.equal(await page.locator("#timeline .activity-row").count(), 0);
  assert.doesNotMatch(
    await page.locator("#timeline").textContent(),
    /Reading days|12.5 minutes|page position/,
  );
  await page.locator("#timeline .book-menu > summary").click();
  await page
    .getByRole("button", { name: "Reading records", exact: true })
    .click();
  assert.match(
    await page.locator("#records .activity-row").textContent(),
    /0 pages.*12.5 minutes.*page position 80/,
  );
  await page.locator("#records-close").click();
  await page.screenshot({
    fullPage: true,
    path: path.join(project, "src/journal/test/timeline-macos.png"),
  });
  await page.getByRole("button", { name: "Reviews", exact: true }).click();
  assert.match(await page.locator(".review-row").textContent(), /quiet garden/);
  await page.evaluate(
    (id) =>
      window.stillleafLibrary.journal("review", {
        bookId: id,
        rating: 3.75,
        text: "",
      }),
    bookId,
  );
  await page.waitForFunction(
    () => document.querySelectorAll(".review-row").length === 0,
  );
  assert.equal(
    await page.locator(".review-row").count(),
    0,
    "Rating-only is excluded from Reviews",
  );
  await page.evaluate(
    (id) =>
      window.stillleafLibrary.journal("review", {
        bookId: id,
        rating: 3.75,
        text: "A quiet garden, and time enough to read. 読書",
      }),
    bookId,
  );
  await page.locator(".review-row").waitFor();
  await page.screenshot({
    fullPage: true,
    path: path.join(project, "src/journal/test/reviews-macos.png"),
  });
  await page.getByRole("button", { name: "Edit review", exact: true }).click();
  await page.getByLabel("Personal review", { exact: true }).fill("discard me");
  await page.locator("#editor-cancel").click();
  await page.locator("#draft-discard").click();
  await page.getByRole("button", { name: "Library", exact: true }).click();
  const journal = await page.evaluate(() => window.stillleafLibrary.snapshot());
  assert.equal(journal.daily.pages, 0);
  assert.equal(journal.daily.minutes, 12.5);
  assert.equal(journal.daily.target, 15);
  assert.equal(journal.annual.target, 12);
  assert.equal(journal.books[0].rating, 3.75);
  assert.match(journal.books[0].review, /quiet garden/);
  await page.screenshot({
    fullPage: true,
    path: path.join(project, "src/journal/test/library-macos.png"),
  });
  await page.getByRole("button", { name: "Read", exact: true }).click();
  await page.waitForFunction(
    () => !document.querySelector(".book button").disabled,
  );
  const windows = await app.windows();
  assert.equal(windows.length, 2);
  let reader = windows.find((x) => x !== page);
  await reader.waitForFunction(() =>
    [...document.querySelectorAll("iframe")].some((f) =>
      f.contentDocument?.body.textContent.includes("Quiet reading"),
    ),
  );
  assert.equal(
    await reader.evaluate(() => typeof window.stillleafLibrary),
    "undefined",
  );
  assert.equal(await reader.evaluate(() => typeof require), "undefined");
  assert.equal(await reader.evaluate(() => window.__pwned), undefined);
  const indents = await reader.evaluate(() =>
    [...document.querySelectorAll("iframe")].map((f) => {
      const p = f.contentDocument.querySelector("p");
      return p ? f.contentWindow.getComputedStyle(p).textIndent : null;
    }),
  );
  assert.ok(indents.includes("13px"), `Publisher CSS retained: ${indents}`);
  const bookURL = await app.evaluate(({ BrowserWindow }) =>
    BrowserWindow.getAllWindows()
      .flatMap((window) => [...(window.stillleafFiles?.keys() ?? [])])
      .find((url) => url.startsWith("stillleaf-app://reader/book/")),
  );
  const bookStatus = () =>
    app.evaluate(
      ({ net }, url) =>
        net.fetch(url).then(
          (response) => response.status,
          () => "blocked",
        ),
      bookURL,
    );
  assert.equal(await bookStatus(), 200, "Book files are served by URL");
  await reader.getByRole("button", { name: "Next", exact: true }).click();
  assert.equal(
    await reader.evaluate(() => Boolean(window.StillleafReader.bookmark())),
    true,
  );
  await reader.waitForFunction(
    () => typeof window.StillleafReader.exportState === "function",
  );
  await reader.evaluate(() => {
    window.StillleafReader.addBookmark();
    const locator = window.StillleafReader.bookmark();
    locator.locations.domRange = {
      start: {
        cssSelector: "body > p:nth-of-type(1)",
        textNodeIndex: 0,
        charOffset: 0,
      },
      end: {
        cssSelector: "body > p:nth-of-type(1)",
        textNodeIndex: 0,
        charOffset: 20,
      },
    };
    locator.text = { highlight: "Paragraph 0. A small " };
    window.StillleafReader.annotate({
      locator,
      quote: "Paragraph 0. A small ",
      note: "Fixture private note",
      color: "yellow",
    });
  });
  await reader.waitForFunction(
    () => window.StillleafReader.exportState().annotations.length === 1,
  );
  // A native book switch must honor the renderer's unsaved-note decision.
  await reader.locator("#contents").click();
  await reader.locator("#tab-notes").click();
  await reader.locator(".edit-note").first().click();
  await reader.locator("#note-text").fill("Unsaved draft retained");
  await page.getByRole("button", { name: "Read", exact: true }).click();
  await reader.locator("#keep-draft").click();
  await page.waitForFunction(
    () => !document.querySelector(".book button").disabled,
  );
  assert.equal(
    await reader.locator("#note-text").inputValue(),
    "Unsaved draft retained",
  );
  assert.equal(
    (await app.windows()).length,
    2,
    "Cancelled switch preserves the current reader",
  );
  await reader.locator("#note-panel [data-close]").click();
  await reader.locator("#discard-draft").click();
  // Reopening the same edition must flush the old window BEFORE reading saved state.
  await page.getByRole("button", { name: "Read", exact: true }).click();
  await page.waitForFunction(
    () => !document.querySelector(".book button").disabled,
  );
  reader = (await app.windows()).find((window) => window !== page);
  await reader.waitForFunction(
    () => window.StillleafReader?.exportState?.().annotations.length === 1,
  );
  const editionId = await page.locator(".book").getAttribute("data-edition");
  assert.equal(
    await reader.evaluate(async () => {
      try {
        await fetch("https://example.invalid/network");
        return false;
      } catch {
        return true;
      }
    }),
    true,
  );
  let requests = 0;
  const witness = createServer((_req, res) => {
    requests++;
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.end("local witness");
  });
  await new Promise((resolve) => witness.listen(0, "127.0.0.1", resolve));
  try {
    const base = `http://127.0.0.1:${witness.address().port}`;
    const outcome = await app.evaluate(async ({ BrowserWindow }, base) => {
      async function probe(partition) {
        const win = new BrowserWindow({
          show: false,
          webPreferences: {
            partition,
            sandbox: true,
            nodeIntegration: false,
            contextIsolation: true,
          },
        });
        try {
          await win.loadURL(
            "data:text/html,<html><body>Network policy probe</body></html>",
          );
          return await win.webContents.executeJavaScript(
            `fetch(${JSON.stringify(base)}).then(r=>r.text()).catch(()=>"blocked")`,
          );
        } finally {
          win.destroy();
        }
      }
      return {
        positive: await probe("isolated-positive-control"),
        protected: await probe(undefined),
      };
    }, base);
    assert.equal(outcome.positive, "local witness");
    assert.equal(outcome.protected, "blocked");
    assert.equal(
      requests,
      1,
      "Default-session host policy blocks even without CSP",
    );
  } finally {
    await new Promise((resolve) => witness.close(resolve));
  }
  await reader.close();
  assert.ok(
    ["blocked", 404].includes(await bookStatus()),
    "Book URLs stop resolving once their reader closes",
  );
  const stateFile = path.join(
    temp,
    "data",
    "library",
    "reader-state",
    editionId + ".json",
  );
  const persisted = JSON.parse(await fs.readFile(stateFile, "utf8"));
  assert.equal(persisted.bookmarks.length, 1);
  assert.equal(persisted.annotations[0].note, "Fixture private note");
  assert.equal(
    persisted.annotations[0].locator.locations.domRange.end.charOffset,
    20,
  );
  await app.close();
  app = null;
  page = await launch();
  await page.locator(".book").waitFor();
  assert.equal(await page.locator(".book").count(), 1);
  assert.equal((await app.windows()).length, 1);
  await page.getByRole("button", { name: "Read", exact: true }).click();
  await page.waitForFunction(
    () => !document.querySelector(".book button").disabled,
  );
  const restored = (await app.windows()).find((x) => x !== page);
  await restored.waitForFunction(
    () => window.StillleafReader?.exportState?.().annotations.length === 1,
  );
  assert.equal(
    await restored.evaluate(
      () => window.StillleafReader.exportState().bookmarks.length,
    ),
    1,
  );
  const exportedState = path.join(temp, "exported-reading-state.json");
  await app.evaluate(({ dialog }, file) => {
    dialog.showSaveDialog = async () => ({ canceled: false, filePath: file });
  }, exportedState);
  await page.locator("#books .book-menu > summary").click();
  await page
    .getByRole("button", {
      name: "Export notes and reading settings…",
      exact: true,
    })
    .click();
  await page.waitForFunction(() =>
    document.getElementById("notice").textContent.includes("exported"),
  );
  assert.equal(
    restored.isClosed(),
    true,
    "Export flushes and closes the active edition",
  );
  const exportedBytes = await fs.readFile(exportedState);
  assert.equal(
    JSON.parse(exportedBytes).annotations[0].note,
    "Fixture private note",
  );
  const noOverwrite = await page.evaluate(
    (id) => window.stillleafLibrary.exportReaderState(id),
    editionId,
  );
  assert.match(noOverwrite.error, /EEXIST|exist/);
  assert.deepEqual(await fs.readFile(exportedState), exportedBytes);
  const incoming = JSON.parse(exportedBytes);
  incoming.revision += 10;
  incoming.preferences.lineHeight = 1.7;
  const stateImport = path.join(temp, "incoming-reading-state.json");
  await fs.writeFile(stateImport, JSON.stringify(incoming));
  await app.evaluate(({ dialog }, file) => {
    dialog.showOpenDialog = async () => ({
      canceled: false,
      filePaths: [file],
    });
    dialog.showMessageBox = async (_window, options) => {
      dialog.__statePreview = options;
      return { response: 1 };
    };
  }, stateImport);
  const beforeImport = await fs.readFile(stateFile);
  const cancelState = await page.evaluate(
    (id) => window.stillleafLibrary.importReaderState(id),
    editionId,
  );
  assert.equal(cancelState.cancelled, true);
  assert.deepEqual(await fs.readFile(stateFile), beforeImport);
  const preview = await app.evaluate(({ dialog }) => dialog.__statePreview);
  assert.match(preview.detail, /1 bookmarks and 1 highlights\/notes/);
  assert.match(preview.detail, /not merged/);
  assert.equal(preview.defaultId, 1);
  await app.evaluate(({ dialog }) => {
    dialog.showMessageBox = async () => ({ response: 0 });
  });
  const applied = await page.evaluate(
    (id) => window.stillleafLibrary.importReaderState(id),
    editionId,
  );
  assert.equal(applied.imported, true);
  assert.equal(
    JSON.parse(await fs.readFile(stateFile)).preferences.lineHeight,
    1.7,
  );
  assert.equal(
    (
      await page.evaluate(
        (id) => window.stillleafLibrary.importReaderState(id),
        editionId,
      )
    ).identical,
    true,
  );
  const stale = { ...incoming, revision: 0 };
  await fs.writeFile(stateImport, JSON.stringify(stale));
  const beforeStale = await fs.readFile(stateFile);
  assert.match(
    (
      await page.evaluate(
        (id) => window.stillleafLibrary.importReaderState(id),
        editionId,
      )
    ).error,
    /older/,
  );
  assert.deepEqual(await fs.readFile(stateFile), beforeStale);

  const bad = path.join(temp, "invalid.epub");
  await fs.writeFile(bad, "not an EPUB");
  await app.evaluate(
    ({ app }, file) => app.emit("second-instance", {}, ["stillleaf", file]),
    bad,
  );
  await page.waitForFunction(() =>
    document.getElementById("summary").textContent.includes("failed"),
  );
  assert.equal(await page.locator(".book").count(), 1);
  assert.equal(
    await app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows().every((w) => !w.isVisible()),
    ),
    true,
    "Synthetic windows remain hidden",
  );
  await app.evaluate(({ dialog }) => {
    dialog.showMessageBox = async () => ({ response: 2 });
  });
  await page.locator("#books .book-menu > summary").click();
  await page
    .getByRole("button", { name: "Remove Fixture", exact: true })
    .click();
  await page.waitForFunction(
    () => !document.querySelector(".book .remove").disabled,
  );
  assert.equal(
    await page.locator(".book").count(),
    1,
    "Cancel keeps the Library book",
  );
  const keepAt = path.join(temp, "kept.epub"),
    fixtureTrash = path.join(temp, "fixture-trash");
  await app.evaluate(
    ({ dialog, shell }, paths) => {
      dialog.showMessageBox = async () => ({ response: 0 });
      dialog.showSaveDialog = async () => ({
        canceled: false,
        filePath: paths.keepAt,
      });
      shell.trashItem = async (file) => {
        await process
          .getBuiltinModule("fs")
          .promises.rename(file, paths.fixtureTrash);
      };
    },
    { keepAt, fixtureTrash },
  );
  await page.locator("#books .book-menu > summary").click();
  await page
    .getByRole("button", { name: "Remove Fixture", exact: true })
    .click();
  await page.waitForFunction(
    () =>
      document.querySelectorAll(".book .remove").length === 0 ||
      Boolean(document.getElementById("error").textContent),
  );
  assert.equal(
    await page.locator(".book").count(),
    1,
    await page.locator("#error").textContent(),
  );
  assert.equal(
    await page
      .getByRole("button", { name: "Import to read", exact: true })
      .count(),
    1,
  );
  assert.equal(await page.locator(".book .remove").count(), 0);
  const retained = await page.evaluate(() =>
    window.stillleafLibrary.snapshot(),
  );
  assert.equal(retained.books[0].rating, 3.75);
  assert.equal(retained.entries.length, 1);
  assert.equal(retained.books[0].available, false);
  assert.deepEqual(await fs.readFile(keepAt), await fs.readFile(source));
  assert.equal(
    JSON.parse(await fs.readFile(stateFile, "utf8")).annotations[0].note,
    "Fixture private note",
  );
  assert.equal(
    JSON.parse(
      await fs.readFile(
        path.join(temp, "data", "library", "retained", editionId + ".json"),
        "utf8",
      ),
    ).assetDisposition,
    "removed",
  );
  await page.waitForFunction(
    () => document.getElementById("notice").textContent === "",
  );
  assert.deepEqual(pageErrors, []);
  console.log(
    "PASS: Electron " +
      (await app.evaluate(({ app }) => process.versions.electron)) +
      " on " +
      process.platform +
      "; no Windows execution claimed",
  );
});
