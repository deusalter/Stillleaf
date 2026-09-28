import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile, mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium, webkit} from 'playwright';
import {slideSign} from '../src/page-slide.js';

const root = path.resolve(import.meta.dirname, '../dist');
const artifacts = path.resolve(import.meta.dirname, '../../../../.local/reader-slide');
const prose = 'The ferry crossed slowly while the gulls kept pace with the wake. She rested the book on her knees and watched the light change on the opposite bank.';
const fixture = (rtl = false) => ({editionId: 'slide-fixture', title: 'Across the Water', language: rtl ? 'ar' : 'en', readingProgression: rtl ? 'rtl' : 'ltr',
  readingOrder: [1, 2].map(n => ({href: `c${n}.html`, type: 'text/html', title: `Chapter ${n}`})),
  resources: [1, 2].map(n => ({href: `c${n}.html`, type: 'text/html', dataBase64: Buffer.from(`<!doctype html><html dir="${rtl ? 'rtl' : 'ltr'}"><head><title>Chapter ${n}</title></head><body><h1>Chapter ${n}</h1>${Array.from({length: 40}, (_, i) => `<p id="c${n}p${i}">${n}.${i + 1} — ${prose}</p>`).join('')}</body></html>`).toString('base64')}))});

test('logical page direction maps to physical slide direction', () => {
  assert.equal(slideSign('next'), 1); assert.equal(slideSign('previous'), -1);
  assert.equal(slideSign('next', true), -1); assert.equal(slideSign('previous', true), 1);
});

