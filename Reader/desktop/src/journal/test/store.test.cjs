"use strict";
const { test } = require("node:test"),
  assert = require("node:assert/strict"),
  fs = require("node:fs"),
  os = require("node:os"),
  path = require("node:path");
const { DatabaseSync } = require("node:sqlite");
const { JournalStore } = require("../store.cjs");
const { importPrototypeFile } = require("../migration.cjs");
const at = "2026-09-24T20:00:00.000Z";
function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "stillleaf-journal-"));
  let store = new JournalStore(path.join(dir, "journal.sqlite"));
  t.after(() => {
    try {
      store.close();
    } catch {}
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return {
    dir,
    get store() {
      return store;
    },
    restart() {
      store.close();
      store = new JournalStore(path.join(dir, "journal.sqlite"));
      return store;
    },
  };
}
function book(store, id = "b") {
  return store.createBook({ id, title: "Same title", recordedAt: at });
}
test("edition identity persists and explicit edition linking counts one journal book", (t) => {
  const f = fixture(t),
    s = f.store;
  const first = s.attachEdition({
    editionId: "a".repeat(64),
    title: "One",
    recordedAt: at,
  });
  assert.equal(first.book.book_id, "epub:" + "a".repeat(64));
  assert.equal(
    s.attachEdition({
      editionId: "a".repeat(64),
      title: "Changed external title",
      recordedAt: at,
    }).created,
    false,
  );
  s.attachEdition({
    editionId: "b".repeat(64),
    bookId: first.book.book_id,
    recordedAt: at,
  });
  assert.throws(() =>
    s.attachEdition({
      editionId: "a".repeat(64),
      bookId: "other",
      recordedAt: at,
    }),
  );
  s.markFinished({ bookId: first.book.book_id, clickedAt: at });
  assert.equal(
    f.restart().annualProgress({ year: 2026, timeZone: "UTC", now: at }).books,
    1,
  );
});
test("dated zero-page minutes and position are independent; no fabricated intervals; restart", (t) => {
  const f = fixture(t),
    s = f.store;
  book(s);
  const entry = {
    id: "e",
    bookId: "b",
    day: "2026-03-08",
    timeZone: "America/Los_Angeles",
    pages: 0,
    minutes: 12.5,
    position: 90,
    recordedAt: at,
  };
  assert.equal(s.addManualEntry(entry).created, true);
  assert.equal(s.addManualEntry(entry).created, false);
  s.addManualEntry({
    ...entry,
    id: "p",
    position: 20,
    pages: null,
    minutes: null,
  });
  const progress = f.restart().dailyProgress("2026-03-08");
  assert.equal(progress.pages, 0);
  assert.equal(progress.minutes, 12.5);
  const saved = f.store.manualEntries()[0];
  assert.equal(saved.day, "2026-03-08");
  assert.equal(saved.startedAt, undefined);
  assert.equal(saved.endedAt, undefined);
  assert.throws(
    () => f.store.addManualEntry({ ...entry, minutes: 20 }),
    /conflicts/,
  );
  assert.throws(() =>
    f.store.addManualEntry({ ...entry, id: "bad", day: "2026-02-30" }),
  );
  assert.throws(() =>
    f.store.addManualEntry({ ...entry, id: "bad", day: "2026-09-25" }),
  );
});
test("completion click is idempotent and creates no page or minute evidence", (t) => {
  const { store: s } = fixture(t);
  book(s);
  const first = s.markFinished({ bookId: "b", clickedAt: at, id: "click" });
  assert.equal(first.celebrationToken, "click");
  const again = s.markFinished({
    bookId: "b",
    clickedAt: "2026-09-25T20:00:00Z",
  });
  assert.equal(again.created, false);
  assert.equal(again.celebrationToken, null);
  assert.equal(again.event.payload.finishedAt, at);
  assert.equal(s.events("bookCompleted").length, 1);
  assert.equal(s.manualEntries().length, 0);
  assert.equal(s.dailyProgress("2026-09-24").minutes, 0);
});
test("manual completion wins later imports; unknown imported finish remains unknown", (t) => {
  const { store: s } = fixture(t);
  book(s);
  s.markFinished({ bookId: "b", clickedAt: at });
  s.recordCompletion({
    bookId: "b",
    finishedAt: "2026-09-25T00:00:00Z",
    recordedAt: "2026-09-26T00:00:00Z",
    imported: true,
  });
  assert.equal(s.completion("b").payload.finishedAt, at);
  book(s, "unknown");
  s.recordCompletion({ bookId: "unknown", recordedAt: at, imported: true });
  assert.equal(
    s.markFinished({ bookId: "unknown", clickedAt: at }).created,
    false,
  );
  assert.equal(
    s.annualProgress({
      year: 2026,
      timeZone: "UTC",
      now: "2026-09-27T00:00:00Z",
    }).books,
    1,
  );
});
test("civil timezone year boundary, future cutoff, edited completion and unique totals", (t) => {
  const { store: s } = fixture(t);
  book(s);
  s.markFinished({ bookId: "b", clickedAt: "2026-01-01T00:30:00Z" });
  assert.equal(
    s.annualProgress({ year: 2025, timeZone: "America/Los_Angeles", now: at })
      .books,
    1,
  );
  assert.equal(
    s.annualProgress({ year: 2026, timeZone: "UTC", now: at }).books,
    1,
  );
  assert.equal(
    s.annualProgress({
      year: 2026,
      timeZone: "UTC",
      now: "2026-01-01T00:00:00Z",
    }).books,
    0,
  );
  s.editCompletionDates({
    bookId: "b",
    finishedAt: "2025-12-30T20:00:00Z",
    recordedAt: at,
  });
  assert.equal(
    s.annualProgress({ year: 2026, timeZone: "UTC", now: at }).books,
    0,
  );
  assert.equal(
    s.annualProgress({ year: 2025, timeZone: "UTC", now: at }).books,
    1,
  );
  assert.equal(s.timeline().length, 1);
  assert.throws(() =>
    s.recordCompletion({
      bookId: "b",
      finishedAt: "2027-01-01T00:00:00Z",
      recordedAt: at,
    }),
  );
  assert.throws(() =>
    s.markFinished({ bookId: "b", clickedAt: "2026-02-31T00:00:00Z" }),
  );
});
test("quarter stars including zero and explicit clears; personal Unicode review", (t) => {
  const f = fixture(t),
    s = f.store;
  book(s);
  for (const value of [0, 0.25, 3.75, 5]) {
    s.setRating({ bookId: "b", value, recordedAt: at });
    assert.equal(s.rating("b"), value);
  }
  assert.throws(() => s.setRating({ bookId: "b", value: 3.1, recordedAt: at }));
  s.setRating({ bookId: "b", value: null, recordedAt: at });
  s.setReview({ bookId: "b", text: "  読書 — thought 👨‍👩‍👦  ", recordedAt: at });
  assert.equal(f.restart().review("b"), "読書 — thought 👨‍👩‍👦");
  assert.equal(f.store.rating("b"), null);
  f.store.setReview({ bookId: "b", text: " \n ", recordedAt: at });
  assert.equal(f.store.review("b"), null);
  assert.throws(() =>
    f.store.setReview({ bookId: "b", text: "x".repeat(50001), recordedAt: at }),
  );
});
test("effective daily goal history and annual clear/ties; combined save atomic", (t) => {
  const { store: s } = fixture(t);
  book(s);
  s.setGoals({
    recordedAt: at,
    daily: {
      effectiveDay: "2026-01-01",
      unit: "pages",
      minutes: 20,
      pages: 10,
    },
    annual: { year: 2026, books: 12, id: "a" },
  });
  s.setGoals({
    recordedAt: at,
    daily: { effectiveDay: "2026-02-01", unit: "minutes", minutes: 30 },
    annual: { year: 2026, books: 15, id: "z" },
  });
  s.setGoals({ recordedAt: at, annual: { year: 2026, books: 4, id: "b" } });
  assert.equal(s.dailyProgress("2025-12-31").target, 20);
  assert.equal(s.dailyProgress("2026-01-01").target, 10);
  assert.equal(s.dailyProgress("2026-02-01").target, 30);
  assert.equal(
    s.annualProgress({ year: 2026, timeZone: "UTC", now: at }).target,
    15,
  );
  assert.throws(() =>
    s.setGoals({
      recordedAt: at,
      daily: {
        id: "rollback",
        effectiveDay: "2026-03-01",
        unit: "minutes",
        minutes: 40,
      },
      annual: { year: 2026, books: 7, id: "z" },
    }),
  );
  assert.equal(s.dailyProgress("2026-03-01").target, 30);
  s.setGoals({
    recordedAt: "2026-09-25T00:00:00Z",
    annual: { year: 2026, books: null },
  });
  assert.equal(
    s.annualProgress({ year: 2026, timeZone: "UTC", now: at }).target,
    null,
  );
});
test("SQLite backup is consistent and refuses overwrite", async (t) => {
  const f = fixture(t);
  book(f.store);
  f.store.markFinished({ bookId: "b", clickedAt: at });
  const destination = path.join(f.dir, "backup.sqlite");
  await f.store.backupTo(destination);
  const copy = new JournalStore(destination);
  assert.equal(copy.completion("b").payload.finishedAt, at);
  copy.close();
  const before = fs.readFileSync(destination);
  await assert.rejects(f.store.backupTo(destination), /EEXIST/);
  assert.deepEqual(fs.readFileSync(destination), before);
});
test("future and unknown schemas and symlink paths reject without changing source", (t) => {
  const { dir } = fixture(t);
  const file = path.join(dir, "newer.sqlite"),
    db = new DatabaseSync(file);
  db.exec(
    "PRAGMA user_version=99;CREATE TABLE precious(value TEXT);INSERT INTO precious VALUES('keep');",
  );
  db.close();
  const before = fs.readFileSync(file);
  assert.throws(() => new JournalStore(file), /Newer/);
  assert.deepEqual(fs.readFileSync(file), before);
  const alias = path.join(dir, "alias");
  fs.symlinkSync(path.join(dir, "absent"), alias);
  assert.throws(() => new JournalStore(alias), /Unsafe/);
  assert.equal(fs.existsSync(path.join(dir, "absent")), false);
});
function prototype() {
  return {
    format: "stillleaf-journal-prototype",
    version: 1,
    unknown: { retained: true },
    books: [
      {
        id: "old",
        title: "Same title",
        author: "A",
        totalPages: 200,
        status: "Finished",
        createdAt: "2025-01-01T00:00:00Z",
      },
    ],
    entries: [
      {
        id: "entry",
        bookId: "old",
        date: "2025-01-02",
        pagesRead: 0,
        minutes: 12.5,
        position: 80,
        note: "Past day",
        source: "manual",
        createdAt: "2025-01-03T00:00:00Z",
      },
    ],
  };
}
test("explicit prototype import retains exact source, unknown fields and provenance with no fake finish time", (t) => {
  const f = fixture(t),
    file = path.join(f.dir, "source.json"),
    raw = Buffer.from(JSON.stringify(prototype(), null, 2));
  fs.writeFileSync(file, raw);
  const result = importPrototypeFile(f.store, file, {
    recordedAt: at,
    timeZone: "America/Los_Angeles",
  });
  assert.equal(result.status, "imported");
  assert.deepEqual(fs.readFileSync(file), raw);
  assert.deepEqual(
    Buffer.from(
      f.store.db.prepare("SELECT original_json FROM migration_sources").get()
        .original_json,
    ),
    raw,
  );
  assert.equal(f.store.completion("prototype:old").payload.finishedAt, null);
  assert.equal(
    f.store.annualProgress({ year: 2025, timeZone: "UTC", now: at }).books,
    0,
  );
  assert.equal(f.store.manualEntries()[0].minutes, 12.5);
  assert.equal(f.store.manualEntries()[0].recorded_at, at);
  assert.equal(
    importPrototypeFile(f.restart(), file, { recordedAt: at, timeZone: "UTC" })
      .status,
    "duplicate",
  );
  assert.equal(f.store.manualEntries().length, 1);
});
test("changed prototype records reject atomically; future version leaves source untouched", (t) => {
  const f = fixture(t),
    file = path.join(f.dir, "source.json"),
    data = prototype();
  fs.writeFileSync(file, JSON.stringify(data));
  importPrototypeFile(f.store, file, { recordedAt: at, timeZone: "UTC" });
  data.books.unshift({ ...data.books[0], id: "added" });
  data.entries[0].minutes = 19;
  fs.writeFileSync(file, JSON.stringify(data));
  assert.throws(
    () =>
      importPrototypeFile(f.store, file, { recordedAt: at, timeZone: "UTC" }),
    /conflict/,
  );
  assert.equal(f.store.getBook("prototype:added"), null);
  assert.equal(f.store.manualEntries()[0].minutes, 12.5);
  data.version = 99;
  const before = JSON.stringify(data);
  fs.writeFileSync(file, before);
  assert.throws(
    () =>
      importPrototypeFile(f.store, file, { recordedAt: at, timeZone: "UTC" }),
    /Unsupported/,
  );
  assert.equal(fs.readFileSync(file, "utf8"), before);
});
