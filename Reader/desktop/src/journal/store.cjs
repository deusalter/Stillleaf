"use strict";
const fs = require("node:fs"),
  path = require("node:path"),
  crypto = require("node:crypto");
const { DatabaseSync, backup } = require("node:sqlite");
const v = require("./validation.cjs");
const SCHEMA_VERSION = 2;
const TRACKING_SCHEMA = `
  CREATE TABLE tracking_intervals(interval_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,book_id TEXT NOT NULL REFERENCES books(book_id),start_at TEXT NOT NULL,end_at TEXT NOT NULL,duration REAL NOT NULL,timezone_id TEXT NOT NULL,mode TEXT NOT NULL,source TEXT NOT NULL,disposition TEXT NOT NULL,payload TEXT NOT NULL) STRICT;
  CREATE INDEX tracking_times ON tracking_intervals(start_at,end_at);
  CREATE INDEX tracking_book ON tracking_intervals(book_id,start_at);`;
// Native ReadingStatistics uses the requested reporting timezone, not each sample's recorded timezone.
function dayBoundary(day, zone) {
  const format = new Intl.DateTimeFormat("en-US", {timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit"});
  const key = (milliseconds) => {
    const p = Object.fromEntries(format.formatToParts(new Date(milliseconds)).map(x => [x.type,x.value]));
    return `${p.year.padStart(4,"0")}-${p.month}-${p.day}`;
  };
  const center = Date.parse(day + "T00:00:00Z");
  let low = center - 48 * 3600000, high = center + 48 * 3600000;
  while (low < high) { const middle = Math.floor((low + high) / 2); if (key(middle) < day) low = middle + 1; else high = middle; }
  return low;
}
const uuid = () => crypto.randomUUID();
function row(value) {
  return value ? { ...value } : null;
}
class JournalStore {
  constructor(file, {timeZone = "UTC"} = {}) {
    this.timeZone = v.timezone(timeZone);
    this.migrationBackup = null;
    if (typeof file !== "string" || !path.isAbsolute(file))
      throw Error("Journal needs an absolute private database path");
    this.file = file;
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    try {
      const stat = fs.lstatSync(file);
      if (!stat.isFile() || stat.isSymbolicLink())
        throw Error("Unsafe journal path");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    this.db = new DatabaseSync(file, { timeout: 5000 });
    this.inTransaction = false;
    try {
      const version = this.db.prepare("PRAGMA user_version").get().user_version;
      if (version > SCHEMA_VERSION || version < 0)
        throw Error("Newer journal schema; no data changed");
      if (version === 0) {
        const tables = this.db
          .prepare(
            "SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
          )
          .all();
        if (tables.length)
          throw Error("Unknown unversioned database; no migration attempted");
        this.db.exec(`BEGIN IMMEDIATE;
      CREATE TABLE books(book_id TEXT PRIMARY KEY,title TEXT NOT NULL,creators TEXT NOT NULL,source TEXT NOT NULL,recorded_at TEXT NOT NULL) STRICT;
      CREATE TABLE editions(edition_id TEXT PRIMARY KEY,book_id TEXT NOT NULL REFERENCES books(book_id),recorded_at TEXT NOT NULL) STRICT;
      CREATE TABLE manual_entries(entry_id TEXT PRIMARY KEY,book_id TEXT NOT NULL REFERENCES books(book_id),day TEXT NOT NULL,timezone_id TEXT NOT NULL,pages INTEGER,minutes REAL,position INTEGER,note TEXT NOT NULL,recorded_at TEXT NOT NULL,provenance TEXT) STRICT;
      CREATE INDEX manual_days ON manual_entries(day,book_id);
      CREATE TABLE events(seq INTEGER PRIMARY KEY AUTOINCREMENT,event_id TEXT UNIQUE NOT NULL,kind TEXT NOT NULL,book_id TEXT REFERENCES books(book_id),recorded_at TEXT NOT NULL,payload TEXT NOT NULL) STRICT;
      CREATE INDEX events_book_kind ON events(book_id,kind,recorded_at,seq);
      CREATE TABLE daily_goals(seq INTEGER PRIMARY KEY AUTOINCREMENT,goal_id TEXT UNIQUE NOT NULL,effective_day TEXT NOT NULL,unit TEXT NOT NULL,minutes REAL NOT NULL,pages REAL,recorded_at TEXT NOT NULL) STRICT;
      CREATE TABLE migration_sources(digest TEXT PRIMARY KEY,namespace TEXT NOT NULL,imported_at TEXT NOT NULL,original_json BLOB NOT NULL) STRICT;
      CREATE TABLE migration_records(namespace TEXT NOT NULL,kind TEXT NOT NULL,source_id TEXT NOT NULL,target_id TEXT NOT NULL,payload_hash TEXT NOT NULL,PRIMARY KEY(namespace,kind,source_id)) STRICT;
      ${TRACKING_SCHEMA}
      PRAGMA user_version=2;COMMIT;`);
      }
      if (version === 1) this.migrateV1();
      this.db.exec(
        "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;",
      );
      fs.chmodSync(file, 0o600);
    } catch (error) {
      try {
        this.db.close();
      } catch {}
      throw error;
    }
  }
  migrateV1() {
    // Validate the known source before migration; VACUUM INTO creates a consistent SQLite snapshot
    // including committed WAL content without copying a live database/WAL pair.
    if (this.db.prepare("PRAGMA integrity_check").get().integrity_check !== "ok" || this.db.prepare("PRAGMA foreign_key_check").all().length) throw Error("Journal integrity failed; migration was not attempted");
    const expected = {
      books: ["book_id","title","creators","source","recorded_at"],
      editions: ["edition_id","book_id","recorded_at"],
      manual_entries: ["entry_id","book_id","day","timezone_id","pages","minutes","position","note","recorded_at","provenance"],
      events: ["seq","event_id","kind","book_id","recorded_at","payload"],
      daily_goals: ["seq","goal_id","effective_day","unit","minutes","pages","recorded_at"],
      migration_sources: ["digest","namespace","imported_at","original_json"],
      migration_records: ["namespace","kind","source_id","target_id","payload_hash"],
    };
    for (const [table, columns] of Object.entries(expected)) {
      const actual = this.db.prepare(`PRAGMA table_info(${table})`).all().map(x => x.name);
      if (JSON.stringify(actual) !== JSON.stringify(columns)) throw Error("Unknown v1 journal shape; migration was not attempted");
    }
    const destination = this.file + ".pre-v2-" + uuid() + ".sqlite";
    const reservation = fs.openSync(destination, "wx", 0o600); fs.closeSync(reservation);
    try {
      this.db.prepare("VACUUM INTO ?").run(destination);
      const copy = new DatabaseSync(destination, {readOnly: true});
      try {
        if (copy.prepare("PRAGMA integrity_check").get().integrity_check !== "ok" || copy.prepare("PRAGMA user_version").get().user_version !== 1 || copy.prepare("PRAGMA foreign_key_check").all().length) throw Error("Pre-migration backup validation failed");
      } finally { copy.close(); }
    } catch (error) { fs.rmSync(destination, {force: true}); throw error; }
    this.migrationBackup = destination;
    this.db.exec("BEGIN IMMEDIATE");
    try { this.db.exec(TRACKING_SCHEMA + "PRAGMA user_version=2;"); this.db.exec("COMMIT"); }
    catch (error) { this.db.exec("ROLLBACK"); throw error; }
  }
  transaction(work) {
    if (this.inTransaction) return work();
    this.db.exec("BEGIN IMMEDIATE");
    this.inTransaction = true;
    try {
      const result = work();
      if (result && typeof result.then === "function")
        throw Error("Journal transactions must be synchronous");
      this.db.exec("COMMIT");
      return result;
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    } finally {
      this.inTransaction = false;
    }
  }
  close() {
    this.db.close();
  }
  getBook(id) {
    v.identity(id);
    const result = row(
      this.db.prepare("SELECT * FROM books WHERE book_id=?").get(id),
    );
    if (result) result.creators = JSON.parse(result.creators);
    return result;
  }
  listBooks() {
    return this.db
      .prepare("SELECT book_id FROM books ORDER BY title,book_id")
      .all()
      .map(({ book_id: id }) => ({
        ...this.getBook(id),
        editionIds: this.db
          .prepare(
            "SELECT edition_id FROM editions WHERE book_id=? ORDER BY edition_id",
          )
          .all(id)
          .map((x) => x.edition_id),
      }));
  }
  requireBook(id) {
    const book = this.getBook(id);
    if (!book) throw Error("Unknown journal book");
    return book;
  }
  createBook({
    id = uuid(),
    title,
    creators = [],
    source = "manual",
    recordedAt,
  }) {
    v.identity(id);
    title = v.text(title, 4096, "book title", true).trim();
    if (!Array.isArray(creators) || creators.length > 100)
      throw Error("Invalid creators");
    creators = creators.map((x) => v.text(x, 4096, "creator"));
    v.identity(source, "source");
    const at = v.instant(recordedAt);
    return this.transaction(() => {
      const existing = this.getBook(id);
      if (existing) {
        if (
          existing.title !== title ||
          JSON.stringify(existing.creators) !== JSON.stringify(creators) ||
          existing.source !== source
        )
          throw Error(
            "Existing book identity conflicts; explicit matching required",
          );
        return existing;
      }
      this.db
        .prepare("INSERT INTO books VALUES(?,?,?,?,?)")
        .run(id, title, JSON.stringify(creators), source, at);
      return this.getBook(id);
    });
  }
  attachEdition({ editionId, title, creators = [], bookId, recordedAt }) {
    if (typeof editionId !== "string" || !/^[a-f0-9]{64}$/.test(editionId))
      throw Error("Invalid publication edition");
    const at = v.instant(recordedAt);
    return this.transaction(() => {
      const link = row(
        this.db
          .prepare("SELECT * FROM editions WHERE edition_id=?")
          .get(editionId),
      );
      if (link) {
        if (bookId && bookId !== link.book_id)
          throw Error("Edition is already linked to another book");
        return {
          created: false,
          book: this.requireBook(link.book_id),
          editionId,
        };
      }
      const id = bookId ?? "epub:" + editionId;
      const book =
        this.getBook(id) ||
        this.createBook({
          id,
          title,
          creators,
          source: "epub",
          recordedAt: at,
        });
      this.db
        .prepare("INSERT INTO editions VALUES(?,?,?)")
        .run(editionId, id, at);
      return { created: true, book, editionId };
    });
  }
  addManualEntry({
    id = uuid(),
    bookId,
    day,
    timeZone,
    pages = null,
    minutes = null,
    position = null,
    note = "",
    recordedAt,
    provenance = null,
  }) {
    this.requireBook(bookId);
    const at = v.instant(recordedAt),
      civil = v.day(day),
      zone = v.timezone(timeZone);
    if (civil > v.dayAt(at, zone))
      throw Error("Reading day cannot be later than record time");
    pages = v.optional(pages, 0, 1000000, "pages", true);
    minutes = v.optional(minutes, 0, 1440, "minutes");
    position = v.optional(position, 0, 1000000, "position", true);
    note = v.text(note, 50000, "entry note").trim();
    if (pages === null && minutes === null && position === null && !note)
      throw Error("Manual entry needs supplied reading evidence");
    v.identity(id);
    if (provenance !== null) v.text(provenance, 4096, "provenance");
    const data = {
      entry_id: id,
      book_id: bookId,
      day: civil,
      timezone_id: zone,
      pages,
      minutes,
      position,
      note,
      recorded_at: at,
      provenance,
    };
    return this.transaction(() => {
      const existing = row(
        this.db
          .prepare("SELECT * FROM manual_entries WHERE entry_id=?")
          .get(id),
      );
      if (existing) {
        if (JSON.stringify(existing) !== JSON.stringify(data))
          throw Error("Manual entry identity conflicts");
        return { created: false, entry: existing };
      }
      this.db
        .prepare("INSERT INTO manual_entries VALUES(?,?,?,?,?,?,?,?,?,?)")
        .run(...Object.values(data));
      return { created: true, entry: data };
    });
  }
  manualEntries(bookId) {
    if (bookId) this.requireBook(bookId);
    return this.db
      .prepare(
        "SELECT * FROM manual_entries" +
          (bookId ? " WHERE book_id=?" : "") +
          " ORDER BY day,recorded_at,entry_id",
      )
      .all(...(bookId ? [bookId] : []))
      .map(row);
  }
  /** Synchronous atomic sink for SessionTracker. No pages or renderer location fields accepted. */
  appendTrackingBatch(batch) {
    if (!batch || !Array.isArray(batch.intervals) || !Array.isArray(batch.events) || batch.intervals.length > 10000 || batch.events.length > 20000) throw Error("Invalid tracking batch");
    const intervals = batch.intervals.map(item => {
      if (!item || item.pages !== undefined || item.pagesRead !== undefined || item.position !== undefined || item.locator !== undefined) throw Error("Tracking intervals cannot infer pages or positions");
      this.requireBook(item.bookId);
      for (const field of ["id","sessionId","source"]) v.identity(item[field], field);
      const start = v.instant(item.start), end = v.instant(item.end), wall = (Date.parse(end) - Date.parse(start)) / 1000;
      const duration = v.number(item.duration, Number.MIN_VALUE, 366 * 86400, "tracked duration");
      if (end <= start || duration > wall + 2 || !["automatic","manual"].includes(item.mode) || !["credited","uncertain"].includes(item.disposition)) throw Error("Invalid tracked interval");
      return {id:item.id, sessionId:item.sessionId, bookId:item.bookId, source:item.source, mode:item.mode, timezoneId:v.timezone(item.timezoneId), start, end, duration, disposition:item.disposition};
    });
    const events = batch.events.map(item => {
      if (!item || !["trackingStarted","trackingCheckpoint","trackingPaused","trackingClockHold","trackingRecovery"].includes(item.kind)) throw Error("Invalid tracking event");
      v.identity(item.id); if (item.bookId !== null) this.requireBook(item.bookId);
      if (item.sessionId !== null) v.identity(item.sessionId, "session");
      if (item.source !== null) v.identity(item.source, "source");
      if (item.mode !== null && !["automatic","manual"].includes(item.mode)) throw Error("Invalid tracking mode");
      const reason = item.reason == null ? null : v.text(item.reason, 4096, "tracking reason");
      return {id:item.id, kind:item.kind, bookId:item.bookId, date:v.instant(item.date), payload:{sessionId:item.sessionId, source:item.source, mode:item.mode, timezoneId:v.timezone(item.timezoneId), reason}};
    });
    return this.transaction(() => {
      let inserted = 0;
      for (const item of intervals) {
        const payload = JSON.stringify(item), existing = this.db.prepare("SELECT payload FROM tracking_intervals WHERE interval_id=?").get(item.id);
        if (existing) { if (existing.payload !== payload) throw Error("Tracking interval identity conflicts"); continue; }
        const session = this.db.prepare("SELECT book_id,source,mode,timezone_id FROM tracking_intervals WHERE session_id=? LIMIT 1").get(item.sessionId);
        if (session && (session.book_id !== item.bookId || session.source !== item.source || session.mode !== item.mode || session.timezone_id !== item.timezoneId)) throw Error("Tracking session identity conflicts");
        if (this.db.prepare("SELECT interval_id FROM tracking_intervals WHERE start_at<? AND end_at>? LIMIT 1").get(item.end,item.start)) throw Error("Tracking intervals overlap");
        this.db.prepare("INSERT INTO tracking_intervals VALUES(?,?,?,?,?,?,?,?,?,?,?)").run(item.id,item.sessionId,item.bookId,item.start,item.end,item.duration,item.timezoneId,item.mode,item.source,item.disposition,payload);
        inserted++;
      }
      for (const item of events) this.appendEvent(item.kind,item.bookId,item.payload,item.date,item.id);
      return {insertedIntervals: inserted};
    });
  }
  trackingIntervals(bookId) {
    if (bookId !== undefined) this.requireBook(bookId);
    return this.db.prepare("SELECT payload FROM tracking_intervals" + (bookId === undefined ? "" : " WHERE book_id=?") + " ORDER BY start_at,interval_id").all(...(bookId === undefined ? [] : [bookId])).map(x => JSON.parse(x.payload));
  }
  trackingWatermark(bookId) {
    if (bookId !== undefined) this.requireBook(bookId);
    return this.db.prepare("SELECT MAX(end_at) AS watermark FROM tracking_intervals" + (bookId === undefined ? "" : " WHERE book_id=?")).get(...(bookId === undefined ? [] : [bookId])).watermark ?? null;
  }
  appendEvent(kind, bookId, payload, recordedAt, id = uuid()) {
    if (bookId !== null) this.requireBook(bookId);
    v.identity(id);
    const at = v.instant(recordedAt),
      json = JSON.stringify(payload);
    const existing = this.db
      .prepare("SELECT * FROM events WHERE event_id=?")
      .get(id);
    if (existing) {
      if (
        existing.kind !== kind ||
        existing.book_id !== bookId ||
        existing.recorded_at !== at ||
        existing.payload !== json
      )
        throw Error("Event identity conflicts");
      return this.decodeEvent(existing);
    }
    this.db
      .prepare(
        "INSERT INTO events(event_id,kind,book_id,recorded_at,payload) VALUES(?,?,?,?,?)",
      )
      .run(id, kind, bookId, at, json);
    return this.decodeEvent(
      this.db.prepare("SELECT * FROM events WHERE event_id=?").get(id),
    );
  }
  decodeEvent(value) {
    return value
      ? {
          id: value.event_id,
          sequence: value.seq,
          kind: value.kind,
          bookId: value.book_id,
          recordedAt: value.recorded_at,
          payload: JSON.parse(value.payload),
        }
      : null;
  }
  events(kind, bookId) {
    return this.db
      .prepare(
        "SELECT * FROM events WHERE kind=?" +
          (bookId !== undefined ? " AND book_id=?" : "") +
          " ORDER BY recorded_at,seq",
      )
      .all(kind, ...(bookId !== undefined ? [bookId] : []))
      .map((x) => this.decodeEvent(x));
  }
  completion(bookId) {
    this.requireBook(bookId);
    const candidates = this.events("bookCompleted", bookId),
      manual = candidates.filter((x) => !x.payload.imported);
    return (manual.length ? manual : candidates).at(-1) ?? null;
  }
  markFinished({ bookId, clickedAt, id = uuid() }) {
    const at = v.instant(clickedAt);
    return this.transaction(() => {
      const previous = this.completion(bookId);
      if (previous)
        return { created: false, event: previous, celebrationToken: null };
      const event = this.appendEvent(
        "bookCompleted",
        bookId,
        { startedAt: null, finishedAt: at, source: "You", imported: false },
        at,
        id,
      );
      return { created: true, event, celebrationToken: event.id };
    });
  }
  recordCompletion({
    bookId,
    startedAt = null,
    finishedAt = null,
    recordedAt,
    source = "You",
    imported = false,
    id = uuid(),
  }) {
    const at = v.instant(recordedAt),
      start = startedAt === null ? null : v.instant(startedAt),
      finish = finishedAt === null ? null : v.instant(finishedAt);
    v.identity(source, "completion source");
    if (
      typeof imported !== "boolean" ||
      (start && start > at) ||
      (finish && finish > at) ||
      (start && finish && start > finish)
    )
      throw Error("Invalid completion dates");
    return this.transaction(() =>
      this.appendEvent(
        "bookCompleted",
        bookId,
        { startedAt: start, finishedAt: finish, source, imported },
        at,
        id,
      ),
    );
  }
  editCompletionDates({
    bookId,
    startedAt = null,
    finishedAt = null,
    recordedAt,
  }) {
    const previous = this.completion(bookId);
    if (!previous) throw Error("Book is not marked finished");
    if (
      previous.payload.startedAt === startedAt &&
      previous.payload.finishedAt === finishedAt
    )
      return { changed: false, event: previous };
    const event = this.recordCompletion({
      bookId,
      startedAt,
      finishedAt,
      recordedAt,
    });
    return { changed: true, event };
  }
  setRating({ bookId, value, recordedAt, id = uuid() }) {
    if (value !== null) {
      v.number(value, 0, 5, "rating");
      if (Math.abs(value * 4 - Math.round(value * 4)) > 0.0000001)
        throw Error("Rating must use quarter-star steps");
    }
    return this.transaction(() =>
      this.appendEvent("bookRated", bookId, { value }, recordedAt, id),
    );
  }
  rating(bookId) {
    return this.events("bookRated", bookId).at(-1)?.payload.value ?? null;
  }
  setReview({ bookId, text, recordedAt, id = uuid() }) {
    const value = v.review(text);
    return this.transaction(() =>
      this.appendEvent("bookReviewed", bookId, { text: value }, recordedAt, id),
    );
  }
  review(bookId) {
    return this.events("bookReviewed", bookId).at(-1)?.payload.text ?? null;
  }
  setGoals({ daily, annual, recordedAt }) {
    const at = v.instant(recordedAt);
    let d = null,
      a = null;
    if (daily) {
      const unit = daily.unit;
      if (!["pages", "minutes"].includes(unit))
        throw Error("Invalid daily goal unit");
      d = {
        id: daily.id ?? uuid(),
        day: v.day(daily.effectiveDay),
        unit,
        minutes: v.number(daily.minutes, Number.MIN_VALUE, 1440, "minute goal"),
        pages: v.optional(daily.pages, Number.MIN_VALUE, 1000000, "page goal"),
      };
      v.identity(d.id);
      if (unit === "pages" && d.pages === null)
        throw Error("Pages goal needs a target");
    }
    if (annual) {
      a = {
        year: v.number(annual.year, 1, 9999, "goal year", true),
        books: v.optional(annual.books, 1, 10000, "annual book goal", true),
        id: annual.id ?? uuid(),
      };
      v.identity(a.id);
    }
    return this.transaction(() => {
      if (d)
        this.db
          .prepare(
            "INSERT INTO daily_goals(goal_id,effective_day,unit,minutes,pages,recorded_at) VALUES(?,?,?,?,?,?)",
          )
          .run(d.id, d.day, d.unit, d.minutes, d.pages, at);
      if (a)
        this.appendEvent(
          "annualGoalChanged",
          null,
          { year: a.year, books: a.books },
          at,
          a.id,
        );
      return { daily: d, annual: a };
    });
  }
  dailyProgress(day, timeZone = this.timeZone) {
    const civil = v.day(day),
      totals = this.db
        .prepare(
          "SELECT COALESCE(SUM(pages),0) AS pages,COALESCE(SUM(minutes),0) AS minutes,COUNT(*) AS entries FROM manual_entries WHERE day=?",
        )
        .get(civil),
      goal = this.db
        .prepare(
          "SELECT * FROM daily_goals WHERE effective_day<=? ORDER BY effective_day DESC,seq DESC LIMIT 1",
        )
        .get(civil);
    const zone = v.timezone(timeZone), nextDay = new Date(Date.parse(civil + "T00:00:00Z") + 86400000).toISOString().slice(0,10);
    const from = dayBoundary(civil,zone), through = dayBoundary(nextDay,zone);
    let creditedSeconds = 0, uncertainSeconds = 0, automaticSeconds = 0, trackedManualSeconds = 0;
    const tracked = this.db.prepare("SELECT start_at,end_at,duration,disposition,mode FROM tracking_intervals WHERE start_at<? AND end_at>?").all(new Date(through).toISOString(),new Date(from).toISOString());
    for (const interval of tracked) {
      const start = Date.parse(interval.start_at), end = Date.parse(interval.end_at);
      const overlap = Math.max(0, Math.min(end,through) - Math.max(start,from));
      const share = interval.duration * overlap / (end-start);
      if (interval.disposition === "uncertain") uncertainSeconds += share;
      else { creditedSeconds += share; if (interval.mode === "automatic") automaticSeconds += share; else trackedManualSeconds += share; }
    }
    totals.minutes += creditedSeconds / 60;
    const unit = goal?.unit ?? "minutes",
      target = unit === "pages" ? goal.pages : (goal?.minutes ?? 20),
      value = totals[unit];
    return {
      day: civil,
      ...row(totals),
      unit,
      value,
      target,
      fraction: Math.min(1, value / target),
      reached: value >= target,
      evidence: tracked.length ? "dated-manual-and-tracked" : "dated-manual",
      timeZone: zone, creditedSeconds, uncertainSeconds, automaticSeconds, trackedManualSeconds, trackingIntervals: tracked.length,
      minutesTarget: goal?.minutes ?? 20,
      pagesTarget: goal?.pages ?? null,
    };
  }
  annualProgress({ year, timeZone, now }) {
    v.number(year, 1, 9999, "year", true);
    const at = v.instant(now),
      zone = v.timezone(timeZone);
    const books = this.db.prepare("SELECT book_id FROM books").all();
    const ids = books
      .filter((b) => {
        const evidence = this.completion(b.book_id)?.payload;
        return (
          evidence?.finishedAt &&
          evidence.finishedAt <= at &&
          Number(v.dayAt(evidence.finishedAt, zone).slice(0, 4)) === year
        );
      })
      .map((x) => x.book_id);
    const target =
      this.events("annualGoalChanged")
        .filter((e) => e.payload.year === year)
        .sort(
          (a, b) =>
            a.recordedAt.localeCompare(b.recordedAt) ||
            (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
        )
        .at(-1)?.payload.books ?? null;
    return {
      year,
      timeZone: zone,
      books: ids.length,
      bookIds: ids,
      target,
      fraction: target ? Math.min(1, ids.length / target) : 0,
      reached: target !== null && ids.length >= target,
    };
  }
  timeline() {
    return this.db
      .prepare("SELECT book_id FROM books")
      .all()
      .map(({ book_id: id }) => {
        const event = this.completion(id);
        if (!event) return null;
        return {
          book: this.getBook(id),
          completion: event,
          rating: this.rating(id),
          review: this.review(id),
        };
      })
      .filter(Boolean)
      .sort(
        (a, b) =>
          (b.completion.payload.finishedAt ?? "").localeCompare(
            a.completion.payload.finishedAt ?? "",
          ) ||
          a.book.title.localeCompare(b.book.title) ||
          a.book.book_id.localeCompare(b.book.book_id),
      );
  }
  async backupTo(destination) {
    if (typeof destination !== "string" || !path.isAbsolute(destination))
      throw Error("Backup needs an absolute path");
    const reserve = fs.openSync(destination, "wx", 0o600);
    fs.closeSync(reserve);
    try {
      await backup(this.db, destination);
      const copy = new DatabaseSync(destination, { readOnly: true });
      try {
        if (
          copy.prepare("PRAGMA integrity_check").get().integrity_check !== "ok"
        )
          throw Error("Backup failed integrity check");
      } finally {
        copy.close();
      }
      return destination;
    } catch (error) {
      fs.rmSync(destination, { force: true });
      throw error;
    }
  }
}
module.exports = { JournalStore, SCHEMA_VERSION };
