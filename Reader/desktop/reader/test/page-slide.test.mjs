import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile, mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium, webkit} from 'playwright';
import {slideSign, SLIDE} from '../src/page-slide.js';

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
  // The stage is persistent: a turn is over when it is idle again (it stays up for a moment so a follow-up turn can reuse it).
  await page.evaluate(() => { window.slideIdle = () => { const stage = document.querySelector('.reader-page-slide'); return !stage || stage.dataset.state === 'idle'; }; });
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
  // Deliver one stroke in one browser task; separate driver round-trips may
  // legitimately exceed the handler's 180ms new-gesture boundary on a slow host.
  await page.evaluate(() => {
    const frame = [...document.querySelectorAll('#reader iframe')].find(f => getComputedStyle(f).visibility !== 'hidden');
    for (const deltaX of [80, 60, 30]) frame.contentWindow.dispatchEvent(new frame.contentWindow.WheelEvent('wheel', {deltaX, cancelable: true}));
    window.dispatchEvent(new WheelEvent('wheel', {deltaX: 60, clientX: 500, clientY: 380, cancelable: true}));
  });
  await page.waitForTimeout(900); assert.deepEqual(await page.evaluate(()=>window.turnEvents.map(e=>e.direction)),['forward'], JSON.stringify(await page.evaluate(()=>({hit:document.elementFromPoint(500,380)?.outerHTML,place:window.StillleafReader.bookmark()})))); await page.waitForFunction(() => window.slideIdle());
  assert.equal(await page.evaluate(() => window.turnEvents[0].direction), 'forward');
  await page.mouse.wheel(-80, 0);
  await page.waitForFunction(() => window.turnEvents.length === 2 && window.slideIdle());
  assert.deepEqual(await start(), beginning);
  // Also retain real browser-input routing in both directions, separately from
  // the precisely timed synthetic momentum burst above.
  await page.mouse.wheel(80, 0);
  await page.waitForFunction(() => window.turnEvents.length === 3 && window.slideIdle());
  await page.mouse.wheel(-80, 0);
  await page.waitForFunction(() => window.turnEvents.length === 4 && window.slideIdle());
  assert.deepEqual(await start(), beginning);
  await page.evaluate(() => { window.turnEvents.splice(2); });
  await page.keyboard.press('Shift+ArrowRight'); await page.waitForTimeout(60);
  assert.equal(await page.evaluate(() => window.turnEvents.length), 2);
  await page.keyboard.press('PageDown');
  await page.waitForFunction(() => window.turnEvents.length === 3 && window.slideIdle());
  await page.keyboard.press('PageUp');
  await page.waitForFunction(() => window.turnEvents.length === 4 && window.slideIdle());
  assert.deepEqual(await start(), beginning);

  // All inputs survive, but Readium never receives overlapping navigation calls.
  await page.evaluate(async () => {
    window.turnEvents.length = 0;
    await Promise.all(['next', 'next', 'previous', 'previous'].map(direction => window.StillleafReader[direction]()));
  });
  assert.deepEqual(await page.evaluate(() => window.turnEvents.map(e => e.direction)), ['forward', 'forward', 'backward', 'backward']);
  assert.deepEqual(await start(), beginning);
  await page.waitForFunction(() => window.slideIdle()); assert.equal(await page.locator('.reader-page-slide:not([data-state="idle"])').count(), 0);
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
  await page.waitForFunction(() => window.slideIdle()); assert.equal(await page.locator('.reader-page-slide:not([data-state="idle"])').count(), 0);
  await page.emulateMedia({reducedMotion: 'no-preference'}); await page.waitForFunction(()=>!matchMedia('(prefers-reduced-motion: reduce)').matches); await page.waitForTimeout(50);
  await launch('next'); await animation(); await page.emulateMedia({reducedMotion: 'reduce'}); await finish();
  await page.waitForFunction(() => window.slideIdle()); assert.equal(await page.locator('.reader-page-slide:not([data-state="idle"])').count(), 0);

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
  await page.keyboard.press('ArrowLeft'); await page.waitForFunction(() => !window.slideIdle());
  await page.waitForFunction(() => window.slideIdle());
  assert.ok((await start()).locations.progression < end.locations.progression);

  await launch('previous'); await animation();
  await page.setViewportSize({width: 960, height: 780}); await finish();
  await page.waitForTimeout(400);
  await page.waitForFunction(() => window.slideIdle()); assert.equal(await page.locator('.reader-page-slide:not([data-state="idle"])').count(), 0);
  assert.ok(await page.evaluate(() => [...document.querySelectorAll('#reader iframe')].some(f => getComputedStyle(f).visibility !== 'hidden' && f.contentDocument?.body.innerText.length > 100)));

  await page.evaluate(input => window.StillleafReader.open(input), fixture(true));
  await launch('next'); await animation();
  assert.ok(await page.evaluate(() => Number(document.querySelector('.page-slide-track').getAnimations()[0].effect.getKeyframes().at(-1).transform.match(/translate3d\(([-\d.]+)/)[1]) > 0));
  await finish();
  await launch('previous'); await animation();
  await page.evaluate(() => window.StillleafReader.close());
  await finish();
  await page.waitForFunction(() => window.slideIdle()); assert.equal(await page.locator('.reader-page-slide:not([data-state="idle"])').count(), 0); assert.deepEqual(errors, []);
  await writeFile(path.join(artifacts, `${engine}-metrics.json`), JSON.stringify(metrics, null, 2));
  const video = page.video(); await page.close(); if (video) await video.saveAs(path.join(artifacts, `${engine}-reader-slide.webm`));
});

