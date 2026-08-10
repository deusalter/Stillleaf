import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { _electron } from "playwright";
import { epub, zip } from "../../packages/publication/test/fixtures.js";
import { importEPUB } from "../../packages/publication/index.js";
const require = createRequire(import.meta.url);
const { readerInput } = require("../src/library-store.cjs");
const project = path.resolve(import.meta.dirname, "..");

test("gated continuous adapter persists through the hidden Electron host", async t => {
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "stillleaf-continuous-host-"));
  let app;
  t.after(async () => { await app?.close(); await fs.rm(temporary, { recursive: true, force: true }); });
  const data = path.join(temporary, "data"), root = path.join(data, "library");
  const chapter = n => `<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Chapter ${n}</h1>${Array.from({length: 24}, (_, i) => `<p id="p${i}">Chapter ${n}, passage ${i}. Rain settled on the leaves beside the open window. The reader turned back to the quiet garden and continued reading.</p>`).join("")}</body></html>`;
  const entries = epub({ extra: [{ name: "EPUB/two.xhtml", data: chapter(2) }], opfTransform: text => text.replace("</manifest>", '<item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest>').replace("</spine>", '<itemref idref="two"/></spine>') });
  entries.find(entry => entry.name === "EPUB/chapter.xhtml").data = chapter(1);
  const source = path.join(temporary, "book.epub"); await fs.writeFile(source, zip(entries));
  const imported = await importEPUB(source, root);
  app = await _electron.launch({ executablePath: require("electron"), args: [project], env: {...process.env, STILLLEAF_TEST_DATA: data} });
  const library = await app.firstWindow(); await library.locator(".book").waitFor();
  assert.equal(await app.evaluate(({BrowserWindow}) => BrowserWindow.getAllWindows().some(window => window.isVisible())), false);
  async function openGated() {
    await library.getByRole("button", { name: "Read", exact: true }).click();
    await library.waitForFunction(() => !document.querySelector(".book button").disabled);
    const reader = (await app.windows()).find(window => window !== library);
    await reader.waitForFunction(() => [...document.querySelectorAll('iframe')].some(frame => frame.contentDocument?.body?.textContent.includes('Chapter')));
    const input = await readerInput(root, imported.editionId);
    await reader.evaluate(async input => {
      input.state = window.StillleafReader.exportState();
      await window.StillleafReader.open({...input, experimentalContinuous: true, canReturnToLibrary: true});
      await window.StillleafReader.setPreferences({scroll: true, fontSize: 1.5});
    }, input);
    await reader.waitForFunction(() => document.querySelectorAll('.continuous-chapter-frame').length === 2);
    return reader;
  }
  let reader = await openGated();
  const boundary = await reader.evaluate(async () => {
    const container = document.querySelector('#reader'), first = document.querySelector('.continuous-chapter');
    container.scrollTop = first.offsetHeight - container.clientHeight / 2;
    await new Promise(resolve => setTimeout(resolve, 250));
    const viewport = container.getBoundingClientRect();
    const frames = [...container.querySelectorAll('iframe')];
    const tail = frames[0].getBoundingClientRect().top + frames[0].contentDocument.querySelector('p:last-of-type').getBoundingClientRect().bottom;
    const heading = frames[1].getBoundingClientRect().top + frames[1].contentDocument.querySelector('h1').getBoundingClientRect().top;
    return {textVisible: tail > viewport.top && tail < viewport.bottom && heading > viewport.top && heading < viewport.bottom, frames: frames.map(frame => {
      const bounds = frame.getBoundingClientRect(), doc = frame.contentDocument;
      return {visible: bounds.bottom > viewport.top && bounds.top < viewport.bottom, overflow: doc.scrollingElement.scrollHeight - frame.clientHeight};
    })};
  });
  assert.equal(boundary.frames.filter(frame => frame.visible).length, 2);
  assert.equal(boundary.textVisible, true, 'actual ending prose and next heading must be visible together');
  assert.ok(boundary.frames.every(frame => frame.overflow <= 1));
  await reader.evaluate(() => {
    window.StillleafReader.addBookmark();
    window.StillleafReader.annotate({locator: window.StillleafReader.bookmark(), quote: 'Synthetic continuous passage', note: 'Host saved across continuous close', color: 'gold'});
  });
  const saved = await reader.evaluate(() => window.StillleafReader.exportState());
  const closed = reader.waitForEvent('close');
  await reader.getByRole('button', {name: 'Library', exact: true}).click();
  await closed;
  const reopened = await readerInput(root, imported.editionId);
  assert.deepEqual(reopened.state.annotations, saved.annotations);
  assert.deepEqual(reopened.state.bookmarks, saved.bookmarks);
  assert.equal(reopened.state.preferences.scroll, true);
  reader = await openGated();
  const restored = await reader.evaluate(() => window.StillleafReader.exportState());
  assert.deepEqual(restored.annotations, saved.annotations);
  assert.deepEqual(restored.bookmarks, saved.bookmarks);
  const snapshot = await library.evaluate(() => window.stillleafLibrary.snapshot());
  assert.equal(snapshot.automaticEntries.length, 0, 'synthetic host never credits reader layout');
  assert.equal(await app.evaluate(({BrowserWindow}) => BrowserWindow.getAllWindows().some(window => window.isVisible())), false);
});
