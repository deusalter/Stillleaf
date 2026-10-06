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
    // One evaluate, so the pixels, the frame state and the breathing class describe the same moment.
    const {pixels, animating, ticks, frozen, cells, breathing} = await page.evaluate(() => {
      const canvas = document.getElementById('garden'), data = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
      let pixels = 0;
      for (let i = 3; i < data.length; i += 4) if (data[i]) pixels++;
      const {animating, ticks, frozen, cells} = window.StillleafReader.gardenDebug();
      return {pixels, animating, ticks, frozen, cells: cells.length, breathing: canvas.classList.contains('breathing')};
    });
    samples.push({pixels, animating, ticks, breathing});
    if ((!animating && !frozen && cells > 0) || Date.now() > end) return samples;
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

test('a Still garden repaints at once when reading moves, without waiting for an animation frame', {timeout: 60000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900}, {reducedMotion: 'no-preference', gardenMode: 'still'});
  await readTo(page, 0.2);
  const results = [];
  for (const progression of [0.6, 0.35, 0.8]) {
    // Sample in the same task that applies the new position, before any frame could run.
    results.push(await page.evaluate(target => new Promise(resolve => {
      const api = window.StillleafReader, start = api.gardenDebug().progress;
      api.go({href: 'one.html', type: 'text/html', locations: {progression: target}});
      const poll = () => {
        const garden = api.gardenDebug();
        if (Math.abs(garden.progress - start) > 0.1) resolve({animating: garden.animating, cells: garden.cells.length});
        else setTimeout(poll, 0);
      };
      poll();
    }), progression));
  }
  assert.ok(results.every(r => r.cells > 0), `a Still garden lost its vines: ${JSON.stringify(results)}`);
  assert.ok(results.every(r => !r.animating), `a Still garden waited for animation frames: ${JSON.stringify(results)}`);
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

test('scrolling an Off garden never freezes it or schedules a frame', {timeout: 60000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900}, {reducedMotion: 'no-preference', gardenMode: 'off'});
  await readTo(page, 0.3);
  // Sample just after the 300 ms freeze would end, before the next animation frame could run.
  const state = await page.evaluate(() => new Promise(resolve => {
    window.dispatchEvent(new WheelEvent('wheel', {deltaY: 1}));
    const frozen = window.StillleafReader.gardenDebug().frozen;
    setTimeout(() => resolve({frozen, animating: window.StillleafReader.gardenDebug().animating}), 301);
  }));
  assert.equal(state.frozen, false, 'an Off garden froze on scroll input');
  assert.equal(state.animating, false, 'an Off garden scheduled a frame after scroll input');
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

// ---- The page as a card on a backdrop, the footer vine and the mockup's garden density ----

