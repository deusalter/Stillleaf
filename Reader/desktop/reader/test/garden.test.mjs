import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium, webkit} from 'playwright';

const root = path.resolve(import.meta.dirname, '../dist');
const chapter = (n) => `<html><body><h1>Chapter ${n}</h1>` + '<p>The light fell across the open book. She turned a page and settled into her chair by the window, where the garden was.</p>'.repeat(140) + '</body></html>';
const book = {editionId: 'margin-garden', title: 'Margins', contentProgress: true,
  readingOrder: [{href: 'one.html', type: 'text/html'}, {href: 'two.html', type: 'text/html'}],
  resources: [{href: 'one.html', type: 'text/html', dataBase64: Buffer.from(chapter(1)).toString('base64')},
    {href: 'two.html', type: 'text/html', dataBase64: Buffer.from(chapter(2)).toString('base64')}]};

async function launch(t, viewport, {reducedMotion = 'reduce'} = {}) {
  const server = createServer(async (req, res) => {
    try {
      const file = path.resolve(root, '.' + new URL(req.url, 'http://localhost').pathname);
      if (!file.startsWith(root + path.sep)) throw Error();
      res.setHeader('Content-Type', {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css'}[path.extname(file)] ?? 'application/octet-stream');
      res.end(await readFile(file));
    } catch { res.writeHead(404).end(); }
  });
  t.after(() => { server.closeAllConnections(); server.close(); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = process.env.READER_TEST_BROWSER === 'webkit' ? await webkit.launch()
    : await chromium.launch({executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true});
  t.after(() => browser.close());
  const page = await browser.newPage({viewport, reducedMotion});
  const errors = [];
  page.on('pageerror', error => errors.push(String(error)));
  await page.addInitScript(() => { window.__stillleafGardenDebug = true; });
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  await page.evaluate(input => window.StillleafReader.open(input), book);
  return {page, errors};
}

/** Moves to a chapter position and waits for the garden to settle on it. */
async function readTo(page, progression) {
  await page.evaluate(p => window.StillleafReader.go({href: 'one.html', type: 'text/html', locations: {progression: p}}), progression);
  await page.waitForFunction(p => Math.abs(window.StillleafReader.gardenDebug().progress - p) < 0.2, progression);
  await page.waitForTimeout(400);
}

/** Painted (non-transparent) pixels on the margin canvas and the spine canvas. */
const painted = page => page.evaluate(() => ['garden', 'garden-spine'].map(id => {
  const canvas = document.getElementById(id), data = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
  let count = 0;
  for (let i = 3; i < data.length; i += 4) if (data[i]) count++;
  return count;
}));

const overlaps = (a, b) => a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
const viewportRect = page => page.evaluate(() => { const r = document.getElementById('reading-viewport').getBoundingClientRect(); return {left: r.left, right: r.right, top: r.top, bottom: r.bottom}; });

test('margin vines grow beside the page and never over it', {timeout: 60000}, async t => {
  const {page, errors} = await launch(t, {width: 1400, height: 900});
  await readTo(page, 0.6);
  const garden = await page.evaluate(() => window.StillleafReader.gardenDebug());
  assert.ok(garden.cells.length > 100, `only ${garden.cells.length} cells at 60% of a chapter`);
  const viewport = await viewportRect(page);
  for (const cell of garden.cells) assert.ok(!overlaps(cell, viewport), `vine over the page at ${JSON.stringify(cell)}`);
  assert.equal(await page.locator('#garden').getAttribute('aria-hidden'), 'true');
  assert.equal(await page.locator('#garden').evaluate(e => getComputedStyle(e).pointerEvents), 'none');
  assert.deepEqual(errors, []);
});

test('facing pages grow a spine vine inside the column gap', {timeout: 60000}, async t => {
  const {page, errors} = await launch(t, {width: 1500, height: 900});
  await page.evaluate(() => window.StillleafReader.setPreferences({columns: 'two'}));
  await readTo(page, 0.5);
  const garden = await page.evaluate(() => window.StillleafReader.gardenDebug());
  assert.ok(garden.spine.length > 5, `spine has ${garden.spine.length} cells`);
  const viewport = await viewportRect(page);
  const center = (viewport.left + viewport.right) / 2;
  for (const cell of garden.spine) assert.ok(cell.left >= center - garden.gutter && cell.right <= center + garden.gutter, `spine cell outside the gap: ${JSON.stringify(cell)}`);
  assert.deepEqual(errors, []);
});

test('a window without usable margins grows no garden', {timeout: 60000}, async t => {
  const {page, errors} = await launch(t, {width: 900, height: 700});
  await page.evaluate(() => window.StillleafReader.setPreferences({measure: 120, contentWidth: 100, margins: 'narrow'}));
  await readTo(page, 0.7);
  const garden = await page.evaluate(() => window.StillleafReader.gardenDebug());
  assert.equal(garden.cells.length, 0);
  assert.deepEqual(errors, []);
});

test('widening the margins regrows the garden into the freed space without moving the page vertically', {timeout: 60000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900});
  await readTo(page, 0.6);
  const before = await viewportRect(page);
  const top = await page.evaluate(() => document.getElementById('reader').getBoundingClientRect().top);
  await page.evaluate(() => window.StillleafReader.setPreferences({contentWidth: 45, measure: 40}));
  await page.waitForTimeout(900);
  const after = await viewportRect(page);
  assert.ok(after.left > before.left + 40, 'the page did not narrow');
  // The progress budget caps how many vines exist; wider margins mean they spread into the freed space.
  const garden = await page.evaluate(() => window.StillleafReader.gardenDebug());
  const freed = garden.cells.filter(c => (c.left >= before.left && c.right <= after.left) || (c.left >= after.right && c.right <= before.right));
  assert.ok(freed.length > 10, `only ${freed.length} vine cells moved into the freed margin`);
  for (const cell of garden.cells) assert.ok(!overlaps(cell, after), 'vine over the narrowed page');
  assert.equal(await page.evaluate(() => document.getElementById('reader').getBoundingClientRect().top), top);
});

test('scrolling over the margins behaves the same with or without vines, and freezes the garden', {timeout: 60000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900});
  await page.evaluate(() => window.StillleafReader.setPreferences({scroll: true}));
  await readTo(page, 0.3);
  const scrolled = async () => {
    const start = await page.evaluate(() => JSON.stringify(window.StillleafReader.bookmark()?.locations ?? {}));
    await page.mouse.move(60, 450);
    for (let i = 0; i < 5; i++) await page.mouse.wheel(0, 200);
    const frozen = await page.evaluate(() => window.StillleafReader.gardenDebug().frozen);
    await page.waitForTimeout(500);
    const end = await page.evaluate(() => JSON.stringify(window.StillleafReader.bookmark()?.locations ?? {}));
    return {moved: start !== end, frozen};
  };
  const withVines = await scrolled();
  assert.equal(withVines.frozen, true, 'the garden kept animating during the wheel burst');
  assert.equal(await page.evaluate(() => window.StillleafReader.gardenDebug().frozen), false, 'the garden stayed frozen after scrolling stopped');
  await page.evaluate(() => window.StillleafReader.setPreferences({vines: 'off'}));
  await page.waitForTimeout(300);
  const withoutVines = await scrolled();
  assert.equal(withVines.moved, withoutVines.moved, 'vines changed how wheel input over the margin behaves');
});

