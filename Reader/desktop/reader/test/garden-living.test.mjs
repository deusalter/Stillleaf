import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium, webkit} from 'playwright';

// The Living garden in a real engine: its frame budget, what it repaints, and when it holds still.
// Every test runs in headless Chromium and headless WebKit, whatever READER_TEST_BROWSER says.
const root = path.resolve(import.meta.dirname, '../dist');
const chapter = n => `<html><body><h1>Chapter ${n}</h1>` + '<p>The light fell across the open book. She turned a page and settled into her chair by the window, where the garden was.</p>'.repeat(140) + '</body></html>';
const book = {editionId: 'living-garden', title: 'Living', contentProgress: true,
  readingOrder: [{href: 'one.html', type: 'text/html'}, {href: 'two.html', type: 'text/html'}],
  resources: [{href: 'one.html', type: 'text/html', dataBase64: Buffer.from(chapter(1)).toString('base64')},
    {href: 'two.html', type: 'text/html', dataBase64: Buffer.from(chapter(2)).toString('base64')}]};

async function launch(t, engine, {reducedMotion = 'no-preference', gardenMode, pace, viewport = {width: 1400, height: 900}} = {}) {
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
  const browser = engine === 'webkit' ? await webkit.launch() : await chromium.launch({headless: true, ...(process.env.CHROME_PATH ? {executablePath: process.env.CHROME_PATH} : {})});
  t.after(() => browser.close());
  const page = await browser.newPage({viewport, reducedMotion});
  const errors = [];
  page.on('pageerror', error => errors.push(String(error)));
  await page.addInitScript(() => { window.__stillleafGardenDebug = true; });
  if (gardenMode) await page.addInitScript(mode => { window.__stillleafGardenMode = mode; }, gardenMode);
  if (pace) await page.addInitScript(value => { window.__stillleafGardenPace = value; }, pace);
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  await page.evaluate(input => window.StillleafReader.open(input), book);
  return {page, errors};
}

const debug = page => page.evaluate(() => window.StillleafReader.gardenDebug());
const ambient = async page => (await debug(page)).ambient;
/** Reads to a chapter position and waits until the garden has grown in and its ambient loop is the only thing still running. */
async function settle(page, progression = 0.4) {
  await page.evaluate(p => window.StillleafReader.go({href: 'one.html', type: 'text/html', locations: {progression: p}}), progression);
  await page.waitForFunction(p => { const g = window.StillleafReader.gardenDebug(); return Math.abs(g.progress - p) < 0.2 && !g.animating && !g.frozen && g.cells.length > 100; }, progression, {timeout: 30000});
  await page.waitForTimeout(300);
}
const hide = (page, hidden) => page.evaluate(value => {
  Object.defineProperty(document, 'hidden', {configurable: true, get: () => value});
  Object.defineProperty(document, 'visibilityState', {configurable: true, get: () => value ? 'hidden' : 'visible'});
  document.dispatchEvent(new Event('visibilitychange'));
}, hidden);
const canvasAlphaInside = (page, rect) => page.evaluate(({left, top, right, bottom}) => {
  const canvas = document.getElementById('garden'), dpr = canvas.width / innerWidth;
  const data = canvas.getContext('2d').getImageData(Math.ceil(left * dpr), Math.ceil(top * dpr), Math.floor((right - left) * dpr), Math.floor((bottom - top) * dpr)).data;
  let count = 0;
  for (let i = 3; i < data.length; i += 4) if (data[i]) count++;
  return count;
}, rect);
const pageRect = page => page.evaluate(() => { const r = document.getElementById('reading-viewport').getBoundingClientRect(); return {left: r.left, right: r.right, top: r.top, bottom: r.bottom}; });