const rgb = hex => `rgb(${[1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16)).join(', ')})`;
const luminance = css => {
  const [r, g, b] = css.match(/\d+/g).slice(0, 3).map(v => v / 255).map(v => v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
const ratio = (a, b) => { const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };

/** The page card: the viewport grown by the card's vertical sliver, with its painted colour, radius and shadow. */
const card = page => page.evaluate(() => {
  const viewport = document.getElementById('reading-viewport'), r = viewport.getBoundingClientRect(), s = getComputedStyle(viewport, '::before');
  const dy = (parseFloat(s.height) - r.height) / 2, dx = (parseFloat(s.width) - r.width) / 2;
  return {left: r.left - dx, right: r.right + dx, top: r.top - dy, bottom: r.bottom + dy, background: s.backgroundColor, radius: parseFloat(s.borderTopLeftRadius), shadow: s.boxShadow, content: s.content,
    backdrop: getComputedStyle(document.documentElement).backgroundColor, paper: getComputedStyle(document.documentElement).getPropertyValue('--paper').trim()};
});
const rectOf = (page, selector) => page.evaluate(selector => { const e = document.querySelector(selector); if (!e) return null; const r = e.getBoundingClientRect(); return {left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width, height: r.height}; }, selector);
const waitForGarden = async (page, progression) => { await readTo(page, progression); await page.waitForFunction(() => window.StillleafReader.gardenDebug().on); await page.waitForTimeout(300); };
const nativeChrome = page => page.evaluate(() => window.StillleafReader.nativeControl({version: 1, editionId: 'margin-garden', id: 1, command: 'activate'}));

test('the page is a raised card on a tinted backdrop in every theme, light and dark', {timeout: 120000}, async t => {
  const {page, errors} = await launch(t, {width: 1400, height: 900});
  await waitForGarden(page, 0.5);
  const themes = [['paper'], ['sepia'], ['white'], ['original'], ['dark'], ['midnight'], ['night'], ['custom', {backgroundColor: '#efe4cf', textColor: '#2a2118'}], ['custom', {backgroundColor: '#101820', textColor: '#e8eef5'}]];
  for (const [theme, extra] of themes) {
    await page.evaluate(p => window.StillleafReader.setPreferences(p), {theme, ...extra});
    await page.waitForTimeout(500);
    const c = await card(page), garden = await page.evaluate(() => window.StillleafReader.gardenDebug());
    const label = `${theme} ${JSON.stringify(extra ?? {})}`;
    assert.equal(garden.card, true, `${label}: no card`);
    assert.equal(c.background, rgb(c.paper), `${label}: the card is not the page colour`);
    assert.notEqual(c.backdrop, c.background, `${label}: the backdrop equals the card`);
    assert.ok(ratio(c.backdrop, c.background) >= 1.1, `${label}: the card edge would not read (${ratio(c.backdrop, c.background).toFixed(3)})`);
    assert.ok(c.radius >= 6, `${label}: the card has no soft corners`);
    assert.notEqual(c.shadow, 'none', `${label}: the card has no shadow`);
    // Near vines hold 3:1 against the backdrop they grow on.
    for (const color of [...garden.palette.stems, ...garden.palette.leaves]) assert.ok(ratio(color.length === 7 ? rgb(color) : color, c.backdrop) >= 3, `${label}: ${color} on ${c.backdrop}`);
  }
  assert.deepEqual(errors, []);
});

test('the card holds the whole text frame, never meets the vines or the footer, and the page geometry is the same with or without it', {timeout: 90000}, async t => {
  const {page, errors} = await launch(t, {width: 1400, height: 900});
  await nativeChrome(page);
  await waitForGarden(page, 0.6);
  const c = await card(page), viewport = await viewportRect(page), garden = await page.evaluate(() => window.StillleafReader.gardenDebug());
  assert.ok(c.left <= viewport.left + 0.5 && c.right >= viewport.right - 0.5 && c.top < viewport.top && c.bottom > viewport.bottom, 'the card does not hold the viewport');
  for (const frame of await page.evaluate(() => [...document.querySelectorAll('#reader iframe')].map(f => { const r = f.getBoundingClientRect(); return {left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width}; })).then(all => all.filter(r => r.width > 0))) {
    assert.ok(frame.left >= c.left - 1 && frame.right <= c.right + 1 && frame.top >= c.top - 1 && frame.bottom <= c.bottom + 1, `text frame outside the card: ${JSON.stringify(frame)}`);
  }
  for (const cell of garden.cells) assert.ok(!overlaps(cell, c), `vine inside the card at ${JSON.stringify(cell)}`);
  const pill = await rectOf(page, '.footer-pill');
  assert.ok(c.bottom <= pill.top, `the card runs into the footer pill (${c.bottom} against ${pill.top})`);
  assert.ok(c.top >= 0, 'the card starts above the window');
  for (const selector of ['.footer-pill', '.footer-navigation']) {
    const rect = await rectOf(page, selector);
    if (rect?.width) for (const cell of garden.cells) assert.ok(!overlaps(cell, rect), `vine over ${selector}`);
  }
  // The same page without vines: identical viewport, text frames and footer height.
  const snapshot = () => page.evaluate(() => ({viewport: JSON.stringify(document.getElementById('reading-viewport').getBoundingClientRect()), reader: JSON.stringify(document.getElementById('reader').getBoundingClientRect()),
    frames: JSON.stringify([...document.querySelectorAll('#reader iframe')].map(f => f.getBoundingClientRect())), footer: document.querySelector('.reading-footer').getBoundingClientRect().height,
    position: document.getElementById('position-label').textContent}));
  const withVines = await snapshot();
  await page.evaluate(() => window.StillleafReader.setPreferences({vines: 'off'}));
  await page.waitForTimeout(500);
  assert.deepEqual(await snapshot(), withVines, 'the card, backdrop or footer pill moved the page');
  assert.deepEqual(errors, []);
});

test('with vines off the page is the flat full-bleed page it was', {timeout: 60000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900});
  await waitForGarden(page, 0.5);
  await page.evaluate(() => window.StillleafReader.setPreferences({vines: 'off'}));
  await page.waitForTimeout(500);
  const flat = await page.evaluate(() => {
    const root = document.documentElement, vp = document.getElementById('reading-viewport');
    return {classes: [...root.classList], background: getComputedStyle(root).backgroundColor, paper: getComputedStyle(root).getPropertyValue('--paper').trim(), card: getComputedStyle(vp, '::before').content,
      pill: getComputedStyle(document.querySelector('.footer-pill')).display, percent: getComputedStyle(document.getElementById('footer-percent')).display, vine: getComputedStyle(document.querySelector('.footer-vine')).display};
  });
  assert.ok(!flat.classes.includes('garden-card') && !flat.classes.includes('garden-on'), `garden classes left behind: ${flat.classes}`);
  assert.equal(flat.background, rgb(flat.paper));
  assert.equal(flat.card, 'none');
  assert.equal(flat.pill, 'contents');
  assert.equal(flat.percent, 'none');
  assert.equal(flat.vine, 'none');
});

