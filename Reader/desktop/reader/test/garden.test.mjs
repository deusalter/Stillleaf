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

async function launch(t, viewport, {reducedMotion = 'reduce', gardenMode} = {}) {
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
  // The app injects its Garden setting at document start, before any reader script runs.
  if (gardenMode) await page.addInitScript(mode => { window.__stillleafGardenMode = mode; }, gardenMode);
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

test('scrolling over the margins scrolls the book the same with or without vines, and freezes the garden', {timeout: 60000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900});
  await page.evaluate(() => window.StillleafReader.setPreferences({scroll: true}));
  await readTo(page, 0.3);
  const progression = () => page.evaluate(() => window.StillleafReader.bookmark()?.locations?.progression ?? null);
  const scrolled = async x => {
    const start = await progression();
    await page.mouse.move(x, 450);
    for (let i = 0; i < 5; i++) await page.mouse.wheel(0, 200);
    const frozen = await page.evaluate(() => window.StillleafReader.gardenDebug().frozen);
    await page.waitForTimeout(500);
    return {delta: (await progression()) - start, frozen};
  };
  const pageX = 700, marginX = 60;
  const overPage = await scrolled(pageX);
  assert.equal(overPage.frozen, true, 'the garden kept animating during the wheel burst');
  assert.ok(overPage.delta > 0.02, `wheeling over the page did not scroll the book (moved ${overPage.delta})`);
  assert.equal(await page.evaluate(() => window.StillleafReader.gardenDebug().frozen), false, 'the garden stayed frozen after scrolling stopped');
  const overMargin = await scrolled(marginX);
  assert.equal(overMargin.frozen, true);
  await page.evaluate(() => window.StillleafReader.setPreferences({vines: 'off'}));
  await page.waitForTimeout(300);
  const pageWithoutVines = await scrolled(pageX);
  assert.ok(pageWithoutVines.delta > 0.02, `wheeling over the page without vines did not scroll the book (moved ${pageWithoutVines.delta})`);
  assert.ok(Math.abs(overPage.delta - pageWithoutVines.delta) < 0.01, `vines changed how far a wheel burst scrolls: ${overPage.delta} against ${pageWithoutVines.delta}`);
  const marginWithoutVines = await scrolled(marginX);
  assert.ok(Math.abs(overMargin.delta - marginWithoutVines.delta) < 0.001, `vines changed how the margin reacts to the wheel: ${overMargin.delta} against ${marginWithoutVines.delta}`);
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
  // Keep input arriving for the whole change, so a slow layout can't outlast the freeze.
  const during = await page.evaluate(async () => {
    const nudge = () => window.dispatchEvent(new WheelEvent('wheel', {deltaY: 1}));
    nudge();
    const input = setInterval(nudge, 100);
    try {
      await window.StillleafReader.setPreferences({contentWidth: 45, measure: 40});
      await new Promise(resolve => setTimeout(resolve, 160));
      const debug = window.StillleafReader.gardenDebug();
      return {frozen: debug.frozen, cells: JSON.stringify(debug.cells)};
    } finally { clearInterval(input); }
  });
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

test('a reader started in Off never plants a garden, even before the app sends a mode', {timeout: 60000}, async t => {
  const {page, errors} = await launch(t, {width: 1400, height: 900}, {reducedMotion: 'no-preference', gardenMode: 'off'});
  await readTo(page, 0.5);
  const garden = await page.evaluate(() => window.StillleafReader.gardenDebug());
  assert.equal(garden.mode, 'off');
  assert.equal(garden.cells.length, 0, 'an Off garden planted vines while waiting for the app');
  assert.equal(garden.animating, false);
  assert.deepEqual(await painted(page), [0, 0]);
  assert.deepEqual(errors, []);
});

test('a reader started Still paints its first frame fully grown, with no fade-in', {timeout: 60000}, async t => {
  const {page, errors} = await launch(t, {width: 1400, height: 900}, {reducedMotion: 'no-preference', gardenMode: 'still'});
  await readTo(page, 0.5);
  const garden = await page.evaluate(() => window.StillleafReader.gardenDebug());
  assert.equal(garden.mode, 'still');
  assert.ok(garden.cells.length > 100);
  assert.equal(garden.animating, false, 'a Still garden faded in');
  assert.equal(await page.evaluate(() => document.getElementById('garden').classList.contains('breathing')), false);
  assert.ok((await painted(page))[0] > 0, 'the first frame was blank');
  assert.deepEqual(errors, []);
});

const animated = {reducedMotion: 'no-preference'};
const debug = async page => {
  const garden = await page.evaluate(() => window.StillleafReader.gardenDebug());
  assert.equal(typeof garden.ticks, 'number', 'gardenDebug() does not count frames');
  assert.equal(typeof garden.ghosts, 'number', 'gardenDebug() does not count ghosts');
  return garden;
};
/** Samples the margin canvas until the garden is planted, unfrozen and no longer animating (or the deadline passes). */
async function watchGrowth(page, deadline = 12000) {
  const samples = [];
  const end = Date.now() + deadline;
  for (;;) {
    const [pixels] = await painted(page), {animating, ticks, frozen, cells} = await debug(page);
    const breathing = await page.evaluate(() => document.getElementById('garden').classList.contains('breathing'));
    samples.push({pixels, animating, ticks, breathing});
    if ((!animating && !frozen && cells.length > 0) || Date.now() > end) return samples;
    await page.waitForTimeout(200);
  }
}

test('an animated garden fades its vines in one after another, not all at once', {timeout: 60000}, async t => {
  const {page, errors} = await launch(t, {width: 1400, height: 900}, animated);
  await page.evaluate(() => window.StillleafReader.go({href: 'one.html', type: 'text/html', locations: {progression: 0.3}}));
  await page.waitForFunction(() => window.StillleafReader.gardenDebug().progress > 0.2);
  const samples = await watchGrowth(page);
  const counts = samples.map(s => s.pixels);
  assert.equal(samples.at(-1).animating, false, 'the garden never finished growing');
  assert.ok(counts.at(-1) > counts[0] * 1.5, `growth was not gradual: ${counts.join(', ')}`);
  assert.ok(new Set(counts).size >= 4, `the garden appeared in too few steps: ${counts.join(', ')}`);
  assert.ok(samples.slice(0, -1).every(s => !s.breathing), 'the garden breathed while it was still growing');
  assert.deepEqual(errors, []);
});

test('a settled animated garden breathes in CSS and draws no more frames', {timeout: 60000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900}, animated);
  await page.evaluate(() => window.StillleafReader.go({href: 'one.html', type: 'text/html', locations: {progression: 0.2}}));
  await page.waitForFunction(() => window.StillleafReader.gardenDebug().progress > 0.1);
  const settled = (await watchGrowth(page)).at(-1);
  assert.equal(settled.animating, false);
  assert.equal(settled.breathing, true, 'a grown garden did not start breathing');
  assert.notEqual(await page.locator('#garden').evaluate(e => getComputedStyle(e).animationName), 'none');
  const before = (await debug(page)).ticks;
  await page.waitForTimeout(800);
  const after = await debug(page);
  assert.equal(after.ticks, before, 'frames kept drawing after the garden settled');
  assert.equal(after.animating, false);
});

