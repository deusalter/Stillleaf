import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { deflateSync } from "node:zlib";
import { createRequire } from "node:module";
import { _electron } from "playwright";
import { epub, zip } from "../../packages/publication/test/fixtures.js";
import { importEPUB } from "../../packages/publication/index.js";
const require = createRequire(import.meta.url),
  { JournalStore } = require("../src/journal/store.cjs");
const project = path.resolve(import.meta.dirname, ".."),
  captures = path.join(project, "src/journal/test");
function crc(bytes) {
  let n = 0xffffffff;
  for (const byte of bytes) {
    n ^= byte;
    for (let j = 0; j < 8; j++) n = (n >>> 1) ^ (n & 1 ? 0xedb88320 : 0);
  }
  return (n ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const label = Buffer.from(type),
    length = Buffer.alloc(4),
    check = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  check.writeUInt32BE(crc(Buffer.concat([label, data])));
  return Buffer.concat([length, label, data, check]);
}
// Original synthetic geometric covers embedded by explicit EPUB cover metadata.
function cover(palette) {
  const width = 120,
    height = 180,
    raw = Buffer.alloc(height * (1 + width * 3));
  for (let y = 0; y < height; y++) {
    const offset = y * (1 + width * 3);
    for (let x = 0; x < width; x++) {
      const band =
        y < 25 || y > 155
          ? 1
          : Math.abs(x - 60) < (y - 35) * 0.33 && y > 35 && y < 140
            ? 2
            : 0;
      const color = palette[band];
      for (let c = 0; c < 3; c++) raw[offset + 1 + x * 3 + c] = color[c];
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  return Buffer.concat([
    Buffer.from("89504e470d0a1a0a", "hex"),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}
test("curated journal hierarchy, quarter-star pointer/keyboard and light/dark/narrow captures", async (t) => {
  const temp = await fs.mkdtemp(
    path.join(os.tmpdir(), "stillleaf-journal-ui-"),
  );
  let app;
  t.after(async () => {
    await app?.close();
    await fs.rm(temp, { recursive: true, force: true });
  });
  const data = path.join(temp, "data"),
    root = path.join(data, "library");
  await fs.mkdir(data, { recursive: true });
  const store = new JournalStore(path.join(data, "journal.sqlite"));
  const specs = [
    [
      "The Orchard at Dusk",
      "Mara Ellis",
      4.25,
      "I kept returning to the quiet moments between the characters. A book about attention, and what it asks of us.",
      "2026-08-18T19:30:00Z",
      [
        [55, 91, 75],
        [212, 219, 177],
        [225, 177, 91],
      ],
    ],
    [
      "Tides of Elsewhere",
      "Elias North",
      3.75,
      null,
      "2026-07-06T20:00:00Z",
      [
        [51, 76, 106],
        [171, 194, 195],
        [215, 218, 186],
      ],
    ],
    [
      "A Field Guide to Ordinary Days",
      "Leah Rivers",
      5,
      "Small observations, held with care. The chapter on walking home stayed with me.",
      "2026-05-22T18:00:00Z",
      [
        [146, 88, 69],
        [220, 181, 134],
        [236, 216, 173],
      ],
    ],
    [
      "The Mapmaker’s Window",
      "Noor Vale",
      null,
      null,
      null,
      [
        [88, 80, 118],
        [187, 174, 178],
        [215, 198, 134],
      ],
    ],
    [
      "Letters from the Coast",
      "Jonah Reed",
      0,
      null,
      null,
      [
        [135, 116, 65],
        [224, 211, 164],
        [78, 112, 112],
      ],
    ],
  ];
  const ids = [];
  for (let i = 0; i < specs.length; i++) {
    const [title, author, rating, review, finish, palette] = specs[i];
    const entries = epub({
      opfTransform: (x) =>
        x.replace("Fixture", title).replace("Tester", author),
    });
    entries.find((e) => e.name === "EPUB/cover.png").data = cover(palette);
    const source = path.join(temp, `book-${i}.epub`);
    await fs.writeFile(source, zip(entries));
    const imported = await importEPUB(source, root, {});
    const linked = store.attachEdition({
      editionId: imported.editionId,
      title,
      creators: [author],
      recordedAt: "2026-09-01T12:00:00Z",
    });
    ids.push(linked.book.book_id);
    if (finish)
      store.recordCompletion({
        bookId: linked.book.book_id,
        finishedAt: finish,
        recordedAt: "2026-09-01T12:00:00Z",
      });
    if (rating !== null)
      store.setRating({
        bookId: linked.book.book_id,
        value: rating,
        recordedAt: "2026-09-01T12:00:00Z",
      });
    if (review)
      store.setReview({
        bookId: linked.book.book_id,
        text: review,
        recordedAt: "2026-09-01T12:00:00Z",
      });
  }
  store.addManualEntry({
    bookId: ids[3],
    day: "2026-08-20",
    timeZone: "America/Los_Angeles",
    minutes: 18,
    recordedAt: "2026-09-01T12:00:00Z",
  });
  store.appendTrackingBatch({
    intervals: [
      {
        id: "fixture-counted",
        sessionId: "fixture-session",
        bookId: ids[3],
        source: "stillleaf-epub",
        mode: "automatic",
        timezoneId: "America/Los_Angeles",
        start: "2026-08-20T20:00:00Z",
        end: "2026-08-20T20:03:00Z",
        duration: 180,
        disposition: "credited",
      },
      {
        id: "fixture-uncertain",
        sessionId: "fixture-session",
        bookId: ids[3],
        source: "stillleaf-epub",
        mode: "automatic",
        timezoneId: "America/Los_Angeles",
        start: "2026-08-20T20:03:00Z",
        end: "2026-08-20T20:04:00Z",
        duration: 60,
        disposition: "uncertain",
      },
    ],
    events: [],
  });
  store.close();
  app = await _electron.launch({
    executablePath: require("electron"),
    args: [project],
    env: { ...process.env, STILLLEAF_TEST_DATA: data },
  });
  const page = await app.firstWindow();
  await page.locator(".book").first().waitFor();
  assert.equal(await page.locator(".book").count(), 5);
  await page.emulateMedia({ colorScheme: "light" });
  await page.screenshot({
    path: path.join(captures, "curated-library-light.png"),
    fullPage: true,
  });
  await page.getByRole("button", { name: "Timeline", exact: true }).click();
  assert.equal(await page.locator(".timeline-row").count(), 3);
  assert.ok(
    await page
      .locator(".finish-date")
      .first()
      .evaluate((x) => parseFloat(getComputedStyle(x).fontSize) >= 28),
  );
  assert.equal(await page.locator("#timeline .cover").count(), 3);
  assert.doesNotMatch(
    await page.locator("#timeline").textContent(),
    /18 minutes|Reading days|page position/,
  );
  await page.screenshot({
    path: path.join(captures, "curated-timeline-light.png"),
    fullPage: true,
  });
  await page.getByRole("button", { name: "Reviews", exact: true }).click();
  assert.equal(await page.locator(".review-row").count(), 2);
  assert.doesNotMatch(
    await page.locator("#reviews").textContent(),
    /Tides of Elsewhere|Letters from the Coast/,
  );
  await page.screenshot({
    path: path.join(captures, "curated-reviews-light.png"),
    fullPage: true,
  });
  await page.emulateMedia({ colorScheme: "dark" });
  await page.getByRole("button", { name: "Timeline", exact: true }).click();
  await page.screenshot({
    path: path.join(captures, "curated-timeline-dark.png"),
    fullPage: true,
  });
  await page.getByRole("button", { name: "Library", exact: true }).click();
  await page.screenshot({
    path: path.join(captures, "curated-library-dark.png"),
    fullPage: true,
  });
  const timeOnly = page.locator(".book").filter({
    has: page.getByRole("heading", {
      name: "The Mapmaker’s Window",
      exact: true,
    }),
  });
  await timeOnly.locator("summary").click();
  await timeOnly
    .getByRole("button", { name: "Reading records", exact: true })
    .click();
  assert.match(await page.locator("#records").textContent(), /18 minutes/);
  assert.equal(await page.locator(".tracked-record-group").count(), 1);
  assert.match(
    await page.locator("#records").textContent(),
    /4 minutes.*Counted toward time goals/,
  );
  assert.doesNotMatch(
    await page.locator("#records").textContent(),
    /Uncertain|Pending|Not counted toward goals/,
  );
  assert.doesNotMatch(
    await page.locator("#records-list").textContent(),
    /0 pages|page position/,
  );
  await page.screenshot({
    path: path.join(captures, "curated-records-dark.png"),
    fullPage: true,
  });
  await page.locator("#records-close").click();
  await page.emulateMedia({ colorScheme: "light" });
  const first = page.locator(".book").filter({
    has: page.getByRole("heading", {
      name: "The Orchard at Dusk",
      exact: true,
    }),
  });
  await first
    .getByRole("button", { name: "Rate & review", exact: true })
    .click();
  const slider = page.getByRole("slider", { name: "Book rating" });
  assert.equal(
    await slider.getAttribute("aria-valuetext"),
    "4.25 out of 5 stars",
  );
  await slider.press("ArrowRight");
  assert.equal(await slider.getAttribute("aria-valuenow"), "4.5");
  await slider.press("ArrowLeft");
  const box = await slider.boundingBox();
  await page.mouse.click(box.x + 46, box.y + 20);
  assert.equal(
    await slider.getAttribute("aria-valuenow"),
    "1",
    "Gap belongs to preceding star",
  );
  await page.mouse.click(box.x + 194, box.y + 20);
  assert.equal(await slider.getAttribute("aria-valuenow"), "4.25");
  await page.screenshot({
    path: path.join(captures, "curated-quarter-editor-light.png"),
    fullPage: true,
  });
  await slider.press("Home");
  assert.equal(await slider.getAttribute("aria-valuetext"), "0 out of 5 stars");
  await page.getByRole("button", { name: "Clear rating", exact: true }).click();
  assert.equal(await slider.getAttribute("aria-valuetext"), "Not rated");
  await page.locator("#editor-cancel").click();
  await page.locator("#draft-keep").click();
  assert.equal(await slider.getAttribute("aria-valuetext"), "Not rated");
  await page.locator("#editor-cancel").click();
  await page.locator("#draft-discard").click();
  await app.evaluate(({ BrowserWindow }) =>
    BrowserWindow.getAllWindows()[0].setSize(760, 820),
  );
  await page.getByRole("button", { name: "Timeline", exact: true }).click();
  await page.screenshot({
    path: path.join(captures, "curated-timeline-narrow.png"),
    fullPage: true,
  });
  assert.equal(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    ),
    true,
  );
  assert.ok(
    await page
      .locator(".finish-date")
      .first()
      .evaluate((x) => parseFloat(getComputedStyle(x).fontSize) >= 24),
  );
  await page.emulateMedia({ colorScheme: "dark" });
  await page.getByRole("button", { name: "Reviews", exact: true }).click();
  await page
    .locator(".review-row")
    .filter({
      has: page.getByRole("heading", {
        name: "The Orchard at Dusk",
        exact: true,
      }),
    })
    .getByRole("button", { name: "Edit review", exact: true })
    .click();
  await page.screenshot({
    path: path.join(captures, "curated-quarter-editor-dark-narrow.png"),
    fullPage: true,
  });
  await page.locator("#editor-cancel").click();
  await page
    .getByRole("button", { name: "Reading goals", exact: true })
    .click();
  await page.screenshot({
    path: path.join(captures, "curated-goals-dark-narrow.png"),
    fullPage: true,
  });
  await page.locator("#editor-cancel").click();
  await page.getByRole("button", { name: "Library", exact: true }).click();
  async function manualCapture(filename) {
    const card = page.locator(".book").filter({
      has: page.getByRole("heading", {
        name: "The Mapmaker’s Window",
        exact: true,
      }),
    });
    await card.locator("summary").click();
    await card
      .getByRole("button", { name: "Log reading", exact: true })
      .click();
    await page.getByLabel("Minutes read", { exact: true }).fill("18");
    await page
      .getByLabel("Note (optional)", { exact: true })
      .fill("A quiet chapter before breakfast.");
    await page.screenshot({
      path: path.join(captures, filename),
      fullPage: true,
    });
    await page.locator("#editor-cancel").click();
    await page.locator("#draft-discard").click();
  }
  await manualCapture("curated-manual-dark-narrow.png");
  await app.evaluate(({ BrowserWindow }) =>
    BrowserWindow.getAllWindows()[0].setSize(1180, 820),
  );
  await page.emulateMedia({ colorScheme: "light" });
  await page
    .getByRole("button", { name: "Reading goals", exact: true })
    .click();
  await page.screenshot({
    path: path.join(captures, "curated-goals-light.png"),
    fullPage: true,
  });
  await page.locator("#editor-cancel").click();
  await manualCapture("curated-manual-light.png");
  await page.evaluate(async () =>
    render({
      ...(await window.stillleafLibrary.snapshot()),
      trackingError: "Fixture disk failure",
    }),
  );
  assert.match(
    await page.locator("#error").textContent(),
    /Reading time could not be saved: Fixture disk failure/,
  );
  await page.evaluate(async () =>
    render(await window.stillleafLibrary.snapshot()),
  );
  assert.equal(await page.locator("#error").textContent(), "");
  assert.equal(
    await app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows().every((w) => !w.isVisible()),
    ),
    true,
    "All fixture windows stay hidden",
  );
});
