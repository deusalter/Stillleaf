"use strict";
const {
  app,
  BrowserWindow,
  ipcMain,
  dialog,
  session,
  protocol,
  shell,
  powerMonitor,
} = require("electron");
const path = require("node:path");
const fs = require("node:fs/promises");
const { pathToFileURL } = require("node:url");
const { randomUUID } = require("node:crypto");
const {
  ImportCoordinator,
  epubArguments,
} = require("./import-coordinator.cjs");
const {
  listLibrary,
  readerInput,
  readEdition,
} = require("./library-store.cjs");
const { saveReaderState } = require("./reader-state.cjs");
const { ReaderSessionHost } = require("./journal/reader-session-host.cjs");
const { removeAssets } = require("./removal.cjs");
const readerStateTransfer = require("./reader-state-transfer.cjs");
const { JournalStore } = require("./journal/store.cjs");
const { LibraryArchive } = require("./library-archive.cjs");
const journalValidation = require("./journal/validation.cjs");
const { resolveCompletionDays } = require("./completion-dates.cjs");
const root = path.join(
  process.env.STILLLEAF_TEST_DATA ||
    path.join(app.getPath("appData"), "StillleafReaderDevelopment"),
  "library",
);
app.setName("Stillleaf Reader Development");
app.setPath("userData", path.dirname(root));
const libraryURL = pathToFileURL(path.join(__dirname, "index.html")).href;
protocol.registerSchemesAsPrivileged([
  {
    scheme: "stillleaf-app",
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: true,
      corsEnabled: true,
    },
  },
]);
const readerURL = "stillleaf-app://reader/index.html";
// Library covers are served by URL rather than inlined in every snapshot. The
// per-launch token keeps these URLs unknown to reader windows.
const coverRoot = `stillleaf-app://library/cover/${randomUUID()}/`;
let covers = new Map();
let library, coordinator, importer, journal, libraryArchive;
let archiveBusy = false;
const pending = [];
let activeReader, activeEdition, readingSessions;
let trackingError = null;
let quitting = false;
app.on("before-quit", (event) => {
  if (archiveBusy) { event.preventDefault(); return; }
  quitting = true;
});
let readerActions = Promise.resolve();
const test = Boolean(process.env.STILLLEAF_TEST_DATA);
function secure(window, allowed) {
  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  window.webContents.on("will-attach-webview", (event) =>
    event.preventDefault(),
  );
  window.webContents.on("will-navigate", (event, url) => {
    if (url !== allowed) event.preventDefault();
  });
  window.webContents.on("will-frame-navigate", (event) => {
    const d = event;
    if (
      d.url !== allowed &&
      !(
        d.isMainFrame === false &&
        (d.url?.startsWith("blob:") || d.url === "about:blank")
      )
    )
      event.preventDefault();
  });
}
function present() {
  if (quitting) return;
  if (!library || library.isDestroyed()) createLibrary();
  if (!test) {
    library.restore();
    library.show();
    library.focus();
  }
}
function createLibrary() {
  library = new BrowserWindow({
    width: 1180,
    height: 820,
    minWidth: 740,
    minHeight: 560,
    show: !test,
    backgroundColor: "#e8f0eb",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      backgroundThrottling: false,
    },
  });
  secure(library, libraryURL);
  library.setMenuBarVisibility(false);
  library.loadURL(libraryURL);
  let closingLibrary = false;
  library.on("close", (event) => {
    if (archiveBusy) { event.preventDefault(); return; }
    if (closingLibrary) return;
    event.preventDefault();
    library.webContents
      .executeJavaScript("window.prepareJournalClose?.() ?? true")
      .then((ok) => {
        if (ok) {
          closingLibrary = true;
          library.close();
        } else {
          quitting = false;
        }
      })
      .catch(() => {
        quitting = false;
      });
  });
}
async function snapshot() {
  const assets = await listLibrary(root);
  covers = new Map(
    assets.books
      .filter((asset) => asset.cover)
      .map((asset) => [coverRoot + asset.editionId, asset.cover]),
  );
  const now = new Date().toISOString();
  const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  for (const asset of assets.books)
    journal.attachEdition({ ...asset, recordedAt: now });
  const books = journal.listBooks().map((book) => {
    const asset = assets.books.find((x) =>
      book.editionIds.includes(x.editionId),
    );
    return {
      ...book,
      bookId: book.book_id,
      title: book.title,
      creators: book.creators,
      editionId: asset?.editionId ?? book.editionIds[0] ?? null,
      available: Boolean(asset),
      cover: asset?.cover ? coverRoot + asset.editionId : null,
      rating: journal.rating(book.book_id),
      review: journal.review(book.book_id),
      completion: journal.completion(book.book_id),
    };
  });
  const today = journalValidation.dayAt(now, timeZone);
  return {
    books,
    warnings: assets.warnings,
    queue: coordinator.snapshot(),
    today,
    timeZone,
    daily: journal.dailyProgress(today, timeZone),
    tracking: readingSessions?.snapshot ?? null,
    trackingError,
    automaticEntries: journal.trackingIntervals(),
    annual: journal.annualProgress({
      year: Number(today.slice(0, 4)),
      timeZone,
      now,
    }),
    entries: journal.manualEntries(),
  };
}
function journalAction(action, input) {
  if (!input || typeof input !== "object" || Array.isArray(input))
    throw Error("Invalid journal input");
  const fields = {
    createBook: ["title", "author"],
    finish: ["bookId"],
    dates: ["bookId", "startedDay", "finishedDay", "completionId", "timeZone"],
    review: ["bookId", "rating", "text"],
    manual: ["bookId", "day", "pages", "minutes", "position", "note"],
    goals: ["unit", "minutes", "pages", "annualBooks"],
  }[action];
  if (!fields || Object.keys(input).some((key) => !fields.includes(key)))
    throw Error("Unknown journal action or field");
  const now = new Date().toISOString(),
    timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  if (action === "createBook") {
    const author = journalValidation.text(input.author, 4096, "author").trim();
    return {
      book: journal.createBook({
        title: input.title,
        creators: author ? [author] : [],
        source: "manual",
        recordedAt: now,
      }),
    };
  }
  if (action === "finish")
    return journal.markFinished({ bookId: input.bookId, clickedAt: now });
  if (action === "dates") {
    const previous = journal.completion(input.bookId);
    if (!previous) throw Error("This book is no longer marked as read.");
    if (input.completionId !== previous.id)
      throw Error(
        "Saved reading dates changed while this editor was open. Your draft was kept; reopen it to review the saved dates.",
      );
    if (input.timeZone !== timeZone)
      throw Error(
        "Your timezone changed while this editor was open. Your draft was kept; reopen it to review local dates.",
      );
    const dates = resolveCompletionDays(input, previous.payload, now);
    return journal.editCompletionDates({
      bookId: input.bookId,
      ...dates,
      recordedAt: now,
    });
  }
  if (action === "review")
    return journal.transaction(() => ({
      rating: journal.setRating({
        bookId: input.bookId,
        value: input.rating,
        recordedAt: now,
      }),
      review: journal.setReview({
        bookId: input.bookId,
        text: input.text,
        recordedAt: now,
      }),
    }));
  if (action === "manual")
    return journal.addManualEntry({ ...input, timeZone, recordedAt: now });
  if (action === "goals") {
    const today = journalValidation.dayAt(now, timeZone);
    return journal.setGoals({
      recordedAt: now,
      daily: {
        effectiveDay: today,
        unit: input.unit,
        minutes: input.minutes,
        pages: input.pages,
      },
      annual: { year: Number(today.slice(0, 4)), books: input.annualBooks },
    });
  }
}
async function changed() {
  if (library && !library.isDestroyed()) {
    try {
      library.webContents.send("library-changed", await snapshot());
    } catch {}
  }
}
async function flushReader(window, id, publication, force = false) {
  if (window.isDestroyed()) return;
  const serialized = await window.webContents.executeJavaScript(
    force
      ? "JSON.stringify(window.StillleafReader?.exportState?.() ?? null)"
      : "window.__stillleafHostTakeState()",
  );
  if (!serialized) return;
  if (typeof serialized !== "string" || serialized.length > 2 * 1024 * 1024)
    throw Error("Reader state exceeds save budget");
  const state = JSON.parse(serialized);
  if (state) await saveReaderState(root, id, publication, state);
}
async function closeReader(window) {
  if (!window || window.isDestroyed()) return true;
  if (window.stillleafClosePromise) return window.stillleafClosePromise;
  return await window.stillleafSaveAndClose();
}
// Caller already owns readerActions, also used by imports/removals and journal writes.
// The reader remains open. Only saved state is exported, after its ordinary draft guard.
async function withArchiveSnapshot(work) {
  const window = activeReader, id = activeEdition;
  let originalInert, originalReady;
  archiveBusy = true;
  try {
    if (window && !window.isDestroyed()) {
      const okay = await window.webContents.executeJavaScript("window.StillleafReader?.prepareClose ? window.StillleafReader.prepareClose() : true");
      if (!okay) return { cancelled: true };
      originalInert = await window.webContents.executeJavaScript("(()=>{const before=document.documentElement.inert;document.documentElement.inert=true;return before;})()");
      originalReady = window.stillleafReady;
      window.stillleafReady = false;
      readingSessions?.sample();
      if (trackingError) throw Error("Resolve the reading-time save error before exporting an archive.");
      const {publication} = await readEdition(root,id);
      await flushReader(window,id,publication,true);
    }
    return await work();
  } finally {
    if (window && !window.isDestroyed() && originalInert !== undefined) {
      await window.webContents.executeJavaScript("document.documentElement.inert="+JSON.stringify(originalInert)).catch(()=>{});
      window.stillleafReady = originalReady;
      readingSessions?.sample();
    }
    archiveBusy = false;
  }
}
async function archiveAction(input) {
  if (!input || typeof input !== "object" || Array.isArray(input) || Object.keys(input).some(key=>!["action","id"].includes(key))) throw Error("Invalid archive request.");
  if (input.action === "list") return libraryArchive.listPreserved();
  if (input.action === "export" || input.action === "export-preserved") {
    if(input.action === "export-preserved" && (typeof input.id !== "string" || !/^[a-f0-9]{64}$/.test(input.id))) throw Error("Invalid recovery archive identity.");
    const target = await dialog.showSaveDialog(library,{title:input.action === "export"?"Export complete Library archive":"Export recovery archive",defaultPath:path.join(app.getPath("documents"),"Stillleaf-library-"+new Date().toISOString().slice(0,10)+".zip"),filters:[{name:"Stillleaf Library archive",extensions:["zip"]}]});
    if(target.canceled||!target.filePath)return{cancelled:true};
    if(input.action === "export-preserved")return{exported:true,...await libraryArchive.exportPreserved(input.id,target.filePath)};
    return withArchiveSnapshot(async()=>({exported:true,...await libraryArchive.exportTo(target.filePath)}));
  }
  if(input.action === "preserve") {
    const source=await dialog.showOpenDialog(library,{title:"Preserve a Library archive for recovery",properties:["openFile"],filters:[{name:"Stillleaf Library archive",extensions:["zip"]}]});
    if(source.canceled||source.filePaths.length!==1)return{cancelled:true};
    const {token,summary}=await libraryArchive.preview(source.filePaths[0]);
    const choice=await dialog.showMessageBox(library,{type:"question",title:"Preserve recovery archive",message:"Keep this archive for recovery?",detail:`This archive contains ${summary.journals} source journals, ${summary.readerStates} reader snapshots, ${summary.epubs} EPUBs and ${summary.covers} covers. ${summary.missingEPUBs} reader snapshots have no EPUB included.\n\nThis preserves an unchanged recovery copy. It does not restore books into your Library, replace notes, or add reading time. History from another host is retained without conversion. You can export the recovery copy later.`,buttons:["Preserve for recovery","Cancel"],defaultId:1,cancelId:1,noLink:true});
    if(choice.response!==0)return{cancelled:true};
    archiveBusy=true;
    try{return await libraryArchive.preserve(token);}finally{archiveBusy=false;}
  }
  throw Error("Unknown archive action.");
}
async function connectReader(window, id, publication) {
  await window.webContents.executeJavaScript(
    `(()=>{let pending=null,close=false;window.addEventListener('stillleaf-reader-event',event=>{if(event.target!==window||event.detail?.editionId!==${JSON.stringify(id)})return;if(event.detail.type==='state'){const text=JSON.stringify(event.detail.state);if(text.length<=2097152)pending=text;}if(event.detail.type==='close-request')close=true;});Object.defineProperty(window,'__stillleafHostTakeState',{value:()=>{const value=pending;pending=null;return value;}});Object.defineProperty(window,'__stillleafHostCloseRequested',{value:()=>{const value=close;close=false;return value;}});})()`,
  );
  let closing = false,
    saving = false;
  const report = async (error) => {
    if (!window.isDestroyed())
      await window.webContents
        .executeJavaScript(
          '(()=>{const target=document.querySelector("#error")||document.querySelector("#status");if(target){target.hidden=false;target.textContent=' +
            JSON.stringify("Could not save reading state: " + error.message) +
            ";}})()",
        )
        .catch(() => {});
  };
  const timer = setInterval(async () => {
    if (saving || closing || window.isDestroyed()) return;
    saving = true;
    try {
      await flushReader(window, id, publication);
      if (
        await window.webContents.executeJavaScript(
          "window.__stillleafHostCloseRequested()",
        )
      )
        if (await closeReader(window)) present();
    } catch (error) {
      await report(error);
    } finally {
      saving = false;
    }
  }, 250);
  window.stillleafSaveAndClose = () => {
    if (window.stillleafClosePromise) return window.stillleafClosePromise;
    window.stillleafClosePromise = (async () => {
      try {
        const mayClose = await window.webContents.executeJavaScript(
          "window.StillleafReader?.prepareClose ? window.StillleafReader.prepareClose() : true",
        );
        if (!mayClose) {
          window.stillleafClosePromise = null;
          quitting = false;
          return false;
        }
        await flushReader(window, id, publication, true);
        closing = true;
        clearInterval(timer);
        window.close();
        return true;
      } catch (error) {
        window.stillleafClosePromise = null;
        quitting = false;
        await report(error);
        throw error;
      }
    })();
    return window.stillleafClosePromise;
  };
  window.on("close", (event) => {
    if (archiveBusy) { event.preventDefault(); return; }
    if (!closing) {
      event.preventDefault();
      void window.stillleafSaveAndClose().catch(() => {});
    }
  });
  window.on("closed", () => {
    clearInterval(timer);
    if (activeReader === window) {
      activeReader = undefined;
      activeEdition = undefined;
      readingSessions?.sample();
    }
  });
}
function enqueue(files) {
  if (coordinator) void coordinator.enqueue(files);
  else pending.push(...files);
}
app.on("open-file", (event, file) => {
  event.preventDefault();
  enqueue([file]);
});
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on("second-instance", (_event, argv) => {
    const files = epubArguments(argv);
    if (files.length) enqueue(files);
    else present();
  });
  enqueue(epubArguments(process.argv));
  app
    .whenReady()
    .then(async () => {
      journal = new JournalStore(
        path.join(path.dirname(root), "journal.sqlite"),
      );
      libraryArchive = new LibraryArchive({ root, journal });
      if (!test) {
        readingSessions = new ReaderSessionHost({
          journal,
          powerMonitor,
          getReader: () => {
            const window = activeReader;
            if (!window || window.isDestroyed()) return null;
            return {
              bookId: window.stillleafBookId,
              ready: window.stillleafReady === true,
              focused: window.isFocused() && window.isVisible(),
              minimized: window.isMinimized(),
              destroyed: false,
            };
          },
          onChanged: () => {
            trackingError = null;
            if (coordinator) return changed();
          },
          onError: (error) => {
            trackingError = "Reading time is paused: " + error.message;
            if (coordinator) void changed().catch(() => {});
          },
        });
        readingSessions.start();
      }
      importer = await import(
        pathToFileURL(
          path.join(__dirname, "../../packages/publication/index.js"),
        ).href
      );
      const bundledAssets = new Map();
      const dist = path.resolve(
        (test && process.env.STILLLEAF_READER_DIST) ||
          path.join(__dirname, "../reader/dist"),
      );
      async function collect(directory, relative = "") {
        for (const item of await fs.readdir(directory, {
          withFileTypes: true,
        })) {
          const name = relative + item.name;
          if (item.isDirectory())
            await collect(path.join(directory, item.name), name + "/");
          else if (item.isFile()) {
            const mime = {
              ".html": "text/html",
              ".js": "text/javascript",
              ".css": "text/css",
            }[path.extname(name)];
            if (mime)
              bundledAssets.set(
                "stillleaf-app://reader/" +
                  name.split("/").map(encodeURIComponent).join("/"),
                {
                  bytes: await fs.readFile(path.join(directory, item.name)),
                  mime,
                },
              );
          }
        }
      }
      await collect(dist);
      // Publication files are named per reader window (`book/<uuid>/<index>`)
      // and read from disk on request, so a URL is only valid while the window
      // it was issued to is the active reader. Library covers resolve through
      // the latest snapshot's map.
      const servedFile = (url) =>
        activeReader?.stillleafFiles?.get(url) ?? covers.get(url);
      protocol.handle("stillleaf-app", async (request) => {
        if (request.method !== "GET")
          return new Response("Not found", { status: 404 });
        const asset = bundledAssets.get(request.url);
        if (asset)
          return new Response(asset.bytes, {
            headers: { "Content-Type": asset.mime },
          });
        const file = servedFile(request.url);
        try {
          const stat = file && (await fs.lstat(file.file));
          // The reader compares the declared size, so a changed file is still served.
          if (!stat?.isFile() || stat.size > 32 * 1024 * 1024)
            return new Response("Not found", { status: 404 });
          return new Response(await fs.readFile(file.file), {
            headers: {
              "Content-Type": file.type,
              // Editions are content-addressed, so a cover URL never changes bytes.
              ...(covers.has(request.url) && {
                "Cache-Control": "max-age=31536000, immutable",
              }),
            },
          });
        } catch {
          return new Response("Not found", { status: 404 });
        }
      });
      const network = session.defaultSession;
      network.setPermissionRequestHandler((_wc, _permission, callback) =>
        callback(false),
      );
      network.setPermissionCheckHandler(() => false);
      const readerAssetRoot = pathToFileURL(
        path.join(__dirname, "../reader/dist/"),
      ).href;
      const shellRoot = pathToFileURL(__dirname + path.sep).href;
      network.webRequest.onBeforeRequest((details, callback) => {
        let allowed = false;
        try {
          const url = new URL(details.url);
          allowed =
            bundledAssets.has(url.href) ||
            Boolean(servedFile(url.href)) ||
            ["blob:", "data:", "devtools:"].includes(url.protocol) ||
            (url.protocol === "file:" &&
              !url.search &&
              !url.hash &&
              (url.href.startsWith(readerAssetRoot) ||
                url.href.startsWith(shellRoot)));
        } catch {}
        callback({ cancel: !allowed });
      });
      coordinator = new ImportCoordinator({
        importFile: async (file) => {
          const previous = readerActions;
          let release;
          readerActions = new Promise((resolve) => (release = resolve));
          await previous;
          try {
            const outcome = await importer.importEPUB(file, root, {});
            journal.attachEdition({
              editionId: outcome.editionId,
              title: outcome.publication.title || "Untitled",
              creators: outcome.publication.creators || [],
              recordedAt: new Date().toISOString(),
            });
            return {
              status: outcome.status,
              publication: {
                editionId: outcome.editionId,
                title: outcome.publication.title,
              },
            };
          } finally {
            release();
          }
        },
        presentLibrary: present,
        changed,
      });
      ipcMain.handle("library", async (event, action, input) => {
        if (
          event.sender !== library?.webContents ||
          event.senderFrame !== event.sender.mainFrame ||
          event.senderFrame.url !== libraryURL
        )
          throw Error("Untrusted library sender");
        let release;
        if (
          ["read", "remove", "exportReaderState", "importReaderState", "journal", "archive"].includes(
            action,
          )
        ) {
          const previous = readerActions;
          readerActions = new Promise((resolve) => (release = resolve));
          await previous;
        }
        try {
          if (quitting && action !== "snapshot") return { cancelled: true };
          if (action === "snapshot") return snapshot();
          if (action === "archive") return await archiveAction(input);
          if (action === "journal") {
            if (
              !input ||
              typeof input !== "object" ||
              Array.isArray(input) ||
              Object.keys(input).some(
                (key) => !["action", "input"].includes(key),
              )
            )
              throw Error("Invalid journal request");
            const result = journalAction(input.action, input.input);
            await changed();
            return result;
          }
          if (action === "pick") {
            const result = await dialog.showOpenDialog(library, {
              title: "Add EPUBs to Library",
              properties: ["openFile", "multiSelections"],
              filters: [{ name: "EPUB books", extensions: ["epub"] }],
            });
            if (!result.canceled) enqueue(result.filePaths);
            return { cancelled: result.canceled };
          }
          if (action === "drop") {
            if (
              !Array.isArray(input) ||
              input.length > 1000 ||
              input.some((x) => typeof x !== "string" || !path.isAbsolute(x))
            )
              throw Error("Invalid dropped files");
            enqueue(input);
            return { accepted: true };
          }
          if (action === "cancel") {
            coordinator.cancelPending();
            return { cancelled: true };
          }
          if (
            action === "exportReaderState" ||
            action === "importReaderState"
          ) {
            if (typeof input !== "string" || !/^[a-f0-9]{64}$/.test(input))
              throw Error("Invalid edition identity");
            const { publication } = await readEdition(root, input);
            if (action === "exportReaderState") {
              const target = await dialog.showSaveDialog(library, {
                title: "Export notes and reading settings",
                defaultPath: path.join(
                  app.getPath("documents"),
                  (publication.title || "Book").replace(/[<>:\"/\\|?*]/g, "_") +
                    "-reading-state.json",
                ),
                filters: [
                  { name: "Notes and reading settings", extensions: ["json"] },
                ],
              });
              if (target.canceled || !target.filePath)
                return { cancelled: true };
              if (activeEdition === input && !(await closeReader(activeReader)))
                return { cancelled: true };
              const exported = await readerStateTransfer.exportState(
                root,
                input,
                publication,
                target.filePath,
              );
              return { exported: true, bytes: exported.bytes };
            }
            const source = await dialog.showOpenDialog(library, {
              title: "Import notes and reading settings",
              properties: ["openFile"],
              filters: [
                { name: "Notes and reading settings", extensions: ["json"] },
              ],
            });
            if (source.canceled || source.filePaths.length !== 1)
              return { cancelled: true };
            if (activeEdition === input && !(await closeReader(activeReader)))
              return { cancelled: true };
            const preview = await readerStateTransfer.previewImport(
              root,
              input,
              publication,
              source.filePaths[0],
            );
            if (preview.disposition === "stale")
              throw Error(
                "These reading settings are older than the saved state. Nothing was imported.",
              );
            if (preview.disposition === "identical")
              return { imported: false, identical: true };
            const replacing = preview.disposition === "replacement";
            const choice = await dialog.showMessageBox(library, {
              type: "question",
              title: "Import notes and reading settings",
              message:
                (replacing
                  ? "Replace saved reading state for "
                  : "Import reading state for ") +
                (publication.title || "this book") +
                "?",
              detail: `Incoming: ${preview.incomingBookmarks} bookmarks and ${preview.incomingAnnotations} highlights/notes (revision ${preview.incomingRevision}).\nSaved: ${preview.localBookmarks} bookmarks and ${preview.localAnnotations} highlights/notes (revision ${preview.localRevision ?? "none"}).\n\nReading position and settings are included. Existing notes are replaced, not merged. This file contains one edition's reading state, not the EPUB or your reading journal.`,
              buttons: [
                replacing
                  ? "Replace saved reading state"
                  : "Import reading state",
                "Cancel",
              ],
              defaultId: 1,
              cancelId: 1,
              noLink: true,
            });
            if (choice.response !== 0) return { cancelled: true };
            const imported = await readerStateTransfer.applyImport(preview, {
              replacingExisting: replacing,
            });
            return { imported };
          }
          if (action === "remove") {
            const { publication } = await readEdition(root, input);
            const choice = await dialog.showMessageBox(library, {
              type: "question",
              title: "Remove from Library",
              message:
                "Remove " +
                (publication.title || "this book") +
                " from Library?",
              detail:
                "Keep an EPUB copy saves a usable file outside Stillleaf before moving the managed EPUB and extracted reading files to Trash. Move to Trash removes only those app-managed files. Your original imported file is never deleted. Reading position, bookmarks, highlights, notes and retained journal metadata stay on this computer.",
              buttons: [
                "Keep an EPUB copy…",
                "Move managed files to Trash",
                "Cancel",
              ],
              defaultId: 2,
              cancelId: 2,
              noLink: true,
            });
            if (choice.response === 2) return { cancelled: true };
            let keepAt = null;
            if (choice.response === 0) {
              const target = await dialog.showSaveDialog(library, {
                title: "Keep an EPUB copy",
                defaultPath: path.join(
                  app.getPath("documents"),
                  (publication.title || "Book").replace(/[<>:"/\\|?*]/g, "_") +
                    ".epub",
                ),
                filters: [{ name: "EPUB book", extensions: ["epub"] }],
              });
              if (target.canceled || !target.filePath)
                return { cancelled: true };
              keepAt = target.filePath;
            }
            if (choice.response !== 0 && choice.response !== 1)
              return { cancelled: true };
            if (activeEdition === input && !(await closeReader(activeReader)))
              return { cancelled: true };
            const result = await removeAssets(root, input, {
              keepAt,
              trashItem: (file) => shell.trashItem(file),
            });
            await changed();
            return result;
          }
          if (action === "read") {
            const { publication } = await readEdition(root, input);
            if (!(await closeReader(activeReader))) return { cancelled: true };
            const files = new Map(),
              token = randomUUID();
            const data = await readerInput(root, input, {
              serve: ({ file, type }, index) => {
                const url = `stillleaf-app://reader/book/${token}/${index}`;
                if (bundledAssets.has(url))
                  throw Error("Reader asset collides with a book resource");
                // Header-safe type; the reader decides from the manifest type.
                files.set(url, {
                  file,
                  type:
                    typeof type === "string" &&
                    type.length < 128 &&
                    /^[!-~]+\/[!-~]+$/.test(type)
                      ? type
                      : "application/octet-stream",
                });
                return url;
              },
            });
            const window = new BrowserWindow({
              width: 1080,
              height: 820,
              minWidth: 600,
              minHeight: 500,
              show: !test,
              backgroundColor: "#f5f4ed",
              webPreferences: {
                sandbox: true,
                contextIsolation: true,
                nodeIntegration: false,
                backgroundThrottling: false,
              },
            });
            window.stillleafFiles = files;
            activeReader = window;
            activeEdition = input;
            window.stillleafBookId = journal
              .listBooks()
              .find((book) => book.editionIds.includes(input))?.book_id;
            window.stillleafReady = false;
            for (const name of [
              "focus",
              "blur",
              "minimize",
              "restore",
              "hide",
              "show",
            ])
              window.on(name, () => readingSessions?.sample());
            window.webContents.on("render-process-gone", () => {
              window.stillleafReady = false;
              readingSessions?.sample();
            });
            secure(window, readerURL);
            window.setMenuBarVisibility(false);
            try {
              await window.loadURL(readerURL);
              await connectReader(window, input, publication);
              await window.webContents.executeJavaScript(
                "window.StillleafReader.open(" +
                  JSON.stringify({ ...data, canReturnToLibrary: true }) +
                  ")",
              );
              window.stillleafReady = true;
              readingSessions?.sample();
              return { opened: true };
            } catch (error) {
              window.destroy();
              throw error;
            }
          }
          throw Error("Unknown library action");
        } catch (error) {
          return { error: error.message };
        } finally {
          release?.();
        }
      });
      createLibrary();
      await coordinator.enqueue(pending.splice(0));
      await coordinator.setReady();
      await changed();
    })
    .catch((error) => {
      console.error(error);
      app.quit();
    });
  app.on("activate", () => {
    if (coordinator) present();
  });
  app.on("window-all-closed", () => app.quit());
  app.on("will-quit", () => {
    try {
      readingSessions?.dispose();
    } catch {
    } finally {
      try {
        journal?.close();
      } catch {}
    }
  });
}