test('every chapter starts as a young garden and fills out to the full garden by its end', {timeout: 90000}, async t => {
  const {page, errors} = await launch(t, {width: 1400, height: 900});
  const counts = [];
  // (go() to exactly 0 from the end of a chapter does not move the reader, so the start is 0.01.)
  for (const progression of [0.01, 0.5, 1]) { await waitForGarden(page, progression); counts.push((await page.evaluate(() => window.StillleafReader.gardenDebug())).cells.length); }
  assert.ok(counts[0] >= 150, `page 1 is nearly bare: ${counts[0]} cells`);
  assert.ok(counts[0] < counts[1] && counts[1] < counts[2], `the garden did not fill out with reading: ${counts}`);
  assert.ok(counts[2] >= counts[0] * 1.8, `the end of the chapter is not clearly fuller than the start: ${counts}`);
  // The same chapter grows the same garden: going back to the start gives the start garden again
  // (give or take the cells the Return button keeps clear once the reader has jumped).
  await waitForGarden(page, 0.01);
  const again = (await page.evaluate(() => window.StillleafReader.gardenDebug())).cells.length;
  assert.ok(Math.abs(again - counts[0]) <= counts[0] * 0.1, `the start of the chapter grew ${again} cells the second time, ${counts[0]} the first`);
  assert.deepEqual(errors, []);
});

test('vines climb the margins from the bottom corners up most of the window, on both sides', {timeout: 60000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900});
  await waitForGarden(page, 1);
  const {cells} = await page.evaluate(() => window.StillleafReader.gardenDebug());
  for (const [name, side] of [['left', cells.filter(c => c.right <= 700)], ['right', cells.filter(c => c.left >= 700)]]) {
    assert.ok(side.length > 100, `${name} margin has ${side.length} cells`);
    assert.ok(Math.min(...side.map(c => c.top)) < 900 * 0.35, `${name} vines only reach y=${Math.min(...side.map(c => c.top))}`);
    assert.ok(Math.max(...side.map(c => c.bottom)) > 900 - 40, `${name} vines do not root at the bottom`);
  }
});

