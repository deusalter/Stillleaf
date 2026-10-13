import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium, webkit} from 'playwright';

// Work that must not happen on the input path: a page turn rescanning the chapter's text, wheel listeners that make
// scrolling wait for script, vine canvases reallocated on every regrow, and a chapter's worth of vines fading for seconds.
const root = path.resolve(process.env.READER_DIST ?? path.resolve(import.meta.dirname, '../dist'));
const prose = 'The ferry crossed slowly while the gulls kept pace with the wake. <em>Nothing</em> moved quickly there; even the <a href="#x">tide</a> seemed to wait. ';
const chapter = n => `<!doctype html><html><head><title>Chapter ${n}</title></head><body><h1>Chapter ${n}</h1>${Array.from({length: 360}, (_, i) => `<p>${n}.${i + 1} ${prose}</p>`).join('')}</body></html>`;
const book = (continuous = false) => ({editionId: 'lag-fixture', title: 'Across the Water', language: 'en', readingProgression: 'ltr', contentProgress: true, experimentalContinuous: continuous,
  readingOrder: [1, 2].map(n => ({href: `c${n}.html`, type: 'text/html', title: `Chapter ${n}`})),
  resources: [1, 2].map(n => ({href: `c${n}.html`, type: 'text/html', dataBase64: Buffer.from(chapter(n)).toString('base64')}))});

