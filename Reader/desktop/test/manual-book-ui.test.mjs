import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { _electron } from "playwright";
const require = createRequire(import.meta.url),
  { JournalStore } = require("../src/journal/store.cjs");
const project = path.resolve(import.meta.dirname, "..");
test("manual-only books retain distinct identity, drafts and full journal actions across restart", async (t) => {
  const temp = await fs.mkdtemp(
    path.join(os.tmpdir(), "stillleaf-manual-book-"),
  );
  let app;
  t.after(async () => {
    await app?.close();
    await fs.rm(temp, { recursive: true, force: true });
  });
  const data = path.join(temp, "data");
  async function launch() {
    app = await _electron.launch({
      executablePath: require("electron"),
      args: [project],
      env: { ...process.env, STILLLEAF_TEST_DATA: data },
    });
    const page = await app.firstWindow();
    await page.getByRole("button", { name: "Add book", exact: true }).waitFor();
    return page;
  }
  let page = await launch();
  await page.getByRole("button", { name: "Add book", exact: true }).click();
  await page.locator("#editor-save").click();
  assert.equal(await page.locator("#editor").isVisible(), true);
  assert.equal(
    (await page.evaluate(() => window.stillleafLibrary.snapshot())).books
      .length,
    0,
  );
  await page
    .getByLabel("Title", { exact: true })
    .fill("The Book I Read Elsewhere");
  await page
    .getByLabel("Author (optional)", { exact: true })
    .fill("Mira Wells");
  await page.screenshot({
    path: path.join(project, "test-output/journal/curated-add-book-light.png"),
    fullPage: true,
  });
  await page.locator("#editor-cancel").click();
  await page.locator("#draft-keep").click();
  assert.equal(
    await page.getByLabel("Title", { exact: true }).inputValue(),
    "The Book I Read Elsewhere",
  );
  const sabotage = new JournalStore(path.join(data, "journal.sqlite"));
  sabotage.db.exec(
    "CREATE TRIGGER fixture_manual_failure BEFORE INSERT ON books BEGIN SELECT RAISE(ABORT,'Fixture book save failure'); END",
  );
  await page.locator("#editor-save").click();
  await page.waitForFunction(() =>
    document
      .getElementById("editor-error")
      .textContent.includes("Fixture book save failure"),
  );
  assert.equal(
    await page.getByLabel("Author (optional)", { exact: true }).inputValue(),
    "Mira Wells",
  );
  assert.equal(
    (await page.evaluate(() => window.stillleafLibrary.snapshot())).books
      .length,
    0,
  );
  sabotage.db.exec("DROP TRIGGER fixture_manual_failure");
  sabotage.close();
  await page.locator("#editor-cancel").click();
  await page.locator("#draft-save").click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  let snapshot = await page.evaluate(() => window.stillleafLibrary.snapshot());
  const id = snapshot.books[0].bookId;
  assert.equal(snapshot.books[0].source, "manual");
  assert.deepEqual(snapshot.books[0].editionIds, []);
  assert.equal(snapshot.books[0].completion, null);
  assert.equal(snapshot.books[0].available, false);
  assert.equal(snapshot.books[0].rating, null);
  assert.equal(snapshot.books[0].review, null);
  assert.equal(snapshot.entries.length, 0);
  assert.equal(snapshot.automaticEntries.length, 0);
  assert.equal((await app.windows()).length, 1);
  assert.equal(
    await page
      .getByRole("button", { name: "Import to read", exact: true })
      .count(),
    1,
  );
  assert.equal(await page.locator(".remove").count(), 0);
  assert.equal(await page.locator(".cover.placeholder").count(), 1);
  await page.getByRole("button", { name: "Add book", exact: true }).click();
  await page.getByLabel("Title", { exact: true }).fill("Discard this draft");
  await page.locator("#editor-cancel").click();
  await page.locator("#draft-discard").click();
  assert.equal(
    (await page.evaluate(() => window.stillleafLibrary.snapshot())).books
      .length,
    1,
  );
  await page.getByRole("button", { name: "Add book", exact: true }).click();
  await page
    .getByLabel("Title", { exact: true })
    .fill("The Book I Read Elsewhere");
  await page.locator("#editor-save").click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  snapshot = await page.evaluate(() => window.stillleafLibrary.snapshot());
  assert.equal(snapshot.books.length, 2);
  assert.notEqual(snapshot.books[0].bookId, snapshot.books[1].bookId);
  assert.equal(snapshot.books.filter((b) => b.creators.length === 0).length, 1);
  const rejected = await page.evaluate(() =>
    window.stillleafLibrary.journal("createBook", {
      title: "Forged",
      author: "",
      recordedAt: "2000-01-01T00:00:00Z",
    }),
  );
  assert.match(rejected.error, /field/);
  const card = page.locator(`[data-book="${id}"]`);
  await card
    .getByRole("button", { name: "Rate & review", exact: true })
    .click();
  const slider = page.getByRole("slider", { name: "Book rating" });
  await slider.press("End");
  await slider.press("ArrowLeft");
  await page
    .getByLabel("Personal review", { exact: true })
    .fill("I read this on paper. The final chapter stayed with me.");
  await page.locator("#editor-save").click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  await card.locator("summary").click();
  await card.getByRole("button", { name: "Log reading", exact: true }).click();
  await page.getByLabel("Minutes read", { exact: true }).fill("17.5");
  await page.locator("#editor-save").click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  await card.locator("summary").click();
  const before = Date.now();
  await card
    .getByRole("button", { name: "Mark finished", exact: true })
    .click();
  await page.waitForFunction(
    async (id) =>
      (await window.stillleafLibrary.snapshot()).books.find(
        (b) => b.bookId === id,
      ).completion,
    id,
  );
  snapshot = await page.evaluate(() => window.stillleafLibrary.snapshot());
  assert.ok(
    Date.parse(
      snapshot.books.find((b) => b.bookId === id).completion.payload.finishedAt,
    ) >= before,
  );
  assert.equal(snapshot.entries.length, 1);
  assert.equal(snapshot.entries[0].minutes, 17.5);
  assert.equal(snapshot.entries[0].pages, null);
  assert.equal(snapshot.automaticEntries.length, 0);
  await page.screenshot({
    path: path.join(
      project,
      "test-output/journal/curated-manual-only-library.png",
    ),
    fullPage: true,
  });
  await app.close();
  app = null;
  page = await launch();
  await page.locator(".book").first().waitFor();
  snapshot = await page.evaluate(() => window.stillleafLibrary.snapshot());
  assert.equal(snapshot.books.length, 2);
  const restored = snapshot.books.find((b) => b.bookId === id);
  assert.equal(restored.rating, 4.75);
  assert.match(restored.review, /on paper/);
  assert.ok(restored.completion);
  assert.equal(snapshot.entries[0].minutes, 17.5);
  assert.equal(restored.available, false);
  assert.equal(await page.locator(".remove").count(), 0);
  await assert.rejects(
    fs.stat(path.join(data, "library", "editions")),
    (error) => error.code === "ENOENT",
  );
  assert.equal(
    await app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows().every((w) => !w.isVisible()),
    ),
    true,
  );
});
