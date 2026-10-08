import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium, webkit} from 'playwright';

const root = path.resolve(import.meta.dirname, '../dist');
const book = {editionId: 'delayed-navigation', title: 'Slow chapter fixture', language: 'en',
  readingOrder: ['First', 'Second'].map((title, i) => ({href: `c${i}.html`, type: 'text/html', title})),
  resources: ['First', 'Second'].map((title, i) => ({href: `c${i}.html`, type: 'text/html', dataBase64: Buffer.from(`<!doctype html><html><body><h1>${title}</h1><p>A short chapter with a single page.</p></body></html>`).toString('base64')}))};

test('chapter readiness beyond four seconds retains queued turns and jumps; disposal releases them', {timeout: 45000}, async t => {
  const server = createServer(async (req, res) => {
    try {
      const file = path.resolve(root, '.' + new URL(req.url, 'http://localhost').pathname);
      if (!file.startsWith(root + path.sep)) throw Error();
      res.setHeader('Content-Type', {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css'}[path.extname(file)] ?? 'application/octet-stream');
      res.end(await readFile(file));
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const browser = await (process.env.SLIDE_BROWSER === 'webkit' ? webkit.launch() : chromium.launch({executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true}));
  t.after(() => browser.close());
  const page = await browser.newPage({viewport: {width: 1000, height: 800}, reducedMotion: 'no-preference'});
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  // Delay the REAL Readium chapter activation acknowledgement, not the public
  // reader API. Its _isNavigating flag remains true until this message completes.
  // This also avoids prefetch hiding a network-only delay before the turn starts.
  await page.addInitScript(() => {
    // Only the live navigator owns the held activation. Background pagination
    // can activate the same chapter independently and must not consume this gate.
    if (window === top || !window.frameElement?.closest('#reader')) return;
    const replayed = new WeakSet();
    window.addEventListener('message', event => {
      if (replayed.has(event) || !event.data?._readium) return;
      if (['go_next', 'go_prev'].includes(event.data.key)) top.commands?.push(event.data.key);
      const delayedChapter = event.data.key === 'focus' && top.holdSecond && document.querySelector('h1')?.textContent === 'Second';
      const stalledCommand = event.data.key === 'go_next' && top.holdTurn;
      if (!delayedChapter && !stalledCommand) return;
      top.holdTurn = false;
      top.holdSecond = false; top.chapterHeld = true;
      event.stopImmediatePropagation();
      const copy = new MessageEvent('message', {data: event.data, source: event.source, origin: event.origin});
      replayed.add(copy);
      top.releaseChapter = () => window.dispatchEvent(copy);
    }, true);
  });
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  await page.evaluate(book => window.StillleafReader.open(book), book);
  await page.evaluate(() => {
    window.events = []; window.commands = [];
    window.addEventListener('stillleaf-reader-event', event => { if (event.detail.type === 'pageTurn') window.events.push(event.detail.direction); });
  });
  for (const action of ['turn', 'jump']) {
    await page.evaluate(action => {
      window.commands.length = 0; window.events.length = 0; window.holdSecond = true; window.chapterHeld = false; window.completed = false;
      const first = action === 'turn' ? window.StillleafReader.next() : window.StillleafReader.go({href: 'c1.html', type: 'text/html', locations: {progression: 0}});
      window.pendingNavigation = Promise.all([first, window.StillleafReader.previous()]).then(results => { window.completed = true; return results; });
    }, action);
    await page.waitForFunction(() => window.chapterHeld);
    await page.waitForTimeout(4250);
    assert.deepEqual(await page.evaluate(() => ({completed: window.completed, commands: window.commands, events: window.events})),
      {completed: false, commands: action === 'turn' ? ['go_next'] : [], events: []}, 'no queue release while the real chapter is still activating');
    await page.evaluate(() => { window.releaseChapter(); });
    assert.deepEqual(await page.evaluate(() => window.pendingNavigation), [true, true], 'neither delayed input is discarded');
    assert.deepEqual(await page.evaluate(() => window.events), action === 'turn' ? ['forward', 'backward'] : ['backward']);
    assert.equal(await page.evaluate(() => window.StillleafReader.bookmark().href), 'c0.html');
  }

  // Withhold a turn command on the already-loaded iframe. Readium can dispose
  // that frame without ever delivering the turn callback; its queue must unblock.
  await page.evaluate(() => {
    window.events.length = 0; window.holdTurn = true; window.chapterHeld = false;
    window.pendingNavigation = Promise.all([window.StillleafReader.next(), window.StillleafReader.previous()]);
  });
  await page.waitForFunction(() => window.chapterHeld);
  await page.evaluate(() => { window.pendingPreferences = window.StillleafReader.setPreferences({fontSize: 1.8}); });
  assert.equal(await page.evaluate(() => window.StillleafReader.close()), true);
  assert.deepEqual(await page.evaluate(() => window.pendingNavigation), [false, false]);
  await page.evaluate(() => window.pendingPreferences);
  await page.evaluate(() => { window.releaseChapter(); });
  await page.waitForTimeout(100);
  assert.deepEqual(await page.evaluate(() => window.events), []);
  assert.equal(await page.locator('.reader-page-slide:not([data-state="idle"])').count(), 0);
  await page.evaluate(book => window.StillleafReader.open(book), book);
  assert.equal(await page.evaluate(() => window.StillleafReader.exportState().preferences.fontSize), 1.2, 'cancelled preferences cannot leak into reopened publication');
  assert.equal(await page.evaluate(() => window.StillleafReader.next()), true);
  assert.equal(await page.evaluate(() => window.StillleafReader.bookmark().href), 'c1.html');
  assert.deepEqual(errors, []);
});