test('a garden that loses cells fades them out as ghosts, then stops drawing', {timeout: 60000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900}, animated);
  await page.evaluate(() => window.StillleafReader.go({href: 'one.html', type: 'text/html', locations: {progression: 0.4}}));
  await page.waitForFunction(() => window.StillleafReader.gardenDebug().progress > 0.3);
  await watchGrowth(page);
  await page.evaluate(() => window.StillleafReader.go({href: 'one.html', type: 'text/html', locations: {progression: 0.05}}));
  await page.waitForFunction(() => window.StillleafReader.gardenDebug().progress < 0.1);
  await page.waitForFunction(() => window.StillleafReader.gardenDebug().ghosts > 0, null, {timeout: 3000});
  const settled = (await watchGrowth(page)).at(-1);
  assert.equal(settled.animating, false);
  assert.equal((await debug(page)).ghosts, 0, 'ghosts outlived their fade');
});

test('a Still garden that loses cells drops them at once, with no fading ghosts', {timeout: 60000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900}, {reducedMotion: 'no-preference', gardenMode: 'still'});
  await page.evaluate(() => window.StillleafReader.go({href: 'one.html', type: 'text/html', locations: {progression: 0.4}}));
  await page.waitForFunction(() => window.StillleafReader.gardenDebug().progress > 0.3);
  await page.waitForTimeout(400);
  const before = (await debug(page)).cells.length;
  await page.evaluate(() => window.StillleafReader.go({href: 'one.html', type: 'text/html', locations: {progression: 0.05}}));
  await page.waitForFunction(() => window.StillleafReader.gardenDebug().progress < 0.1);
  const after = await debug(page);
  assert.ok(after.cells.length < before, 'going back did not shrink the garden, so nothing was removed');
  assert.equal(after.ghosts, 0, 'a Still garden kept fading ghosts');
  await page.waitForTimeout(100);
  assert.equal((await debug(page)).animating, false, 'a Still garden kept drawing frames');
});