test('the footer is a pill with the page, a vine along a dotted track and the percentage, and the vine tracks reading', {timeout: 120000}, async t => {
  const {page, errors} = await launch(t, {width: 1400, height: 900});
  await nativeChrome(page);
  const reaches = [];
  for (const progression of [0.1, 0.5, 0.9]) {
    await waitForGarden(page, progression);
    // The footer labels settle ("Calculating book pages…" first), and the vine regrows to the room they leave.
    await page.waitForFunction(() => window.StillleafReader.gardenDebug().footTrack.length > 20, null, {timeout: 8000});
    await page.waitForTimeout(400);
    const garden = await page.evaluate(() => window.StillleafReader.gardenDebug());
    const stems = garden.foot.filter(cell => cell.kind === 'stem'), left = Math.min(...garden.footTrack.map(r => r.left)), right = Math.max(...garden.footTrack.map(r => r.right));
    assert.ok(garden.footTrack.length > 10, 'the footer vine has no dotted track');
    const reach = (Math.max(...stems.map(cell => cell.right)) - left) / (right - left);
    assert.ok(Math.abs(reach - garden.progress) < 0.12, `the vine reaches ${reach.toFixed(2)} of its track at progress ${garden.progress.toFixed(2)}`);
    reaches.push(reach);
    assert.equal(await page.locator('#footer-percent').textContent(), `${Math.round(garden.progress * 100)}%`);
    const pill = await rectOf(page, '.footer-pill'), c = await card(page);
    for (const cell of garden.foot) assert.ok(cell.left >= pill.left && cell.right <= pill.right && cell.top >= pill.top - 2 && cell.bottom <= pill.bottom + 2, `footer vine cell outside the pill: ${JSON.stringify(cell)}`);
    assert.ok(Math.abs((pill.left + pill.right) / 2 - (c.left + c.right) / 2) < 40, 'the pill is not under the card');
    assert.ok(pill.width <= c.right - c.left + 4, 'the pill is wider than the card');
    assert.ok(await page.locator('.footer-pill #position-label').isVisible());
  }
  assert.ok(reaches[0] < reaches[1] && reaches[1] < reaches[2], `the footer vine did not grow with reading: ${reaches}`);
  assert.deepEqual(errors, []);
});

test('focus reading hides the footer and its vine, and bringing it back regrows the vine', {timeout: 90000}, async t => {
  const {page, errors} = await launch(t, {width: 1400, height: 900});
  await waitForGarden(page, 0.5);
  assert.ok((await page.evaluate(() => window.StillleafReader.gardenDebug())).foot.length > 3);
  await page.evaluate(() => window.StillleafReader.setPreferences({immersive: true}));
  await page.waitForTimeout(600);
  assert.equal(await page.locator('.reading-footer').isVisible(), false);
  assert.equal((await page.evaluate(() => window.StillleafReader.gardenDebug())).foot.length, 0, 'a hidden footer kept a vine');
  const c = await card(page), garden = await page.evaluate(() => window.StillleafReader.gardenDebug());
  assert.equal(garden.card, true, 'focus reading lost the card');
  for (const cell of garden.cells) assert.ok(!overlaps(cell, c), 'vine inside the card in focus reading');
  await page.evaluate(() => window.StillleafReader.setPreferences({immersive: false}));
  await page.waitForFunction(() => window.StillleafReader.gardenDebug().foot.length > 3, null, {timeout: 5000});
  assert.deepEqual(errors, []);
});