/** A facing-pages reader on a wide window, with the garden and card on, ready for turns. */
async function facingReader(t, {width = 1500, height = 860, paragraphs = 120} = {}) {
  const server = createServer(async (req, res) => {
    try {
      const file = path.resolve(root, '.' + new URL(req.url, 'http://localhost').pathname);
      if (!file.startsWith(root + path.sep)) throw Error();
      res.setHeader('Content-Type', {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css'}[path.extname(file)] ?? 'application/octet-stream');
      res.end(await readFile(file));
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const engine = process.env.SLIDE_BROWSER === 'webkit' ? webkit : chromium;
  const browser = await (engine === webkit ? webkit.launch() : chromium.launch({executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true}));
  t.after(async () => { try { await browser.close(); } finally { await new Promise(resolve => server.close(resolve)); } });
  const page = await browser.newPage({viewport: {width, height}, reducedMotion: 'no-preference'});
  // WebKit reports a benign "ResizeObserver loop" notice from time to time; it is not an error of the page.
  const errors = []; page.on('pageerror', error => { if (!/ResizeObserver loop/.test(error.message)) errors.push(error.message); });
  await page.addInitScript(() => { window.__stillleafGardenDebug = true; });
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  await page.waitForFunction(() => Boolean(window.StillleafReader));
  const book = fixture();
  book.resources = [1, 2].map(n => ({href: `c${n}.html`, type: 'text/html', dataBase64: Buffer.from(`<!doctype html><html><head><title>Chapter ${n}</title></head><body><h1>Chapter ${n}</h1>${Array.from({length: paragraphs}, (_, i) => `<p id="c${n}p${i}">${n}.${i + 1} — ${prose}</p>`).join('')}</body></html>`).toString('base64')}));
  await page.evaluate(input => window.StillleafReader.open(input), book);
  await page.evaluate(() => window.StillleafReader.setPreferences({columns: 'two', fontFamily: 'literata', fontSize: 1.1}));
  await page.evaluate(() => { window.slideIdle = () => { const stage = document.querySelector('.reader-page-slide'); return !stage || stage.dataset.state === 'idle'; }; });
  // The copies are built in the background once the page has been still for a moment.
  await page.waitForFunction(() => { const state = window.StillleafReader.slideDebug(); return state.frames === 2 && state.fresh; }, null, {timeout: 20000});
  // And the garden has finished fading in, so any frame it draws later belongs to the turn.
  await page.waitForFunction(() => { const g = window.StillleafReader.gardenDebug(); return !g.animating && !g.frozen; }, null, {timeout: 15000});
  await page.waitForTimeout(300);
  return {page, errors};
}

test('a turn follows the motion contract: 280-360 ms, an eased-in curve, transform and opacity only', {timeout: 120000}, async t => {
  const {page, errors} = await facingReader(t);
  assert.ok(SLIDE.duration >= 280 && SLIDE.duration <= 360, `duration ${SLIDE.duration} is outside 280-360 ms`);
  assert.ok(SLIDE.hurried < SLIDE.duration);
  await page.evaluate(() => {
    window.animations = [];
    const original = Element.prototype.animate;
    Element.prototype.animate = function (keyframes, options) {
      const animation = original.call(this, keyframes, options);
      if (this.closest('.reader-page-slide')) window.animations.push({target: this.className, keyframes: JSON.parse(JSON.stringify(keyframes)), duration: options.duration, easing: options.easing});
      return animation;
    };
    window.frameTimes = []; window.xs = []; window.clocks = [];
    const sample = now => {
      const track = document.querySelector('.page-slide-track'), running = track?.getAnimations().some(a => a.playState === 'running');
      if (running) { window.frameTimes.push(now); window.xs.push(new DOMMatrix(getComputedStyle(track).transform).m41); window.clocks.push(track.getAnimations()[0].currentTime); }
      requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
    window.iframesMade = 0;
    const create = document.createElement;
    document.createElement = function (name, ...rest) { if (String(name).toLowerCase() === 'iframe') window.iframesMade++; return create.call(this, name, ...rest); };
    window.__stillleafGardenTicks = window.StillleafReader.gardenDebug().ticks;
  });
  const idle = await page.evaluate(() => getComputedStyle(document.querySelector('.page-slide-track')).willChange);
  assert.equal(idle, 'auto', 'will-change is set while the stage is idle');
  await page.evaluate(() => { window.turned = window.StillleafReader.next(); });
  await page.waitForFunction(() => window.animations.length > 0);
  const during = await page.evaluate(() => ({willChange: getComputedStyle(document.querySelector('.page-slide-track')).willChange, garden: window.StillleafReader.gardenDebug().frozen}));
  assert.match(during.willChange, /transform/, 'the strip is not promoted while it moves');
  assert.equal(during.garden, true, 'the garden was not held still during the turn');
  assert.equal(await page.evaluate(() => window.turned), true);
  await page.waitForFunction(() => window.slideIdle());
  const result = await page.evaluate(() => ({animations: window.animations, frameTimes: window.frameTimes, xs: window.xs, clocks: window.clocks, iframesMade: window.iframesMade, width: document.querySelector('#reader').clientWidth, ticks: window.StillleafReader.gardenDebug().ticks - window.__stillleafGardenTicks}));
  const main = result.animations.find(a => a.target.includes('page-slide-track'));
  assert.equal(main.duration, SLIDE.duration);
  assert.equal(main.easing, SLIDE.easing);
  // Nothing but transform and opacity is ever animated, so the turn never touches layout.
  for (const animation of result.animations) for (const frame of animation.keyframes) assert.deepEqual(Object.keys(frame).filter(k => !['offset', 'easing', 'composite'].includes(k)).filter(k => !['transform', 'opacity'].includes(k)), [], `${animation.target} animates ${JSON.stringify(frame)}`);
  assert.ok(result.animations.some(a => a.target.includes('page-slide-shade')) && result.animations.some(a => a.target.includes('page-slide-edge')), 'the depth cues did not animate');
  assert.equal(result.iframesMade, 0, 'a turn within a warm chapter built a snapshot');
  // The curve eases in from rest: a frame's worth of time moves it a few percent, not a fifth of the page.
  const bezier = (x1, y1, x2, y2) => t => {
    let low = 0, high = 1;
    for (let i = 0; i < 40; i++) { const u = (low + high) / 2, x = 3 * (1 - u) ** 2 * u * x1 + 3 * (1 - u) * u * u * x2 + u ** 3; if (x < t) low = u; else high = u; }
    const u = (low + high) / 2;
    return 3 * (1 - u) ** 2 * u * y1 + 3 * (1 - u) * u * u * y2 + u ** 3;
  };
  const curve = bezier(...SLIDE.easing.match(/-?[\d.]+/g).map(Number));
  assert.ok(curve(16.7 / SLIDE.duration) < 0.04, `the first frame of the curve covers ${(curve(16.7 / SLIDE.duration) * 100).toFixed(1)}% of the page`);
  assert.ok(curve(0.5) > 0.7 && curve(0.5) < 0.95 && curve(0.9) > 0.97, 'the curve does not settle gently');
  // Whatever the frame pacing of the machine, the strip sits where the curve says it should at the animation clock.
  result.xs.forEach((x, i) => {
    const expected = curve(Math.min(1, result.clocks[i] / SLIDE.duration)) * result.width;
    assert.ok(Math.abs(Math.abs(x) - expected) < result.width * 0.04, `at ${Math.round(result.clocks[i])} ms the strip is at ${Math.round(Math.abs(x))}px, the curve says ${Math.round(expected)}px`);
  });
  assert.ok(Math.abs(result.xs.at(-1)) > result.width * 0.9);
  const gaps = result.frameTimes.slice(1).map((time, i) => time - result.frameTimes[i]);
  // A shared CI runner can stall any frame for a moment (the book-wide page count runs in the background), so this only catches a
  // pathological one; scripts/measure-page-turn.mjs reports the real frame times.
  assert.ok(Math.max(...gaps) < 250, `a frame took ${Math.round(Math.max(...gaps))} ms during the turn`);
  assert.equal(result.ticks, 0, 'the garden drew frames while the page turned');
  assert.deepEqual(errors, []);
});

test('turns in a row reuse the copies and the stage; a held key fast-forwards instead of stuttering', {timeout: 120000}, async t => {
  const {page, errors} = await facingReader(t);
  await page.evaluate(() => {
    window.states = []; window.iframesMade = 0;
    const stage = document.querySelector('.reader-page-slide');
    new MutationObserver(() => window.states.push(stage.dataset.state)).observe(stage, {attributes: true, attributeFilter: ['data-state']});
    const create = document.createElement;
    document.createElement = function (name, ...rest) { if (String(name).toLowerCase() === 'iframe') window.iframesMade++; return create.call(this, name, ...rest); };
    window.frames0 = [...document.querySelectorAll('.page-slide-snapshot')];
    window.durations = [];
    const original = Element.prototype.animate;
    Element.prototype.animate = function (keyframes, options) { if (this.classList.contains('page-slide-track')) window.durations.push(options.duration); return original.call(this, keyframes, options); };
  });
  const start = await page.evaluate(() => window.StillleafReader.bookmark());
  // Separate presses straight after one another, then two waiting together.
  await page.evaluate(async () => { await window.StillleafReader.next(); await window.StillleafReader.next(); });
  await page.evaluate(async () => { await Promise.all([window.StillleafReader.previous(), window.StillleafReader.previous()]); });
  const result = await page.evaluate(() => ({states: window.states, made: window.iframesMade, durations: window.durations, same: [...document.querySelectorAll('.page-slide-snapshot')].filter(f => window.frames0.includes(f)).length}));
  // The reading position is reported by Readium a moment after the last turn settles.
  await page.waitForFunction(place => JSON.stringify(window.StillleafReader.bookmark()) === place, JSON.stringify(start), {timeout: 5000}).catch(() => {});
  assert.deepEqual(await page.evaluate(() => window.StillleafReader.bookmark()), start, 'four turns did not return to the start');
  assert.equal(result.made, 0, 'turns in a row built new snapshots');
  assert.equal(result.same, 2, 'the chapter copies were replaced');
  assert.equal(result.states.filter(state => state === 'arming').length, 1, `the stage was brought up again between turns: ${result.states}`);
  assert.equal(result.durations.length, 4);
  assert.ok(result.durations.slice(2).includes(SLIDE.hurried), `waiting turns were not hurried: ${result.durations}`);
  // A held key: repeat events fast-forward the turn on screen; they never queue a backlog.
  await page.evaluate(() => { window.turnEvents = []; window.addEventListener('stillleaf-reader-event', e => { if (e.detail.type === 'pageTurn') window.turnEvents.push(e.detail); }); });
  await page.keyboard.down('ArrowRight');
  for (let i = 0; i < 12; i++) { await page.keyboard.down('ArrowRight'); await page.waitForTimeout(40); }
  await page.keyboard.up('ArrowRight');
  await page.waitForFunction(() => window.slideIdle());
  const turned = await page.evaluate(() => window.turnEvents.length);
  assert.ok(turned >= 2 && turned <= 12, `a held key made ${turned} turns`);
  assert.equal(await page.evaluate(() => window.iframesMade), 0);
  assert.deepEqual(errors, []);
});

test('Reduce Motion changes the page at once, with no stage, strip or copies in motion', {timeout: 120000}, async t => {
  const {page, errors} = await facingReader(t);
  await page.emulateMedia({reducedMotion: 'reduce'});
  await page.waitForFunction(() => matchMedia('(prefers-reduced-motion: reduce)').matches);
  const before = await page.evaluate(() => window.StillleafReader.bookmark());
  const seen = await page.evaluate(async () => {
    const states = [], stage = document.querySelector('.reader-page-slide');
    if (stage) new MutationObserver(() => states.push(stage.dataset.state)).observe(stage, {attributes: true, attributeFilter: ['data-state']});
    const moved = await window.StillleafReader.next();
    return {moved, states, animating: document.getAnimations().filter(a => a.effect?.target?.closest?.('.reader-page-slide')).length};
  });
  assert.equal(seen.moved, true);
  assert.deepEqual(seen.states.filter(state => state !== 'idle'), [], 'Reduce Motion brought the stage up');
  assert.equal(seen.animating, 0);
  assert.notDeepEqual(await page.evaluate(() => window.StillleafReader.bookmark()), before);
  assert.deepEqual(errors, []);
});

test('a turn in a large chapter starts far sooner with the copies built ahead than when it has to build them', {timeout: 180000}, async t => {
  const {page, errors} = await facingReader(t, {paragraphs: 2500});
  await page.evaluate(() => {
    window.longTasks = [];
    try { new PerformanceObserver(list => window.longTasks.push(...list.getEntries().map(e => ({duration: e.duration, start: e.startTime})))).observe({entryTypes: ['longtask']}); } catch { /* WebKit has no long-task entries */ }
    window.starts = [];
    const original = Element.prototype.animate;
    Element.prototype.animate = function (keyframes, options) { if (this.classList.contains('page-slide-track')) window.starts.push(performance.now()); return original.call(this, keyframes, options); };
    window.latency = async () => { const t0 = performance.now(); window.starts.length = 0; const promise = window.StillleafReader.next(); await promise; return window.starts[0] - t0; };
  });
  const warm = [];
  for (let i = 0; i < 3; i++) {
    warm.push(await page.evaluate(() => window.latency()));
    await page.waitForFunction(() => window.slideIdle());
    await page.waitForTimeout(600);
  }
  const quiet = await page.evaluate(() => window.longTasks.filter(task => task.duration > 50));
  // The same turn when the copies have just been dropped (as a layout change does) and must be built inside the turn.
  await page.evaluate(() => window.StillleafReader.slideInvalidate());
  const cold = await page.evaluate(() => window.latency());
  const median = [...warm].sort((a, b) => a - b)[1];
  assert.ok(median < cold * 0.7, `a warm turn took ${warm.map(Math.round)} ms to start moving, a cold one ${Math.round(cold)} ms`);
  assert.deepEqual(quiet, [], 'a long task ran during the warm turns');
  assert.deepEqual(errors, []);
});