test('actual Readium page slides, reversal, chapter edges and reduced motion', {timeout: 120000}, async t => {
  await mkdir(artifacts, {recursive: true});
  const server = createServer(async (req, res) => {
    try {
      const file = path.resolve(root, '.' + new URL(req.url, 'http://localhost').pathname);
      if (!file.startsWith(root + path.sep)) throw Error();
      res.setHeader('Content-Type', {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css'}[path.extname(file)] ?? 'application/octet-stream');
      res.end(await readFile(file));
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser, context;
  // Register cleanup before setup can fail (for example, missing optional FFmpeg).
  t.after(async () => {
    try { await context?.close(); }
    finally {
      try { await browser?.close(); }
      finally { await new Promise(resolve => server.close(resolve)); }
    }
  });
  const engine = process.env.SLIDE_BROWSER === 'webkit' ? 'webkit' : 'chromium';
  browser = await (engine === 'webkit' ? webkit.launch() : chromium.launch({executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true}));
  const recordVideo = process.env.SLIDE_RECORD_VIDEO === '1' ? {dir: artifacts, size: {width: 1000, height: 800}} : undefined;
  context = await browser.newContext({viewport: {width: 1000, height: 800}, reducedMotion: 'no-preference', ...(recordVideo ? {recordVideo} : {})});
  const page = await context.newPage(); const errors = []; page.on('pageerror', error => errors.push(error.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  await page.waitForFunction(() => Boolean(window.StillleafReader));
  await page.evaluate(input => window.StillleafReader.open(input), fixture());
  await page.evaluate(() => window.StillleafReader.setPreferences({fontFamily: 'literata', fontSize: 1.3}));
  await page.waitForTimeout(300);
  await page.evaluate(prose => window.StillleafReader.annotate({locator: {href: 'c1.html', type: 'text/html', locations: {cssSelector: '#c1p0'}, text: {highlight: '1.1 — ' + prose}}, quote: prose, note: 'Keep this passage.', color: 'sage'}), prose);
  await page.waitForFunction(() => [...document.querySelectorAll('#reader iframe')].some(f => f.contentWindow.CSS.highlights?.size > 0));
  await page.evaluate(() => { window.turnEvents = []; window.addEventListener('stillleaf-reader-event', e => { if (e.detail.type === 'pageTurn') window.turnEvents.push(e.detail); }); });
  const start = () => page.evaluate(() => window.StillleafReader.bookmark());
  const launch = direction => page.evaluate(direction => { window.turnPromise = window.StillleafReader[direction](); }, direction);
  const animation = async () => { try { await page.waitForFunction(() => document.querySelector('.page-slide-track')?.getAnimations().some(a => a.playState === 'running'), null, {timeout: 4000}); } catch(error) { throw Error(JSON.stringify(await page.evaluate(async()=>({place:window.StillleafReader.bookmark(),result:await window.turnPromise,reduced:matchMedia('(prefers-reduced-motion: reduce)').matches,stage:document.querySelector('.reader-page-slide')?.outerHTML})))+' '+error.message); } };
  const finish = () => page.evaluate(() => window.turnPromise);

  const beginning = await start();
  await page.screenshot({path: path.join(artifacts, `${engine}-before.png`)});
  await launch('next'); await animation();
  const metrics = await page.evaluate(() => {
    const stage = document.querySelector('.reader-page-slide'), track = stage.firstElementChild;
    const animation = track.getAnimations()[0]; animation.pause(); animation.currentTime = 65;
    const live = [...document.querySelectorAll('#reader iframe')].find(f => getComputedStyle(f).visibility !== 'hidden');
    const frames = [...stage.querySelectorAll('iframe')];
    return {inert: stage.inert, hidden: stage.getAttribute('aria-hidden'), liveTransform: getComputedStyle(document.querySelector('#reader')).transform,
      frames: frames.map(f => ({x: f.contentWindow.scrollX, width: f.clientWidth, text: f.contentDocument.body.innerText.length,
        scripts: f.contentDocument.scripts.length, highlights: f.contentWindow.CSS.highlights?.size ?? 0,
        family: f.contentWindow.getComputedStyle(f.contentDocument.querySelector('p')).fontFamily,
        zoom: f.contentWindow.getComputedStyle(f.contentDocument.body).zoom})),
      live: {x: live.contentWindow.scrollX, width: live.clientWidth, zoom: live.contentWindow.getComputedStyle(live.contentDocument.body).zoom},
      transform: getComputedStyle(track).transform};
  });
  assert.equal(metrics.inert, true); assert.equal(metrics.hidden, 'true'); assert.equal(metrics.liveTransform, 'none');
  assert.equal(metrics.frames.length, 2); assert.ok(metrics.frames.every(f => f.text > 100 && f.scripts === 0));
  assert.ok(metrics.frames[0].highlights > 0); assert.ok(metrics.frames.every(f => /Literata/i.test(f.family)));
  assert.equal(metrics.frames[1].x, metrics.live.x); assert.equal(metrics.frames[1].zoom, metrics.live.zoom);
  assert.equal(metrics.frames[1].x - metrics.frames[0].x, metrics.live.width);
  assert.ok(Number(metrics.transform.split(',')[4]) < 0);
  await page.screenshot({path: path.join(artifacts, `${engine}-mid-slide.png`)});
  await page.evaluate(() => document.querySelector('.page-slide-track').getAnimations()[0].play()); await finish();
  await launch('previous'); await animation();
  assert.ok(await page.evaluate(() => Number(document.querySelector('.page-slide-track').getAnimations()[0].effect.getKeyframes().at(-1).transform.match(/translate3d\(([-\d.]+)/)[1]) > 0));
  await finish(); assert.deepEqual(await start(), beginning);

  // Horizontal trackpad momentum is one turn; reversing direction remains responsive.
  await page.evaluate(() => { window.turnEvents.length = 0; });
  await page.mouse.move(500, 380);
  await page.mouse.wheel(80, 0); await page.mouse.wheel(60, 0); await page.mouse.wheel(30, 0);
  await page.evaluate(()=>window.dispatchEvent(new WheelEvent('wheel',{deltaX:60,clientX:500,clientY:380,cancelable:true}))); // Same stroke retargeted to the iframe host.
  await page.waitForTimeout(900); assert.deepEqual(await page.evaluate(()=>window.turnEvents.map(e=>e.direction)),['forward'], JSON.stringify(await page.evaluate(()=>({hit:document.elementFromPoint(500,380)?.outerHTML,place:window.StillleafReader.bookmark()})))); await page.waitForFunction(() => !document.querySelector('.reader-page-slide'));
  assert.equal(await page.evaluate(() => window.turnEvents[0].direction), 'forward');
  await page.mouse.wheel(-80, 0);
  await page.waitForFunction(() => window.turnEvents.length === 2 && !document.querySelector('.reader-page-slide'));
  assert.deepEqual(await start(), beginning);
  await page.keyboard.press('Shift+ArrowRight'); await page.waitForTimeout(60);
  assert.equal(await page.evaluate(() => window.turnEvents.length), 2);
  await page.keyboard.press('PageDown');
  await page.waitForFunction(() => window.turnEvents.length === 3 && !document.querySelector('.reader-page-slide'));
  await page.keyboard.press('PageUp');
  await page.waitForFunction(() => window.turnEvents.length === 4 && !document.querySelector('.reader-page-slide'));
  assert.deepEqual(await start(), beginning);

  // All inputs survive, but Readium never receives overlapping navigation calls.
  await page.evaluate(async () => {
    window.turnEvents.length = 0;
    await Promise.all(['next', 'next', 'previous', 'previous'].map(direction => window.StillleafReader[direction]()));
  });
  assert.deepEqual(await page.evaluate(() => window.turnEvents.map(e => e.direction)), ['forward', 'forward', 'backward', 'backward']);
  assert.deepEqual(await start(), beginning);
  assert.equal(await page.locator('.reader-page-slide').count(), 0);
  assert.equal(await page.evaluate(() => window.StillleafReader.exportState().annotations[0].note), 'Keep this passage.');

  // A chapter switch uses the same two-surface slide, including backward to its last page.
  await page.evaluate(() => window.StillleafReader.go({href: 'c1.html', type: 'text/html', locations: {progression: 1}}));
  await launch('next'); await animation();
  const chapters = await page.evaluate(() => [...document.querySelectorAll('.page-slide-snapshot')].map(f => f.contentDocument.querySelector('h1').textContent));
  assert.deepEqual(chapters, ['Chapter 1', 'Chapter 2']);
  await page.screenshot({path: path.join(artifacts, `${engine}-chapter-slide.png`)});
  await finish(); assert.equal((await start()).href, 'c2.html');
  await launch('previous'); await finish(); assert.equal((await start()).href, 'c1.html');
  assert.ok((await start()).locations.progression > .8);

  // Reduced Motion performs the very same navigation with no snapshot or animation.
  await page.emulateMedia({reducedMotion: 'reduce'});
  await launch('next'); await finish(); assert.equal((await start()).href, 'c2.html');
  assert.equal(await page.locator('.reader-page-slide').count(), 0);
  await page.emulateMedia({reducedMotion: 'no-preference'}); await page.waitForFunction(()=>!matchMedia('(prefers-reduced-motion: reduce)').matches); await page.waitForTimeout(50);
  await launch('next'); await animation(); await page.emulateMedia({reducedMotion: 'reduce'}); await finish();
  assert.equal(await page.locator('.reader-page-slide').count(), 0);

  // Selection belongs only to the live document after surfaces are removed.
  const selection = await page.evaluate(() => {
    const f = [...document.querySelectorAll('#reader iframe')].find(f => getComputedStyle(f).visibility !== 'hidden');
    const text = [...f.contentDocument.querySelectorAll('p')].find(p => { const r = p.getBoundingClientRect(); return r.left >= 0 && r.left < f.clientWidth; }).firstChild;
    const r = f.contentDocument.createRange(); r.setStart(text, 0); r.setEnd(text, 8);
    f.contentWindow.getSelection().removeAllRanges(); f.contentWindow.getSelection().addRange(r);
    return f.contentWindow.getSelection().toString();
  });
  assert.equal(selection.length, 8);
  await page.evaluate(() => window.StillleafReader.go({href: 'c2.html', type: 'text/html', locations: {progression: 1}}));
  const end = await start(); await launch('next'); assert.equal(await finish(), false); assert.deepEqual(await start(), end);

  // Real keyboard input still reaches the same navigation path.
  await page.emulateMedia({reducedMotion: 'no-preference'}); await page.waitForFunction(()=>!matchMedia('(prefers-reduced-motion: reduce)').matches); await page.waitForTimeout(50);
  await page.keyboard.press('ArrowLeft'); await page.waitForFunction(() => Boolean(document.querySelector('.reader-page-slide')));
  await page.waitForFunction(() => !document.querySelector('.reader-page-slide'));
  assert.ok((await start()).locations.progression < end.locations.progression);

  await launch('previous'); await animation();
  await page.setViewportSize({width: 960, height: 780}); await finish();
  await page.waitForTimeout(400);
  assert.equal(await page.locator('.reader-page-slide').count(), 0);
  assert.ok(await page.evaluate(() => [...document.querySelectorAll('#reader iframe')].some(f => getComputedStyle(f).visibility !== 'hidden' && f.contentDocument?.body.innerText.length > 100)));

  await page.evaluate(input => window.StillleafReader.open(input), fixture(true));
  await launch('next'); await animation();
  assert.ok(await page.evaluate(() => Number(document.querySelector('.page-slide-track').getAnimations()[0].effect.getKeyframes().at(-1).transform.match(/translate3d\(([-\d.]+)/)[1]) > 0));
  await finish();
  await launch('previous'); await animation();
  await page.evaluate(() => window.StillleafReader.close());
  await finish();
  assert.equal(await page.locator('.reader-page-slide').count(), 0); assert.deepEqual(errors, []);
  await writeFile(path.join(artifacts, `${engine}-metrics.json`), JSON.stringify(metrics, null, 2));
  const video = page.video(); await page.close(); if (video) await video.saveAs(path.join(artifacts, `${engine}-reader-slide.webm`));
});