test('turning vines off clears the garden and stops drawing', {timeout: 60000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900});
  await readTo(page, 0.6);
  await page.evaluate(() => window.StillleafReader.setPreferences({vines: 'off'}));
  await page.waitForTimeout(300);
  const garden = await page.evaluate(() => window.StillleafReader.gardenDebug());
  assert.equal(garden.cells.length, 0);
  assert.equal(garden.animating, false);
  assert.equal(await page.evaluate(() => window.StillleafReader.exportState().preferences.vines), 'off');
});

test('changing appearance while the garden is frozen keeps the old garden until input stops', {timeout: 60000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900});
  await readTo(page, 0.6);
  const before = await page.evaluate(() => JSON.stringify(window.StillleafReader.gardenDebug().cells));
  await page.mouse.move(60, 450);
  await page.mouse.wheel(0, 40);
  await page.evaluate(() => window.StillleafReader.setPreferences({contentWidth: 45, measure: 40}));
  await page.waitForTimeout(160);
  const during = await page.evaluate(() => ({frozen: window.StillleafReader.gardenDebug().frozen, cells: JSON.stringify(window.StillleafReader.gardenDebug().cells)}));
  assert.equal(during.frozen, true);
  assert.equal(during.cells, before, 'the garden was replaced (and blanked) while input was still arriving');
  await page.waitForTimeout(900);
  const after = await page.evaluate(() => JSON.stringify(window.StillleafReader.gardenDebug().cells));
  assert.notEqual(after, before, 'the garden never regrew for the new margins');
});

test('closing the reader wipes both canvases and plants nothing new', {timeout: 60000}, async t => {
  const {page, errors} = await launch(t, {width: 1400, height: 900}, {reducedMotion: 'no-preference'});
  await readTo(page, 0.15);
  await page.waitForTimeout(1500);
  const [margin] = await painted(page);
  assert.ok(margin > 0, 'the garden never painted before the close');
  await page.evaluate(() => window.StillleafReader.close());
  // Ghosts last 900ms; a leftover frame or a replanted garden would still show after that.
  await page.waitForTimeout(1500);
  assert.deepEqual(await painted(page), [0, 0], 'faded cells or ghosts stayed painted after close');
  const garden = await page.evaluate(() => window.StillleafReader.gardenDebug());
  assert.equal(garden.cells.length, 0, 'closing planted a garden for a book that is gone');
  assert.equal(garden.spine.length, 0);
  assert.equal(garden.animating, false, 'a frame stayed scheduled after close');
  assert.deepEqual(errors, []);
});
