// How long the reader takes to show a whole-book page count, in headless WebKit (the engine of the Mac app) or Chromium.
// Synthetic books only. Resources are host-served by URL, as the Mac app serves them.
//   node scripts/measure-page-count.mjs engine=webkit book=small|typical|large mode=single|facing|continuous
//        changes=1 reopen=1 dist=<dir> limit=240
// For each step it prints how long the footer showed no whole-book number (`calculatingMs`), when the exact laid-out count
// was known (`exactMs`), every distinct whole-book total the footer showed (`totals`), and how many hidden chapter
// layouts ran (`probes`). Where the footer kept an estimate it adds the estimate's error and the label after one forward
// turn. A build without the footer's `data-pages` attribute shows a whole-book number only once it is exact.
// Needs `npm ci` and `npm run build` in Reader/desktop/reader first. dist=<dir> measures another build of the reader.
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import zlib from 'node:zlib';
import {pathToFileURL} from 'node:url';
const reader = path.resolve(import.meta.dirname, '../Reader/desktop/reader');
const {chromium, webkit} = await import(pathToFileURL(path.join(reader, 'node_modules/playwright/index.mjs')).href);
const o = Object.fromEntries(process.argv.slice(2).map(a => a.split('=')));
const root = o.dist ?? path.join(reader, 'dist');
const LIMIT = +(o.limit ?? 240) * 1000;

