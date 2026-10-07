// Frame timing of the page turn in headless Chromium or WebKit (rAF timestamps, long tasks, easing steps).
//   node scripts/measure-page-turn.mjs engine=chromium|webkit columns=two w=1500 h=860 turns=6 paras=120 mode=api|key
// paras=3000 makes a large chapter. Prints a summary and per-turn numbers as JSON; dump=file.json keeps the raw frames.
// Needs `npm ci` and `npm run build` in Reader/desktop/reader first.
import {createServer} from 'node:http';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const {chromium, webkit} = await import(pathToFileURL(path.resolve(import.meta.dirname, '../Reader/desktop/reader/node_modules/playwright/index.mjs')).href);
const o = Object.fromEntries(process.argv.slice(2).map(a => a.split('=')));
const root = process.env.DIST ?? path.resolve(import.meta.dirname, '../Reader/desktop/reader/dist');
const prose = 'The ferry crossed slowly while the gulls kept pace with the wake. She rested the book on her knees and watched the light change on the opposite bank.';
const book = {editionId: 'slide-fixture', title: 'Across the Water', language: 'en', readingProgression: 'ltr', contentProgress: true,
  readingOrder: [1, 2].map(n => ({href: `c${n}.html`, type: 'text/html', title: `Chapter ${n}`})),
  resources: [1, 2].map(n => ({href: `c${n}.html`, type: 'text/html', dataBase64: Buffer.from(`<!doctype html><html><head><title>Chapter ${n}</title></head><body><h1>Chapter ${n}</h1>${Array.from({length: +(o.paras ?? 120)}, (_, i) => `<p id="c${n}p${i}">${n}.${i + 1} — ${prose}</p>`).join('')}</body></html>`).toString('base64')}))};
