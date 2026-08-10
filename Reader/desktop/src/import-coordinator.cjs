"use strict";
const path = require("node:path");

// Host event coordination only: this module cannot start a reader or credit time.
// Importers return only after their managed-file transaction has completed.
class ImportCoordinator {
  constructor({
    importFile,
    presentLibrary,
    changed = () => {},
    limit = 1000,
    platform = process.platform,
  }) {
    if (
      typeof importFile !== "function" ||
      typeof presentLibrary !== "function"
    )
      throw new TypeError("Importer and Library presenter required");
    this.importFile = importFile;
    this.presentLibrary = presentLibrary;
    this.changed = changed;
    this.limit = limit;
    this.platform = platform;
    this.paths = platform === "win32" ? path.win32 : path.posix;
    this.items = [];
    this.overflow = 0;
    this.running = null;
    this.presentationPending = false;
    this.ready = false;
  }
  snapshot() {
    return {
      items: this.items.map(
        ({ path: source, state, message, publication }) => ({
          path: source,
          state,
          message,
          publication,
        }),
      ),
      overflow: this.overflow,
    };
  }
  notify() {
    this.changed(this.snapshot());
  }
  setReady() {
    this.ready = true;
    this.flushPresentation();
    return this.drain();
  }
  flushPresentation() {
    if (this.ready && this.presentationPending) {
      this.presentationPending = false;
      this.presentLibrary();
    }
  }
  enqueue(files) {
    if (!files.length) return this.running || Promise.resolve();
    if (!this.running && !this.items.some((item) => item.state === "queued")) {
      this.items = [];
      this.overflow = 0;
    }
    this.presentationPending = true;
    const canonical = (value) =>
      this.platform === "win32" ? value.toLowerCase() : value;
    const keys = new Set(this.items.map((item) => canonical(item.path)));
    for (const file of files) {
      if (typeof file !== "string" || file.includes("\0")) continue;
      const source = this.paths.resolve(file),
        key = canonical(source);
      if (keys.has(key)) continue;
      if (this.items.length >= this.limit) {
        this.overflow++;
        continue;
      }
      keys.add(key);
      const valid = this.paths.extname(source).toLowerCase() === ".epub";
      this.items.push({
        path: source,
        state: valid ? "queued" : "failed",
        message: valid ? undefined : "Choose an EPUB file.",
      });
    }
    this.flushPresentation();
    this.notify();
    return this.ready ? this.drain() : Promise.resolve();
  }
  cancelPending() {
    // In-flight work reports its actual transaction outcome; cancellation cannot
    // turn a successfully committed book into a claimed failure.
    for (const item of this.items)
      if (item.state === "queued") item.state = "cancelled";
    this.notify();
  }
  drain() {
    if (this.running) return this.running;
    this.running = Promise.resolve()
      .then(async () => {
        for (;;) {
          const item = this.items.find((value) => value.state === "queued");
          if (!item) break;
          item.state = "importing";
          this.notify();
          try {
            const outcome = await this.importFile(item.path);
            if (!outcome || !["imported", "duplicate"].includes(outcome.status))
              throw new Error("Import did not return a committed result.");
            item.state = outcome.status;
            item.publication = outcome.publication;
          } catch (error) {
            item.state = "failed";
            item.message =
              error instanceof Error ? error.message : "Import failed.";
          }
          this.notify();
        }
      })
      .finally(() => {
        this.running = null;
      });
    return this.running;
  }
}

// The executable/application path is never an import candidate. OS argv carries
// absolute paths; extension filtering excludes switches and unrelated arguments.
function epubArguments(argv, platform = process.platform) {
  const paths = platform === "win32" ? path.win32 : path.posix;
  return argv
    .slice(1)
    .filter(
      (value) =>
        typeof value === "string" &&
        !value.startsWith("-") &&
        paths.isAbsolute(value) &&
        paths.extname(value).toLowerCase() === ".epub",
    );
}
module.exports = { ImportCoordinator, epubArguments };