// A plain PNG of the given size, so illustrated chapters carry real image geometry.
function png(width, height) {
  const crcTable = Array.from({length: 256}, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = buf => { let c = 0xffffffff; for (const b of buf) c = crcTable[(c ^ b) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (type, data) => { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const body = Buffer.concat([Buffer.from(type), data]); const sum = Buffer.alloc(4); sum.writeUInt32BE(crc(body)); return Buffer.concat([len, body, sum]); };
  const header = Buffer.alloc(13); header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  const row = Buffer.concat([Buffer.from([0]), Buffer.alloc(width * 3, 0x9c)]);
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(Buffer.concat(Array(height).fill(row)))), chunk('IEND', Buffer.alloc(0))]);
}
const sentences = ['The ferry crossed slowly while the gulls kept pace with the wake.', 'She rested the book on her knees and watched the light change on the opposite bank.', 'Nothing moved quickly there; even the tide seemed to wait for the evening bell.', 'He said the harbour had been quieter the winter before, when the boats stayed in.', 'A long conversation about the orchard followed, and nobody hurried to end it.'];
const words = sentences.join(' ').split(/\s+/).length / sentences.length;
// small ≈ 10k words; typical ≈ 100k words over 30 chapters; large ≈ 400k words over 120 chapters of uneven length with illustrations.
const shapes = {small: {chapters: 5, words: 2000, images: 0}, typical: {chapters: 30, words: 3300, images: 6}, large: {chapters: 120, words: 3300, images: 40}};
export function syntheticBook(kind, editionId = 'measure-' + kind) {
  const shape = shapes[kind], files = new Map(), readingOrder = [], resources = [];
  const picture = png(900, 600); files.set('plate.png', {type: 'image/png', body: picture});
  for (let c = 0; c < shape.chapters; c++) {
    const target = Math.round(shape.words * (kind === 'large' ? [0.4, 1.6, 1, 0.7, 1.3][c % 5] : 1));
    const paras = []; let count = 0, s = c;
    while (count < target) { const n = 2 + (s % 5); const p = Array.from({length: n}, (_, i) => sentences[(s + i) % sentences.length]).join(' '); paras.push(`<p>${p}</p>`); count += n * words; s++; }
    const illustrated = c < shape.images * (shape.chapters / Math.max(1, shape.images)) && c % Math.max(1, Math.round(shape.chapters / Math.max(1, shape.images))) === 0 && shape.images > 0;
    if (illustrated) paras.splice(Math.floor(paras.length / 2), 0, '<figure><img src="plate.png" alt="Plate"/></figure>');
    const href = `c${c}.xhtml`;
    files.set(href, {type: 'application/xhtml+xml', body: Buffer.from(`<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter ${c + 1}</title></head><body><h1>Chapter ${c + 1}</h1>${paras.join('')}</body></html>`)});
    readingOrder.push({href, type: 'application/xhtml+xml', title: `Chapter ${c + 1}`});
  }
  for (const [href, file] of files) resources.push({href, type: file.type, url: '/book/' + href, size: file.body.length});
  return {book: {editionId, title: 'Measured ' + kind, language: 'en', readingProgression: 'ltr', contentProgress: true, readingOrder, resources}, files};
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const kind = o.book ?? 'typical', mode = o.mode ?? 'single';
  const {book, files} = syntheticBook(kind);
  const server = createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://x');
      if (url.pathname.startsWith('/book/')) { const file = files.get(url.pathname.slice(6)); if (!file) throw Error(); res.setHeader('Content-Type', file.type); res.end(file.body); return; }
      const file = path.resolve(root, '.' + url.pathname); res.setHeader('Content-Type', {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css'}[path.extname(file)] ?? 'application/octet-stream'); res.end(await readFile(file));
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const engine = o.engine ?? 'webkit';
  const browser = await (engine === 'webkit' ? webkit : chromium).launch({headless: true});
  const page = await browser.newPage({viewport: {width: 1300, height: 860}, reducedMotion: 'reduce'});
  const errors = []; page.on('pageerror', e => errors.push(String(e)));
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  await page.waitForFunction(() => window.StillleafReader);
  // The footer label, the probes the background counter lays out, and any page map the reader offers its host.
  await page.evaluate(() => {
    const r = window.__m = {labels: [], probes: 0, maps: [], t0: 0};
    const label = document.querySelector('#position-label');
    const whole = text => /^Pages? \d+(?:–\d+)? of \d+$/.test(text);
    const look = () => {
      const text = label.textContent, now = performance.now() - r.t0;
      const state = label.dataset.pages ?? '';
      if (r.labels.at(-1)?.text !== text || r.labels.at(-1)?.state !== state) r.labels.push({at: Math.round(now), text, state});
    };
    new MutationObserver(look).observe(label, {childList: true, characterData: true, subtree: true, attributes: true});
    new MutationObserver(list => { for (const m of list) for (const n of m.addedNodes) if (n.classList?.contains('pagination-probe')) { r.probes++; r.firstProbe ??= Math.round(performance.now() - r.t0); } }).observe(document.body, {childList: true});
    window.addEventListener('stillleaf-reader-event', e => { if (e.detail.type === 'pageMap') { r.maps.push(e.detail.pageMap); r.known = {at: Math.round(performance.now() - r.t0), total: e.detail.pageMap.counts.reduce((a, b) => a + b, 0)}; } });
    r.whole = whole;
    r.reset = () => { r.labels = []; r.probes = 0; r.t0 = performance.now(); r.known = null; r.firstProbe = null; look(); };
  });
  const prefs = {single: {scroll: false, columns: 'one'}, facing: {scroll: false, columns: 'two'}, continuous: {scroll: true}}[mode];
  const state = {schemaVersion: 1, editionId: book.editionId, revision: 0, annotations: [], bookmarks: [], preferences: prefs};
  const opened = {...book, experimentalContinuous: mode === 'continuous', state};
  const results = [];
  async function step(name, action) {
    await page.evaluate(() => window.__m.reset());
    const started = Date.now();
    await action();
    // Settled: no hidden layout in progress, and either an exact label or an exact map handed to the host; unchanged for 2.5 s.
    await page.waitForFunction(() => { const m = window.__m, last = m.labels.at(-1), now = performance.now() - m.t0;
      return !document.querySelector('.pagination-probe') && m.whole(last.text) && ((last.state || 'exact') === 'exact' || m.known) && now - Math.max(last.at, m.known?.at ?? 0) > 2500 && now > 2600; }, null, {timeout: LIMIT, polling: 100}).catch(() => {});
    const m = await page.evaluate(() => ({labels: window.__m.labels, probes: window.__m.probes, firstProbe: window.__m.firstProbe, known: window.__m.known, now: performance.now() - window.__m.t0}));
    const whole = text => /^Pages? \d+(?:–\d+)? of \d+$/.test(text), end = m.labels.at(-1);
    const exactLabel = m.labels.find((l, i) => whole(l.text) && (l.state || 'exact') === 'exact' && (i > 0 || name === 'theme'));
    const exactAt = Math.min(exactLabel?.at ?? Infinity, m.known?.at ?? Infinity);
    // Time the footer showed no whole-book number, and every distinct whole-book total it showed.
    let calculating = 0; const totals = [];
    m.labels.forEach((l, i) => { const until = m.labels[i + 1]?.at ?? m.now; if (!whole(l.text)) calculating += until - l.at; else { const t = +l.text.match(/of (\d+)$/)[1]; if (totals.at(-1) !== t) totals.push(t); } });
    const shown = totals.at(-1), exact = m.known?.total ?? (exactLabel ? +exactLabel.text.match(/of (\d+)$/)[1] : null);
    const result = {step: name, calculatingMs: Math.round(Math.min(calculating, m.now)), exactMs: Number.isFinite(exactAt) ? exactAt : `>${Date.now() - started}`, totals: totals.join('→'), probes: m.probes, ...(o.verbose ? {firstProbeMs: m.firstProbe} : {})};
    if (end?.state === 'estimate' && exact) {
      result.estimateError = (100 * (shown - exact) / exact).toFixed(1) + '%';
      // The refinement arrives with the reader's next move.
      await page.evaluate(() => window.StillleafReader.next()); await page.waitForTimeout(900);
      result.afterTurn = await page.evaluate(() => { const l = document.querySelector('#position-label'); return `[${l.dataset.pages}] ${l.textContent}`; });
    }
    results.push(result);
    if (o.verbose) for (const l of m.labels) console.log(`  ${name} +${l.at}ms ${l.state ? '[' + l.state + '] ' : ''}${l.text}`);
  }
  await step('open', () => page.evaluate(b => window.StillleafReader.open(b), opened));
  if (o.changes !== '0') {
    await step('resize', () => page.setViewportSize({width: 1180, height: 820}));
    await step('font size', () => page.evaluate(() => window.StillleafReader.setPreferences({fontSize: 1.35})));
    await step('line spacing', () => page.evaluate(() => window.StillleafReader.setPreferences({lineHeight: 1.8})));
    await step('theme', () => page.evaluate(() => window.StillleafReader.setPreferences({theme: 'night'})));
  }
  if (o.reopen !== '0') {
    // The host returns the page maps it was offered, as the Mac app does across launches.
    const maps = await page.evaluate(() => window.__m.maps);
    const saved = await page.evaluate(() => window.StillleafReader.exportState());
    await page.evaluate(() => window.StillleafReader.close());
    await step('reopen', () => page.evaluate(([b, s, m]) => window.StillleafReader.open({...b, state: s, pageMaps: m.length ? m : undefined}), [opened, saved, maps]));
  }
  console.log(JSON.stringify({engine, book: kind, mode, chapters: book.readingOrder.length, results, errors: errors.slice(0, 3)}));
  await browser.close(); server.close();
}