for (const engine of ['chromium', 'webkit']) {
  test(`[${engine}] a settled garden keeps moving, at a capped frame rate and a small frame cost`, {timeout: 120000}, async t => {
    const {page, errors} = await launch(t, engine);
    await settle(page);
    const before = await ambient(page);
    await page.waitForTimeout(4000);
    const after = await ambient(page), frames = after.frames - before.frames;
    // 15 frames a second at most: a 4 s window holds about 60 frames, never 240.
    assert.ok(frames >= 8, `a settled Living garden drew only ${frames} frames in 4 s`);
    assert.ok(frames <= 4 * 15 + 3, `the ambient loop ran at ${(frames / 4).toFixed(1)} fps, above its 15 fps cap`);
    assert.ok(after.shortestGap >= 55, `two frames ran ${after.shortestGap.toFixed(0)} ms apart`);
    const average = (after.drawMs - before.drawMs) / frames;
    console.log(`# ${engine}: ${frames} frames in 4 s, ${average.toFixed(2)} ms per frame on average, slowest ${after.slowestMs.toFixed(1)} ms, repaints ${(100 * after.meanDirtyShare).toFixed(1)}% of the canvas (peak ${(100 * after.peakDirtyShare).toFixed(1)}%)`);
    assert.ok(average < 6, `an ambient frame took ${average.toFixed(2)} ms of drawing on average`);
    assert.ok(after.slowestMs < 40, `one ambient frame took ${after.slowestMs.toFixed(1)} ms`);
    assert.deepEqual(errors, []);
  });

  test(`[${engine}] each frame repaints only what changed, never the whole canvas`, {timeout: 120000}, async t => {
    const {page} = await launch(t, engine);
    await settle(page);
    await page.waitForTimeout(4000);
    const full = (await debug(page)).ticks, a = await ambient(page);
    assert.ok(a.frames > 10);
    assert.ok(a.peakDirtyShare < 0.35, `a frame repainted ${(100 * a.peakDirtyShare).toFixed(0)}% of the canvas`);
    assert.ok(a.meanDirtyShare < 0.12, `frames repainted ${(100 * a.meanDirtyShare).toFixed(0)}% of the canvas on average`);
    // The ambient loop never falls back to the full redraw that growth and regrowth use.
    assert.equal((await debug(page)).ticks, full);
    await page.waitForTimeout(1500);
    const later = await debug(page);
    assert.equal(later.ticks, full, 'the ambient loop redrew the whole garden');
    assert.ok(later.ambient.frames > a.frames);
  });

  test(`[${engine}] wind flutters the leaves while the page stays clear`, {timeout: 120000}, async t => {
    const {page} = await launch(t, engine);
    await settle(page);
    const rect = await pageRect(page);
    let swayed = 0, hashes = new Set();
    for (let i = 0; i < 12; i++) {
      const a = await ambient(page);
      swayed = Math.max(swayed, a.swaying);
      hashes.add(await page.evaluate(() => { const c = document.getElementById('garden'), d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data; let h = 0; for (let j = 3; j < d.length; j += 4) h = (h * 31 + d[j]) | 0; return h; }));
      assert.equal(await canvasAlphaInside(page, rect), 0, 'the garden painted over the page');
      await page.waitForTimeout(350);
    }
    assert.ok(swayed > 0, 'no leaf ever moved in the wind');
    assert.ok(hashes.size > 2, 'the canvas never changed, so nothing moved');
  });

  test(`[${engine}] it pauses while the window is hidden and picks up again when it is shown`, {timeout: 120000}, async t => {
    const {page} = await launch(t, engine);
    await settle(page);
    assert.equal((await ambient(page)).running, true);
    await hide(page, true);
    const paused = await ambient(page);
    assert.equal(paused.running, false, 'the ambient loop stayed scheduled in a hidden window');
    await page.waitForTimeout(800);
    assert.equal((await ambient(page)).frames, paused.frames, 'frames were drawn in a hidden window');
    const clock = paused.time;
    await hide(page, false);
    await page.waitForTimeout(800);
    const resumed = await ambient(page);
    assert.ok(resumed.frames > paused.frames, 'the garden never started moving again');
    assert.ok(resumed.time - clock < 1500, `the garden's clock jumped ${resumed.time - clock} ms while hidden`);
  });

  test(`[${engine}] it never animates while scrolling or turning a page, and resumes afterwards`, {timeout: 120000}, async t => {
    const {page} = await launch(t, engine);
    await settle(page);
    // Wheel input: record every 8 ms whether the garden is frozen and how many ambient frames it has drawn.
    const wheel = await page.evaluate(() => new Promise(resolve => {
      const api = window.StillleafReader, samples = [];
      const poll = setInterval(() => { const g = api.gardenDebug(true); samples.push([g.frozen, g.ambient.frames, g.ambient.running, performance.now()]); }, 8);
      let n = 0;
      const burst = setInterval(() => { window.dispatchEvent(new WheelEvent('wheel', {deltaY: 40})); if (++n > 8) { clearInterval(burst); setTimeout(() => { clearInterval(poll); resolve(samples); }, 1200); } }, 80);
    }));
    const frozen = wheel.filter(s => s[0]);
    assert.ok(frozen.length >= 3 && frozen.at(-1)[3] - frozen[0][3] > 500, 'the garden did not stay frozen through a wheel burst');
    assert.ok(frozen.every(s => s[1] === frozen[0][1]), 'ambient frames ran while the wheel was turning');
    assert.ok(frozen.every(s => s[2] === false), 'the ambient loop stayed scheduled during a wheel burst');
    assert.ok(wheel.at(-1)[1] > frozen[0][1], 'the garden never resumed after scrolling stopped');
    // A page turn holds the garden for the length of the slide and a moment after.
    const turn = await page.evaluate(() => new Promise(resolve => {
      const api = window.StillleafReader, samples = [];
      const poll = setInterval(() => { const g = api.gardenDebug(true); samples.push([g.frozen, g.ambient.frames, false, performance.now()]); }, 8);
      api.next();
      setTimeout(() => { clearInterval(poll); resolve(samples); }, 2500);
    }));
    const held = turn.filter(s => s[0]);
    assert.ok(held.length >= 3 && held.at(-1)[3] - held[0][3] > 200, 'a page turn did not hold the garden');
    assert.ok(held.every(s => s[1] === held[0][1]), 'ambient frames ran during a page turn');
    assert.ok(turn.at(-1)[1] > held[0][1], 'the garden never resumed after the page turn');
  });

  for (const [name, options] of [['Still', {gardenMode: 'still'}], ['Off', {gardenMode: 'off'}], ['Reduce Motion', {reducedMotion: 'reduce'}]]) {
    test(`[${engine}] ${name} draws no ambient frames and keeps nothing moving`, {timeout: 120000}, async t => {
      const {page, errors} = await launch(t, engine, {...options, pace: 30});
      await page.evaluate(() => window.StillleafReader.go({href: 'one.html', type: 'text/html', locations: {progression: 0.4}}));
      await page.waitForFunction(() => window.StillleafReader.gardenDebug().progress > 0.2);
      await page.waitForTimeout(2500);
      const a = await ambient(page);
      assert.equal(a.frames, 0, `${name} drew ambient frames`);
      assert.equal(a.running, false);
      assert.deepEqual(a.living, {shoots: 0, cells: 0, growing: 0, withering: 0, recycled: 0, petals: 0, spores: 0, flies: 0});
      assert.equal((await debug(page)).animating, false);
      assert.deepEqual(errors, []);
    });
  }

  test(`[${engine}] switching a moving garden to Still stops the motion and removes what had grown`, {timeout: 120000}, async t => {
    const {page} = await launch(t, engine, {pace: 30});
    await settle(page);
    await page.waitForFunction(() => window.StillleafReader.gardenDebug().ambient.living.cells > 0, null, {timeout: 20000});
    await page.evaluate(() => window.StillleafReader.setGardenMode('still'));
    await page.waitForTimeout(300);
    const stopped = await ambient(page);
    await page.waitForTimeout(800);
    const later = await ambient(page);
    assert.equal(later.frames, stopped.frames, 'frames kept drawing after Still');
    assert.equal(later.living.cells + later.living.petals + later.living.flies, 0, 'Still kept live growth or particles');
    await page.evaluate(() => window.StillleafReader.setGardenMode('off'));
    await page.waitForTimeout(300);
    assert.equal((await ambient(page)).running, false);
  });

  test(`[${engine}] new shoots grow beside the page and old ones wither away again`, {timeout: 180000}, async t => {
    const {page} = await launch(t, engine, {pace: 40});
    await settle(page);
    const rect = await pageRect(page);
    await page.waitForFunction(() => window.StillleafReader.gardenDebug().ambient.living.recycled >= 1, null, {timeout: 90000, polling: 500});
    const a = await ambient(page);
    assert.ok(a.living.cells > 0 && a.living.cells <= 260, `${a.living.cells} live cells`);
    assert.equal(await canvasAlphaInside(page, rect), 0, 'live growth painted over the page');
  });

  test(`[${engine}] petals fall now and then, and fireflies come out in dark themes only`, {timeout: 180000}, async t => {
    const {page, errors} = await launch(t, engine, {pace: 20});
    await settle(page);
    await page.waitForFunction(() => window.StillleafReader.gardenDebug().ambient.living.petals > 0, null, {timeout: 40000, polling: 250});
    assert.equal((await ambient(page)).living.flies, 0, 'fireflies came out in a light theme');
    await page.evaluate(() => window.StillleafReader.setPreferences({theme: 'dark'}));
    await page.waitForFunction(() => window.StillleafReader.gardenDebug().ambient.living.flies === 4, null, {timeout: 20000, polling: 250});
    await page.evaluate(() => window.StillleafReader.setPreferences({theme: 'paper'}));
    await page.waitForFunction(() => window.StillleafReader.gardenDebug().ambient.living.flies === 0, null, {timeout: 20000, polling: 250});
    assert.deepEqual(errors, []);
  });
}
