"use strict";
const fs = require("node:fs"),
  crypto = require("node:crypto");
const v = require("./validation.cjs");
const namespace = "stillleaf-journal-prototype/v1";
const hash = (value) => crypto.createHash("sha256").update(value).digest("hex");
// Explicit, one-time source import. A changed existing source record requires a future
// conflict-resolution UI; this adapter never guesses which copy wins.
function importPrototypeFile(store, file, { recordedAt, timeZone }) {
  const at = v.instant(recordedAt),
    zone = v.timezone(timeZone);
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 16 * 1024 * 1024)
    throw Error("Invalid prototype source file");
  const original = fs.readFileSync(file);
  if (original.length > 16 * 1024 * 1024)
    throw Error("Prototype source too large");
  const digest = hash(original),
    data = JSON.parse(original.toString("utf8"));
  if (
    data.format !== "stillleaf-journal-prototype" ||
    data.version !== 1 ||
    !Array.isArray(data.books) ||
    !Array.isArray(data.entries) ||
    data.books.length > 10000 ||
    data.entries.length > 100000
  )
    throw Error("Unsupported prototype archive");
  const ids = new Set(),
    entries = new Set();
  for (const b of data.books) {
    v.identity(b.id);
    if (ids.has(b.id)) throw Error("Duplicate prototype book");
    ids.add(b.id);
    v.text(b.title, 4096, "title", true);
    v.text(b.author, 4096, "author");
    v.instant(b.createdAt);
    v.optional(b.totalPages, 1, 1000000, "total pages", true);
    if (
      !["Want to read", "Reading", "Finished", "Did not finish"].includes(
        b.status,
      )
    )
      throw Error("Invalid prototype status");
  }
  for (const e of data.entries) {
    v.identity(e.id);
    if (entries.has(e.id) || !ids.has(e.bookId))
      throw Error("Invalid prototype entry identity");
    entries.add(e.id);
    v.day(e.date);
    v.instant(e.createdAt);
    v.optional(e.position, 0, 1000000, "position", true);
    v.optional(e.pagesRead, 0, 1000000, "pages", true);
    v.optional(e.minutes, 0, 1440, "minutes");
    v.text(e.note, 50000, "note");
    if (e.source !== "manual")
      throw Error("Unsupported prototype entry source");
  }
  return store.transaction(() => {
    if (
      store.db
        .prepare("SELECT digest FROM migration_sources WHERE digest=?")
        .get(digest)
    )
      return { status: "duplicate", digest, books: 0, entries: 0 };
    function imported(kind, item, work) {
      const payloadHash = hash(JSON.stringify(item)),
        prior = store.db
          .prepare(
            "SELECT * FROM migration_records WHERE namespace=? AND kind=? AND source_id=?",
          )
          .get(namespace, kind, item.id);
      if (prior) {
        if (prior.payload_hash !== payloadHash)
          throw Error(
            "Prototype source record changed; explicit conflict resolution required",
          );
        return false;
      }
      const target = "prototype:" + item.id;
      v.identity(target);
      work(target);
      store.db
        .prepare("INSERT INTO migration_records VALUES(?,?,?,?,?)")
        .run(namespace, kind, item.id, target, payloadHash);
      return true;
    }
    let books = 0,
      entries = 0;
    for (const b of data.books)
      if (
        imported("book", b, (id) => {
          if (store.getBook(id))
            throw Error(
              "Prototype book identity already exists without provenance",
            );
          store.createBook({
            id,
            title: b.title,
            creators: b.author ? [b.author] : [],
            source: namespace,
            recordedAt: at,
          });
          if (b.status === "Finished")
            store.recordCompletion({
              bookId: id,
              recordedAt: at,
              source: namespace,
              imported: true,
              finishedAt: null,
            });
        })
      )
        books++;
    for (const e of data.entries)
      if (
        imported("entry", e, (id) => {
          if (
            store.db
              .prepare("SELECT entry_id FROM manual_entries WHERE entry_id=?")
              .get(id)
          )
            throw Error(
              "Prototype entry identity already exists without provenance",
            );
          store.addManualEntry({
            id,
            bookId: "prototype:" + e.bookId,
            day: e.date,
            timeZone: zone,
            pages: e.pagesRead,
            minutes: e.minutes,
            position: e.position,
            note: e.note,
            recordedAt: at,
            provenance: JSON.stringify({
              namespace,
              sourceId: e.id,
              originalCreatedAt: e.createdAt,
            }),
          });
        })
      )
        entries++;
    store.db
      .prepare("INSERT INTO migration_sources VALUES(?,?,?,?)")
      .run(digest, namespace, at, original);
    return { status: "imported", digest, books, entries };
  });
}
module.exports = { importPrototypeFile };