const server = createServer(async (req, res) => { try { const file = path.resolve(root, '.' + new URL(req.url, 'http://x').pathname); res.setHeader('Content-Type', {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css'}[path.extname(file)] ?? 'application/octet-stream'); res.end(await readFile(file)); } catch { res.writeHead(404).end(); } });
await new Promise(r => server.listen(0, '127.0.0.1', r));
const engine = o.engine ?? 'chromium';
const browser = engine === 'webkit' ? await webkit.launch() : await chromium.launch({executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true});
const page = await browser.newPage({viewport: {width: +(o.w ?? 1500), height: +(o.h ?? 860)}, reducedMotion: o.reduced ? 'reduce' : 'no-preference'});
const errors = []; page.on('pageerror', e => errors.push(String(e)));
await page.addInitScript(() => { window.__stillleafGardenDebug = true; });
await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
await page.waitForFunction(() => window.StillleafReader);
await page.evaluate(b => window.StillleafReader.open(b), book);
await page.evaluate(() => window.StillleafReader.nativeControl({version: 1, editionId: 'slide-fixture', id: 1, command: 'activate'}));
await page.evaluate(c => window.StillleafReader.setPreferences({columns: c, fontFamily: 'literata', fontSize: 1.1}), o.columns ?? 'two');
await page.waitForTimeout(1500);

await page.evaluate(() => {
  window.__rec = {start() {
    const r = this; r.frames = []; r.events = []; r.longtasks = []; r.token = (r.token ?? 0) + 1; const token = r.token; r.running = true; r.last = performance.now(); r.t0 = r.last;
    try { r.po = new PerformanceObserver(l => r.longtasks.push(...l.getEntries().map(e => ({start: e.startTime, duration: e.duration})))); r.po.observe({entryTypes: ['longtask']}); } catch {}
    const sample = now => {
      if (r.token !== token) return;
      const stage0 = document.querySelector('.reader-page-slide'), state = stage0?.dataset.state, stage = state && state !== 'idle' ? stage0 : null, track = stage0?.firstElementChild, a = track?.getAnimations()[0];
      r.frames.push({t: now, dt: now - r.last, stage: !!stage, vis: state === 'active', anim: a ? a.playState : null, ct: a ? Number(a.currentTime) : null,
        x: track ? new DOMMatrix(getComputedStyle(track).transform).m41 : null, snaps: stage ? stage.querySelectorAll('iframe').length : 0, state});
      r.last = now; if (r.running && r.token === token) requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
    r.mo = new MutationObserver(list => { for (const m of list) for (const n of [...m.addedNodes, ...m.removedNodes]) if (n.classList?.contains('reader-page-slide')) r.events.push({t: performance.now(), what: m.addedNodes.length ? 'stage-added' : 'stage-removed'}); });
    r.mo.observe(document.getElementById('reading-viewport'), {childList: true});
    return r.t0;
  }, stop() { this.running = false; this.mo.disconnect(); this.po?.disconnect(); return {t0: this.t0, frames: this.frames, events: this.events, longtasks: this.longtasks}; }};
});
await page.waitForFunction(() => { const d = window.StillleafReader.slideDebug?.(); return !d || (d.frames === 2 && d.fresh); }, null, {timeout: 40000});
await page.waitForTimeout(+(o.settle ?? 1500));
const turns = [];
const n = +(o.turns ?? 6);
for (let i = 0; i < n; i++) {
  await page.evaluate(() => window.__rec.start());
  const call = await page.evaluate(() => performance.now());
  if (o.mode === 'key') await page.keyboard.press('ArrowRight'); else await page.evaluate(() => { window.__done = window.StillleafReader.next(); });
  await page.waitForTimeout(900);
  const rec = await page.evaluate(() => window.__rec.stop());
  turns.push({call, ...rec});
}
function analyse(t) {
  const f = t.frames, first = (p) => f.findIndex(p);
  const iStage = first(x => x.stage), iVis = first(x => x.vis), iAnim = first(x => x.anim === 'running' || (x.ct ?? -1) > 0), iEnd = f.findIndex((x, i) => i > iAnim && iAnim >= 0 && !x.stage), iAnimEnd = f.findIndex((x, i) => i > iAnim && iAnim >= 0 && x.anim == null);
  const anim = f.slice(iAnim, iAnimEnd < 0 ? f.length : iAnimEnd);
  const ct = anim.map(x => x.ct).filter(x => x != null);
  const xs = anim.map(x => x.x).filter(x => x != null);
  const dts = anim.map(x => x.dt);
  const total = f[iAnimEnd]?.t - f[iStage]?.t;
  return {
    latencyToStage: f[iStage] ? +(f[iStage].t - t.call).toFixed(1) : null,
    latencyToVisible: f[iVis] ? +(f[iVis].t - t.call).toFixed(1) : null,
    latencyToAnimation: f[iAnim] ? +(f[iAnim].t - t.call).toFixed(1) : null,
    animFrames: anim.length, animMs: anim.length ? +(anim.at(-1).t - anim[0].t).toFixed(1) : null,
    maxAnimDt: +Math.max(0, ...dts.slice(1)).toFixed(1), animLongFrames: dts.slice(1).filter(d => d > 18.5).length,
    totalMs: total ? +total.toFixed(1) : null,
    maxDtAll: +Math.max(...f.slice(1, iAnimEnd < 0 ? f.length : iAnimEnd + 1).map(x => x.dt)).toFixed(1), allLongFrames: f.slice(1, iAnimEnd < 0 ? f.length : iAnimEnd + 1).filter(x => x.dt > 18.5).length,
    longTasks: t.longtasks.filter(l => f[iAnimEnd] && l.start < f[iAnimEnd].t && l.start + l.duration > t.call).map(l => +l.duration.toFixed(0)),
    xRange: xs.length ? [Math.round(xs[0]), Math.round(xs.at(-1))] : null, maxCt: ct.length ? Math.max(...ct) : null,
    xStep: xs.length > 2 ? +Math.max(...xs.slice(1).map((x, i) => Math.abs(x - xs[i]))).toFixed(0) : null,
    events: t.events.map(e => [e.what, +(e.t - t.call).toFixed(0)])
  };
}
const results = turns.map(analyse);
const num = k => results.map(r => r[k]).filter(v => v != null);
const avg = k => { const v = num(k); return v.length ? +(v.reduce((a, b) => a + b, 0) / v.length).toFixed(1) : null; };
console.log(JSON.stringify({engine, columns: o.columns ?? 'two', mode: o.mode ?? 'api', summary: {latencyToAnimation: avg('latencyToAnimation'), animMs: avg('animMs'), maxAnimDt: Math.max(...num('maxAnimDt')), animLongFrames: num('animLongFrames').reduce((a, b) => a + b, 0), maxDtAll: Math.max(...num('maxDtAll')), allLongFrames: num('allLongFrames').reduce((a, b) => a + b, 0), totalMs: avg('totalMs')}, perTurn: results, errors}, null, 1));
if (o.dump) await writeFile(o.dump, JSON.stringify(turns));
await browser.close(); server.close();
