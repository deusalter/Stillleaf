import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { _electron } from "playwright";
import { epub, zip } from "../../packages/publication/test/fixtures.js";
import { importEPUB } from "../../packages/publication/index.js";
const require = createRequire(import.meta.url),
  { JournalStore } = require("../src/journal/store.cjs");
const project = path.resolve(import.meta.dirname, "..");
test("completion date editor preserves unknown/exact instants and retains failed drafts", async (t) => {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), "stillleaf-date-ui-"));
  let app;
  t.after(async () => {
    await app?.close();
    await fs.rm(temp, { recursive: true, force: true });
  });
  const data = path.join(temp, "data");
  await fs.mkdir(data, { recursive: true });
  const file = path.join(data, "journal.sqlite"),
    journal = new JournalStore(file);
  const original = "2026-03-07T20:42:13.678Z";
  const ids = [];
  for (const title of ["Dated Fixture", "Undated Fixture"]) {
    const entries = epub({ opfTransform: (x) => x.replace("Fixture", title) });
    entries.find((e) => e.name === "EPUB/cover.png").data = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=",
      "base64",
    );
    const source = path.join(temp, title + ".epub");
    await fs.writeFile(source, zip(entries));
    const imported = await importEPUB(source, path.join(data, "library"), {});
    const book = journal.attachEdition({
      editionId: imported.editionId,
      title,
      recordedAt: "2026-09-01T00:00:00Z",
    }).book;
    ids.push(book.book_id);
    journal.recordCompletion({
      bookId: book.book_id,
      finishedAt: title === "Dated Fixture" ? original : null,
      recordedAt: "2026-09-01T00:00:00Z",
      imported: title === "Undated Fixture",
    });
  }
  const originalEvent = journal.completion(ids[0]).id,
    unknownEvent = journal.completion(ids[1]).id;
  journal.close();
  app = await _electron.launch({
    executablePath: require("electron"),
    args: [project],
    env: {
      ...process.env,
      TZ: "America/Los_Angeles",
      STILLLEAF_TEST_DATA: data,
    },
  });
  const page = await app.firstWindow();
  await page.locator(".book").first().waitFor();
  assert.equal(
    (await page.evaluate(() => window.stillleafLibrary.snapshot())).timeZone,
    "America/Los_Angeles",
  );
  async function open(title) {
    const card = page
      .locator("#books .book")
      .filter({ has: page.getByRole("heading", { name: title, exact: true }) });
    await card.locator("summary").click();
    await card
      .getByRole("button", { name: "Edit reading dates…", exact: true })
      .click();
  }
  async function saved() {
    return (
      await page.evaluate(() => window.stillleafLibrary.snapshot())
    ).books.find((b) => b.bookId === ids[0]);
  }
  await open("Dated Fixture");
  assert.equal(
    await page.getByLabel("Started", { exact: true }).inputValue(),
    "",
  );
  assert.equal(
    await page.getByLabel("Finished", { exact: true }).inputValue(),
    "2026-03-07",
  );
  await page.getByLabel("Finished", { exact: true }).fill("2026-03-07");
  await page.getByRole("button", { name: "Save dates", exact: true }).click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  assert.equal((await saved()).completion.id, originalEvent);
  assert.equal((await saved()).completion.payload.finishedAt, original);
  await open("Undated Fixture");
  assert.equal(
    await page.getByLabel("Started", { exact: true }).inputValue(),
    "",
  );
  assert.equal(
    await page.getByLabel("Finished", { exact: true }).inputValue(),
    "",
  );
  await page.getByRole("button", { name: "Save dates", exact: true }).click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  const undated = (
    await page.evaluate(() => window.stillleafLibrary.snapshot())
  ).books.find((b) => b.bookId === ids[1]);
  assert.equal(undated.completion.id, unknownEvent);
  assert.equal(undated.completion.payload.finishedAt, null);
  await open("Dated Fixture");
  await page.getByLabel("Started", { exact: true }).fill("2026-03-10");
  await page.getByLabel("Finished", { exact: true }).fill("2026-03-09");
  await page.getByRole("button", { name: "Save dates", exact: true }).click();
  await page.waitForFunction(() =>
    document.getElementById("editor-error").textContent.includes("start date"),
  );
  assert.equal(await page.locator("#editor").isVisible(), true);
  assert.equal(
    await page.getByLabel("Started", { exact: true }).inputValue(),
    "2026-03-10",
  );
  assert.equal((await saved()).completion.id, originalEvent);
  await page.getByLabel("Started", { exact: true }).fill("2026-03-01");
  const sabotage = new JournalStore(file);
  sabotage.db.exec(
    "CREATE TRIGGER fixture_date_failure BEFORE INSERT ON events WHEN NEW.kind='bookCompleted' BEGIN SELECT RAISE(ABORT,'Fixture disk save failure'); END",
  );
  await page.getByRole("button", { name: "Save dates", exact: true }).click();
  await page.waitForFunction(() =>
    document
      .getElementById("editor-error")
      .textContent.includes("Fixture disk save failure"),
  );
  assert.equal((await saved()).completion.id, originalEvent);
  assert.equal(
    await page.getByLabel("Finished", { exact: true }).inputValue(),
    "2026-03-09",
  );
  await page.screenshot({
    path: path.join(project, "test-output/journal/curated-dates-save-failure.png"),
    fullPage: true,
  });
  await page.locator("#editor-cancel").click();
  await page.locator("#draft-keep").click();
  assert.equal(
    await page.getByLabel("Started", { exact: true }).inputValue(),
    "2026-03-01",
  );
  sabotage.db.exec("DROP TRIGGER fixture_date_failure");
  sabotage.close();
  await page.getByRole("button", { name: "Save dates", exact: true }).click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  assert.equal(
    (await saved()).completion.payload.startedAt,
    "2026-03-01T08:00:00.000Z",
  );
  assert.equal(
    (await saved()).completion.payload.finishedAt,
    "2026-03-09T19:42:13.000Z",
  );
  await open("Dated Fixture");
  await page.screenshot({
    path: path.join(project, "test-output/journal/curated-dates-light.png"),
    fullPage: true,
  });
  await page
    .getByRole("button", { name: "Leave finished date unknown", exact: true })
    .click();
  await page.getByRole("button", { name: "Save dates", exact: true }).click();
  await page.locator("#editor").waitFor({ state: "hidden" });
  assert.equal((await saved()).completion.payload.finishedAt, null);
  assert.equal(
    (await page.evaluate(() => window.stillleafLibrary.snapshot())).annual
      .books,
    0,
  );
  await page.getByRole("button", { name: "Timeline", exact: true }).click();
  assert.equal(
    await page.getByText("Finish date unknown", { exact: true }).count(),
    2,
  );
  assert.equal(
    (await page.evaluate(() => window.stillleafLibrary.snapshot())).entries
      .length,
    0,
  );
  await page.getByRole("button", { name: "Library", exact: true }).click();
  await open("Dated Fixture");
  await page.emulateMedia({ colorScheme: "dark" });
  await app.evaluate(({ BrowserWindow }) =>
    BrowserWindow.getAllWindows()[0].setSize(760, 820),
  );
  await page.screenshot({
    path: path.join(
      project,
      "test-output/journal/curated-dates-unknown-dark-narrow.png",
    ),
    fullPage: true,
  });
  await page.locator("#editor-cancel").click();
  assert.equal(
    await app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows().every((w) => !w.isVisible()),
    ),
    true,
  );
});