test('facing pages sit on one card with a fold, one spine vine in the gap and a footer vine', {timeout: 90000}, async t => {
  const {page, errors} = await launch(t, {width: 1800, height: 900});
  await page.evaluate(() => window.StillleafReader.setPreferences({columns: 'two'}));
  await waitForGarden(page, 0.5);
  const garden = await page.evaluate(() => window.StillleafReader.gardenDebug()), c = await card(page);
  assert.equal(garden.card, true);
  assert.ok(await page.evaluate(() => document.documentElement.classList.contains('garden-facing')));
  assert.notEqual(await page.evaluate(() => getComputedStyle(document.getElementById('reading-viewport'), '::after').content), 'none', 'no fold in the gap');
  assert.ok(garden.spine.length > 5 && garden.foot.length > 3);
  assert.ok(garden.cells.length > 50, 'the outer margins hold no garden');
  for (const cell of garden.cells) assert.ok(!overlaps(cell, c), 'vine inside the facing card');
  const center = (c.left + c.right) / 2;
  for (const cell of garden.spine) assert.ok(cell.left >= center - garden.gutter && cell.right <= center + garden.gutter, 'spine cell outside the gap');
  assert.deepEqual(errors, []);
});

test('continuous scroll reads as a card column with the garden fixed beside it', {timeout: 90000}, async t => {
  const {page, errors} = await launch(t, {width: 1400, height: 900});
  await page.evaluate(() => window.StillleafReader.setPreferences({scroll: true}));
  await waitForGarden(page, 0.4);
  const garden = await page.evaluate(() => window.StillleafReader.gardenDebug()), c = await card(page);
  assert.equal(garden.card, true);
  assert.equal(await page.evaluate(() => document.documentElement.classList.contains('garden-facing')), false);
  assert.ok(garden.cells.length > 100 && garden.foot.length > 3);
  for (const cell of garden.cells) assert.ok(!overlaps(cell, c), 'vine inside the scroll card');
  assert.deepEqual(errors, []);
});

test('a window too narrow for margins keeps the page edge to edge, with no card and no margin vines', {timeout: 60000}, async t => {
  const {page, errors} = await launch(t, {width: 700, height: 700});
  await page.evaluate(() => window.StillleafReader.setPreferences({measure: 120, contentWidth: 100, margins: 'narrow'}));
  await waitForGarden(page, 0.5);
  const garden = await page.evaluate(() => window.StillleafReader.gardenDebug());
  assert.equal(garden.card, false);
  assert.equal(garden.cells.length, 0);
  const root = await page.evaluate(() => ({background: getComputedStyle(document.documentElement).backgroundColor, paper: getComputedStyle(document.documentElement).getPropertyValue('--paper').trim()}));
  assert.equal(root.background, rgb(root.paper));
  assert.equal(await page.evaluate(() => getComputedStyle(document.getElementById('reading-viewport'), '::before').content), 'none');
  assert.ok(garden.foot.length > 2, 'the footer vine goes with the garden, whatever the window size');
  assert.deepEqual(errors, []);
});

test('growing the garden stays cheap: each growth frame costs a few milliseconds of drawing, and the frames stop when it settles', {timeout: 90000}, async t => {
  const {page} = await launch(t, {width: 1400, height: 900}, animated);
  await waitForGarden(page, 0.1);
  const before = await debug(page);
  await page.evaluate(() => window.StillleafReader.go({href: 'one.html', type: 'text/html', locations: {progression: 0.95}}));
  await page.waitForFunction(() => window.StillleafReader.gardenDebug().progress > 0.8);
  // The garden fades in over a few seconds; measure the drawing itself with performance.now(), which the frame rate of a busy machine cannot blur.
  await page.waitForFunction(() => { const g = window.StillleafReader.gardenDebug(); return !g.animating && !g.frozen && g.cells.length > 400; }, null, {timeout: 20000, polling: 250});
  const after = await debug(page);
  const frames = after.ticks - before.ticks, average = (after.drawMs - before.drawMs) / frames;
  assert.ok(frames > 10, `the regrow drew only ${frames} frames`);
  assert.ok(average < 10, `a growth frame took ${average.toFixed(1)} ms of drawing on average (${frames} frames, ${after.cells.length} cells)`);
  assert.ok(after.slowestDraw < 60, `one frame took ${after.slowestDraw.toFixed(0)} ms to draw`);
  const settled = after.ticks;
  await page.waitForTimeout(700);
  assert.equal((await debug(page)).ticks, settled, 'frames kept drawing after the garden settled');
});