async function launch(t, {viewport = {width: 1300, height: 820}, reducedMotion = 'no-preference', init} = {}) {
  const server = createServer(async (req, res) => {
    try {
      const file = path.resolve(root, '.' + new URL(req.url, 'http://localhost').pathname);
      if (!file.startsWith(root + path.sep)) throw Error();
      res.setHeader('Content-Type', {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css'}[path.extname(file)] ?? 'application/octet-stream');
      res.end(await readFile(file));
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = process.env.READER_TEST_BROWSER === 'webkit' ? await webkit.launch()
    : await chromium.launch({executablePath: process.env.CHROME_PATH || (process.platform === 'darwin' ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : undefined), headless: true});
  t.after(async () => { try { await browser.close(); } finally { server.closeAllConnections(); server.close(); } });
  const page = await browser.newPage({viewport, reducedMotion});
  const errors = [];
  // WebKit reports its benign ResizeObserver loop notice as an error.
  page.on('pageerror', error => { if (!/ResizeObserver loop/.test(String(error))) errors.push(String(error)); });
  await page.addInitScript(() => { window.__stillleafGardenDebug = true; });
  if (init) await page.addInitScript(init);
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  await page.waitForFunction(() => window.StillleafReader);
  return {page, errors};
}

test('a page turn finds the text on screen without measuring the whole chapter again', {timeout: 120000}, async t => {
  const {page, errors} = await launch(t, {init: () => {
    // Counts the engine's text measurements in every document, the reader's and each chapter frame's.
    window.__measured = 0;
    for (const name of ['getClientRects', 'getBoundingClientRect']) {
      const original = Range.prototype[name];
      Range.prototype[name] = function () { window.__measured++; return original.call(this); };
    }
  }});
  await page.evaluate(b => window.StillleafReader.open(b), book());
  await page.evaluate(() => window.StillleafReader.setPreferences({columns: 'two', fontFamily: 'literata', fontSize: 1.1}));
  await page.waitForFunction(() => { const d = window.StillleafReader.slideDebug?.(); return d && d.frames === 2 && d.fresh; }, null, {timeout: 60000});
  await page.waitForTimeout(1500);
  const measured = async () => (await Promise.all(page.frames().map(frame => frame.evaluate(() => window.__measured ?? 0).catch(() => 0)))).reduce((a, b) => a + b, 0);
  const textNodes = await page.evaluate(() => { const doc = document.querySelector('#reader iframe').contentDocument, walk = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT); let n = 0; while (walk.nextNode()) n++; return n; });
  const perTurn = [], positions = [];
  for (let i = 0; i < 4; i++) {
    const before = await measured();
    await page.evaluate(() => window.StillleafReader.next());
    await page.waitForTimeout(500);
    perTurn.push(await measured() - before);
    positions.push(await page.evaluate(() => document.getElementById('position-label').textContent));
  }
  t.diagnostic(`${textNodes} text nodes; text measurements per turn: ${perTurn.join(', ')}`);
  // The index is built once per layout (one measurement per text node). A turn then only tests the nodes on screen,
  // where scanning the chapter took several measurements for every text node of it.
  for (const [i, calls] of perTurn.slice(1).entries()) assert.ok(calls < textNodes / 2, `turn ${i + 2} measured ${calls} times in a chapter of ${textNodes} text nodes`);
  assert.equal(new Set(positions).size, positions.length, 'the footer followed every turn: ' + positions.join(' | '));
  assert.deepEqual(errors, []);
});

test('scrolling never waits on a wheel listener, and paging still turns on a horizontal swipe', {timeout: 120000}, async t => {
  const {page, errors} = await launch(t, {init: () => {
    // Tracks the wheel listeners that can call preventDefault(): the ones that make the engine wait for script.
    window.__blocking = [];
    const add = EventTarget.prototype.addEventListener, remove = EventTarget.prototype.removeEventListener;
    const capture = options => options === true || Boolean(options && options.capture);
    EventTarget.prototype.addEventListener = function (type, listener, options) {
      if (type === 'wheel' && listener && !(options && typeof options === 'object' && options.passive === true) && !window.__blocking.some(e => e.t === this && e.l === listener && e.c === capture(options))) window.__blocking.push({t: this, l: listener, c: capture(options)});
      return add.call(this, type, listener, options);
    };
    EventTarget.prototype.removeEventListener = function (type, listener, options) {
      if (type === 'wheel') window.__blocking = window.__blocking.filter(e => !(e.t === this && e.l === listener && e.c === capture(options)));
      return remove.call(this, type, listener, options);
    };
  }});
  await page.evaluate(b => window.StillleafReader.open(b), book(true));
  const count = () => Promise.all(page.frames().map(frame => frame.evaluate(() => window.__blocking?.length ?? 0).catch(() => 0))).then(list => list.reduce((a, b) => a + b, 0));
  await page.evaluate(() => window.StillleafReader.setPreferences({scroll: false, columns: 'two'}));
  await page.waitForTimeout(800);
  const paged = await count();
  assert.ok(paged >= 1, 'paged reading needs its horizontal-swipe listener');
  // A horizontal swipe still turns a page.
  const before = await page.evaluate(() => window.StillleafReader.bookmark().locations.progression);
  await page.mouse.move(650, 400);
  await page.mouse.wheel(120, 0);
  await page.waitForFunction(b => window.StillleafReader.bookmark().locations.progression > b, before, {timeout: 5000});
  await page.evaluate(() => window.StillleafReader.setPreferences({scroll: true}));
  await page.waitForTimeout(1500);
  const scrolling = await count();
  t.diagnostic(`blocking wheel listeners: paged ${paged}, continuous scroll ${scrolling}`);
  assert.equal(scrolling, 0, 'continuous scrolling kept a wheel listener that can call preventDefault()');
  await page.evaluate(() => window.StillleafReader.setPreferences({scroll: false}));
  await page.waitForTimeout(1500);
  assert.ok(await count() >= 1, 'paged reading lost its swipe listener after a trip through scrolling');
  assert.deepEqual(errors, []);
});

test('a regrow leaves the vine canvases alone unless their size changed, and a chapter of vines fades in within seconds', {timeout: 120000}, async t => {
  const {page, errors} = await launch(t, {init: () => {
    // Assigning a canvas's width or height reallocates and clears its bitmap, even to the same value.
    window.__resets = 0;
    for (const name of ['width', 'height']) {
      const descriptor = Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype, name);
      Object.defineProperty(HTMLCanvasElement.prototype, name, {configurable: true, get() { return descriptor.get.call(this); }, set(value) { if (this.id === 'garden') window.__resets++; descriptor.set.call(this, value); }});
    }
  }});
  await page.evaluate(b => window.StillleafReader.open(b), book());
  await page.evaluate(() => window.StillleafReader.setPreferences({columns: 'one'}));
  const settle = async () => { await page.waitForFunction(() => { const g = window.StillleafReader.gardenDebug(true); return !g.animating && !g.frozen; }, null, {timeout: 20000}); };
  await page.waitForTimeout(600); await settle();
  const first = await page.evaluate(() => window.__resets);
  assert.ok(first >= 1, 'the margin canvas was sized at least once');
  // Move through the chapter: every step regrows the garden, none changes the window.
  const started = Date.now();
  await page.evaluate(() => window.StillleafReader.go({href: 'c1.html', type: 'text/html', locations: {progression: 0.97}}));
  await page.waitForFunction(() => window.StillleafReader.gardenDebug(true).ticks > 0 && window.StillleafReader.gardenDebug().progress > 0.9, null, {timeout: 20000});
  const grown = await page.evaluate(() => window.StillleafReader.gardenDebug().cells.length);
  await settle();
  const seconds = (Date.now() - started) / 1000;
  const second = await page.evaluate(() => window.__resets);
  t.diagnostic(`canvas resets ${first} then ${second}; ${grown} vine cells, settled ${seconds.toFixed(1)} s after the jump`);
  assert.equal(second, first, 'a regrow in an unchanged window reallocated the canvas');
  // The fade-in is bounded at about two and a half seconds however many vines arrive; allow for a slow machine.
  assert.ok(seconds < 5, `a grown chapter's vines took ${seconds.toFixed(1)} s to finish fading in`);
  // A real size change still resizes it.
  await page.setViewportSize({width: 1180, height: 760});
  await page.waitForFunction(first => window.__resets > first, first, {timeout: 10000});
  assert.deepEqual(errors, []);
});

test('a turn into the next chapter finds its page copy ready instead of cloning the chapter', {timeout: 120000}, async t => {
  const {page, errors} = await launch(t);
  await page.evaluate(b => window.StillleafReader.open(b), book());
  await page.evaluate(() => window.StillleafReader.setPreferences({columns: 'two', fontFamily: 'literata', fontSize: 1.1}));
  await page.evaluate(() => window.StillleafReader.go({href: 'c1.html', type: 'text/html', locations: {progression: 0.93}}));
  await page.waitForFunction(() => { const d = window.StillleafReader.slideDebug?.(); return d && d.frames === 2 && d.fresh; }, null, {timeout: 60000});
  await page.waitForTimeout(2500);
  for (let i = 0; i < 12 && (await page.evaluate(() => window.StillleafReader.bookmark().href)) !== 'c2.html'; i++) {
    await page.evaluate(() => window.StillleafReader.next());
    await page.waitForTimeout(700);
  }
  assert.equal(await page.evaluate(() => window.StillleafReader.bookmark().href), 'c2.html', 'the reader reached the next chapter');
  const stats = await page.evaluate(() => window.StillleafReader.slideDebug().crossings);
  t.diagnostic('page copies of the next chapter: ' + JSON.stringify(stats));
  assert.deepEqual(stats, {prepared: 1, built: 0}, 'the turn into the next chapter cloned the chapter while the old page waited');
  assert.deepEqual(errors, []);
});