test('an Off garden never schedules a frame', {timeout: 60000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900}, {...animated, gardenMode: 'off'});
  await readTo(page, 0.5);
  await page.setViewportSize({width: 1300, height: 850});
  await page.waitForTimeout(600);
  const garden = await debug(page);
  assert.equal(garden.ticks, 0, 'an Off garden drew frames');
  assert.equal(garden.animating, false);
  assert.equal(await page.evaluate(() => document.getElementById('garden').classList.contains('breathing')), false);
});

test('switching a live garden to Off stops its frames and blanks both canvases', {timeout: 60000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900}, animated);
  await page.evaluate(() => window.StillleafReader.go({href: 'one.html', type: 'text/html', locations: {progression: 0.3}}));
  await page.waitForFunction(() => window.StillleafReader.gardenDebug().progress > 0.2);
  await page.waitForTimeout(500);
  assert.ok((await debug(page)).animating, 'the garden was not mid-growth when switched off');
  await page.evaluate(() => window.StillleafReader.setGardenMode('off'));
  const ticks = (await debug(page)).ticks;
  await page.waitForTimeout(600);
  const garden = await debug(page);
  assert.equal(garden.ticks, ticks, 'frames kept drawing after Off');
  assert.equal(garden.animating, false);
  assert.equal(garden.cells.length, 0);
  assert.deepEqual(await painted(page), [0, 0]);
});

test('the spine vine paints above the live page but below the sliding page snapshots', {timeout: 60000}, async t => {
  const {page, errors} = await launch(t, {width: 1500, height: 900});
  await page.evaluate(() => window.StillleafReader.setPreferences({columns: 'two'}));
  await readTo(page, 0.5);
  const topmost = await page.evaluate(() => {
    const viewport = document.getElementById('reading-viewport'), spine = document.getElementById('garden-spine');
    const box = viewport.getBoundingClientRect(), x = box.left + box.width / 2, y = box.top + box.height / 2;
    // pointer-events:none layers are skipped by hit testing; turn them on so elementFromPoint reports paint order.
    const probe = document.createElement('style');
    probe.textContent = '#garden-spine,.reader-page-slide,.reader-page-slide *{pointer-events:auto!important}';
    document.head.append(probe);
    const name = el => el === spine ? 'spine' : el.closest('.reader-page-slide') ? 'slide' : el.closest('#reader') ? 'page' : el.id || el.tagName;
    const resting = name(document.elementFromPoint(x, y));
    // The same stage page-slide.js raises over the live page while a turn animates (minus inert, which also skips hit testing).
    const stage = document.createElement('div');
    stage.className = 'reader-page-slide';
    viewport.append(stage);
    const sliding = name(document.elementFromPoint(x, y));
    stage.remove(); probe.remove();
    return {resting, sliding};
  });
  assert.equal(topmost.resting, 'spine', 'the spine vine is hidden behind the live page');
  assert.equal(topmost.sliding, 'slide', 'the spine vine draws over the sliding page snapshots');
  assert.deepEqual(errors, []);
});
