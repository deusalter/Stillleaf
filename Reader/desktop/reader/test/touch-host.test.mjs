// A touch host (the iPhone and iPad app) draws its own controls over the page and its readers select text with the
// system's handles. This checks the renderer's side of that: the hand-held bands, the page number making room for the
// host's toolbar, a selection found without any pointer event, and the tap that clears a selection not turning the page.
// TOUCH_HOST_BROWSER=chromium switches engine; WebKit is the default because it is what the app runs.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import {serve, launchBrowser, openReader, settle} from './surface-support.mjs';

const root = path.resolve(import.meta.dirname, '../dist');
const rect = (page, selector) => page.evaluate(s => { const r = document.querySelector(s).getBoundingClientRect(); return {left: r.left, right: r.right, top: r.top, bottom: r.bottom}; }, selector);

test('touch host: bands, page number beside the toolbar, handle selections and deselecting taps', async () => {
  const server = await serve(root), browser = await launchBrowser(process.env.TOUCH_HOST_BROWSER ?? 'webkit');
  try {
    const {page, errors, editionId} = await openReader(browser, server.url, {width: 393, height: 759, preferences: {scroll: false, columns: 'one', fontSize: 1}});
    let id = 1;
    const control = (command, payload) => page.evaluate(request => window.StillleafReader.nativeControl(request), {version: 1, editionId, id: ++id, command, ...(payload ? {payload} : {})});
    const policy = controlsVisible => control('policy', {touch: true, fullScreen: true, controlsVisible});
    await policy(false);
    await settle(page, 600);

    // The text keeps the same bands whether or not the controls show.
    const viewport = await rect(page, '#reading-viewport');
    assert.deepEqual([viewport.top, 759 - viewport.bottom], [56, 50]);
    const centred = await rect(page, '#page-number');
    assert.ok(Math.abs((centred.left + centred.right) / 2 - 393 / 2) < 2, 'the page number is centred while reading');
    await policy(true);
    const aside = await rect(page, '#page-number');
    assert.equal(aside.left, 24, 'the page number moves to the leading side under the controls');
    assert.ok(aside.right < 393 / 2 - 40, 'and leaves the trailing half of the band to the host toolbar');
    assert.deepEqual(await rect(page, '#reading-viewport'), viewport, 'showing the controls moves no text');
    await policy(false);

    // A selection made with the system's handles arrives as selectionchange alone.
    const lowest = await page.evaluate(() => {
      const frame = [...document.querySelectorAll('#reader iframe')].find(f => getComputedStyle(f).visibility !== 'hidden');
      const doc = frame.contentDocument, host = frame.getBoundingClientRect();
      const paragraph = [...doc.querySelectorAll('p')].find(p => { const r = p.getBoundingClientRect(); return host.left + r.left >= 0 && host.left + r.right <= innerWidth && host.top + r.top > 150 && host.top + r.bottom < innerHeight - 250; });
      const range = doc.createRange(); range.setStart(paragraph.firstChild, 4); range.setEnd(paragraph.firstChild, 120);
      const selection = frame.contentWindow.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      return host.top + Math.max(...[...range.getClientRects()].map(r => r.bottom));
    });
    await page.locator('#selection-tools').waitFor({state: 'visible'});
    const popup = await rect(page, '#selection-tools');
    assert.ok(popup.top >= lowest + 20, `the colours sit under the whole selection (${popup.top} against ${lowest}), leaving the place above it to the system menu`);
    assert.ok(popup.bottom - popup.top >= 44, 'and are tall enough for a finger');

    // The tap that clears a selection is not a page turn; the next one is.
    const place = () => page.evaluate(() => JSON.stringify(window.StillleafReader.exportState().position?.locations ?? null));
    const before = await place();
    await page.mouse.click(380, 640);
    await page.waitForTimeout(450);
    assert.equal(await page.locator('#selection-tools').isVisible(), false);
    assert.equal(await place(), before, 'the deselecting tap at the page edge turned no page');
    await page.waitForTimeout(300);
    await page.mouse.click(380, 640);
    await page.waitForFunction(was => JSON.stringify(window.StillleafReader.exportState().position?.locations ?? null) !== was, before, {timeout: 5000});
    assert.deepEqual(errors, []);
  } finally { await browser.close(); server.close(); }
});

test('touch host: facing pages only on its side, and selections found in a chapter Readium preloaded', async () => {
  const server = await serve(root), browser = await launchBrowser(process.env.TOUCH_HOST_BROWSER ?? 'webkit');
  try {
    // An upright 13-inch iPad is wider than the 960 px a window needs for facing pages, but shows one page.
    for (const [width, height, facing] of [[1032, 1322, false], [1376, 988, true]]) {
      const {page, errors, editionId} = await openReader(browser, server.url, {width, height, preferences: {scroll: false, columns: 'two'}});
      let id = 1;
      const control = (command, payload) => page.evaluate(request => window.StillleafReader.nativeControl(request), {version: 1, editionId, id: ++id, command, ...(payload ? {payload} : {})});
      await settle(page, 600);
      const before = await page.evaluate(() => document.querySelector('#reader iframe').getBoundingClientRect().width);
      await control('policy', {touch: true, fullScreen: true, controlsVisible: false});
      await settle(page, 600);
      const after = await page.evaluate(() => [...document.querySelectorAll('#reader iframe')].find(f => getComputedStyle(f).visibility !== 'hidden').getBoundingClientRect().width);
      if (facing) assert.ok(after > width * 0.8, `on its side the spread keeps the width (${after} of ${width})`);
      else assert.ok(after < before * 0.8 && after < width * 0.7, `upright, learning the host is hand-held narrows the spread to one page (${before} to ${after})`);

      // Move into the second chapter, which Readium had preloaded, and select there as the handles would.
      const outline = await control('panel', {name: 'outline'});
      await control('go', {kind: 'outline', id: outline.panel.rows[1].id});
      await page.waitForFunction(() => window.StillleafReader.exportState().position?.href === 'c2.html');
      await page.waitForTimeout(700);
      const selected = await page.evaluate(() => {
        const frame = [...document.querySelectorAll('#reader iframe')].find(f => getComputedStyle(f).visibility !== 'hidden');
        const doc = frame.contentDocument, host = frame.getBoundingClientRect(), view = document.getElementById('reader').getBoundingClientRect();
        const paragraph = [...doc.querySelectorAll('p')].find(p => { const r = p.getBoundingClientRect(); return host.left + r.left >= view.left && host.left + r.right <= view.right && host.top + r.top > 150 && host.top + r.bottom < innerHeight - 280; });
        if (!paragraph) return false;
        const range = doc.createRange(); range.setStart(paragraph.firstChild, 4); range.setEnd(paragraph.firstChild, 90);
        const selection = frame.contentWindow.getSelection(); selection.removeAllRanges(); selection.addRange(range);
        return true;
      });
      assert.ok(selected, 'a paragraph of the second chapter is on the page');
      await page.locator('#selection-tools').waitFor({state: 'visible', timeout: 5000});
      assert.deepEqual(errors, []);
      await page.context().close();
    }
  } finally { await browser.close(); server.close(); }
});
