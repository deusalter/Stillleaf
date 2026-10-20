// Input-path cost of the reader in headless Chromium or WebKit: main-thread work and frame pacing around page turns,
// a chapter crossing, continuous scrolling and idle. Nothing opens a visible window.
//   node scripts/measure-reader-lag.mjs scenario=turn|chapter|scroll|idle|boot engine=chromium|webkit dpr=2 w=1500 h=860
//        paras=1500 chapters=3 turns=5 start=0.9 prof=1 dist=<dir> reps=8
// scenario=boot opens `reps` fresh pages and reports, per page, when the renderer script has loaded and run
// (window.StillleafReader assigned, ms after navigation) and how long open() of the fixture takes; medians last.
// Per window it prints frames over 20 / 50 ms, main-thread time blocked (a 4 ms timer's lateness), key-to-animation
// latency, long tasks, and in Chromium the Script / Task / Layout / RecalcStyle time (CDP Performance.getMetrics).
// prof=1 adds the hottest functions of a Chromium sampling profile; build with `vite build --minify false` to read names.
// Needs `npm ci` and `npm run build` in Reader/desktop/reader first. dist=<dir> measures another build of the reader.
import {createServer} from 'node:http';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const reader = path.resolve(import.meta.dirname, '../Reader/desktop/reader');
const {chromium, webkit} = await import(pathToFileURL(path.join(reader, 'node_modules/playwright/index.mjs')).href);
const o = Object.fromEntries(process.argv.slice(2).map(a => a.split('=')));
const root = o.dist ?? path.join(reader, 'dist');
const N = +(o.chapters ?? 3), P = +(o.paras ?? 1500), scenario = o.scenario ?? 'turn';
const prose = 'The ferry crossed slowly while the gulls kept pace with the wake. She rested the book on her knees and watched the light change on the opposite bank. <em>Nothing</em> moved quickly there; even the <a href="#x">tide</a> seemed to wait.';
const chapters = Array.from({length: N}, (_, i) => i + 1);
const scroll = scenario === 'scroll';
const book = {editionId: 'perf-fixture', title: 'Across the Water', language: 'en', readingProgression: 'ltr', contentProgress: true, experimentalContinuous: scroll,
  readingOrder: chapters.map(n => ({href: `c${n}.html`, type: 'text/html', title: `Chapter ${n}`})),
  resources: chapters.map(n => ({href: `c${n}.html`, type: 'text/html', dataBase64: Buffer.from(`<!doctype html><html><head><title>Chapter ${n}</title></head><body><h1>Chapter ${n}</h1>${Array.from({length: P}, (_, i) => `<p id="c${n}p${i}">${n}.${i + 1} — ${prose}</p>`).join('')}</body></html>`).toString('base64')}))};
const server = createServer(async (req, res) => { try { const file = path.resolve(root, '.' + new URL(req.url, 'http://x').pathname); res.setHeader('Content-Type', {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css'}[path.extname(file)] ?? 'application/octet-stream'); res.end(await readFile(file)); } catch { res.writeHead(404).end(); } });
await new Promise(r => server.listen(0, '127.0.0.1', r));
const engine = o.engine ?? 'chromium';
const browser = engine === 'webkit' ? await webkit.launch() : await chromium.launch({executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true});
const ctx = await browser.newContext({viewport: {width: +(o.w ?? 1500), height: +(o.h ?? 860)}, deviceScaleFactor: +(o.dpr ?? 2), reducedMotion: 'no-preference'});
const page = await ctx.newPage();
const errors = []; page.on('pageerror', e => errors.push(String(e)));
if (scenario === 'boot') {
  const runs = [];
  for (let i = 0; i < +(o.reps ?? 8); i++) {
    const fresh = await ctx.newPage();
    fresh.on('pageerror', e => errors.push(String(e)));
    await fresh.addInitScript(() => { let api; Object.defineProperty(window, 'StillleafReader', {configurable: true, get: () => api, set: v => { api = v; window.__bootAt = performance.now(); }}); });
    await fresh.goto(`http://127.0.0.1:${server.address().port}/index.html`);
    await fresh.waitForFunction(() => window.__bootAt);
    const open = await fresh.evaluate(async b => { const t = performance.now(); await window.StillleafReader.open(b); return performance.now() - t; }, book);
    runs.push({boot: Math.round(await fresh.evaluate(() => window.__bootAt)), open: Math.round(open)});
    await fresh.close();
  }
  const median = k => runs.map(r => r[k]).sort((a, b) => a - b)[runs.length >> 1];
  console.log(JSON.stringify({engine, scenario, dist: root, runs, medianBoot: median('boot'), medianOpen: median('open'), errors}));
  await Promise.race([browser.close(), new Promise(resolve => setTimeout(resolve, 3000))]); server.close(); process.exit(0);
}
await page.addInitScript(() => { window.__stillleafGardenDebug = true; });
await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
await page.waitForFunction(() => window.StillleafReader);
await page.evaluate(b => window.StillleafReader.open(b), book);
await page.evaluate(() => window.StillleafReader.nativeControl({version: 1, editionId: 'perf-fixture', id: 1, command: 'activate'}));
await page.evaluate(([c, s]) => window.StillleafReader.setPreferences({columns: c, fontFamily: 'literata', fontSize: 1.1, scroll: s}), [o.columns ?? 'two', scroll]);
await page.waitForTimeout(1500);
if (!scroll) await page.waitForFunction(() => { const d = window.StillleafReader.slideDebug?.(); return !d || (d.frames === 2 && d.fresh); }, null, {timeout: 60000});
// settle: garden fade-in, pagination idle
await page.waitForTimeout(+(o.settle ?? 4000));
await page.evaluate(() => {
  window.__p = {
    start() {
      const r = this; r.frames = []; r.gaps = []; r.running = true; r.last = performance.now(); r.t0 = r.last; r.lastTick = r.t0; r.stageActiveAt = null; r.animAt = null;
      r.longtasks = []; try { r.po = new PerformanceObserver(l => r.longtasks.push(...l.getEntries().map(e => +e.duration.toFixed(0)))); r.po.observe({entryTypes: ['longtask']}); } catch {}
      const sample = now => { if (!r.running) return; r.frames.push(now - r.last); r.last = now;
        const st = document.querySelector('.reader-page-slide'), tr = st?.firstElementChild, a = tr?.getAnimations()[0];
        if (r.animAt == null && a && a.playState === 'running' && Number(a.currentTime) > 0) r.animAt = now - r.t0;
        requestAnimationFrame(sample); };
      requestAnimationFrame(sample);
      r.timer = setInterval(() => { const n = performance.now(), g = n - r.lastTick - 4; r.lastTick = n; if (g > 0) r.gaps.push(g); }, 4);
    },
    stop() { this.running = false; clearInterval(this.timer); this.po?.disconnect(); const f = this.frames.slice(1), g = this.gaps;
      const sum = a => a.reduce((x, y) => x + y, 0);
      return {frames: f.length, maxFrame: Math.max(0, ...f), over20: f.filter(x => x > 20).length, over50: f.filter(x => x > 50).length, blockedMs: sum(g.filter(x => x > 8)), maxBlock: Math.max(0, ...g), longtasks: this.longtasks, animAt: this.animAt}; }
  };
});
let cdp = null;
if (engine === 'chromium') { cdp = await ctx.newCDPSession(page); await cdp.send('Performance.enable'); }
const metrics = async () => { if (!cdp) return null; const {metrics} = await cdp.send('Performance.getMetrics'); return Object.fromEntries(metrics.map(m => [m.name, m.value])); };
const diff = (a, b) => a && b ? Object.fromEntries(['ScriptDuration', 'TaskDuration', 'LayoutDuration', 'RecalcStyleDuration'].map(k => [k.replace('Duration', ''), Math.round((b[k] - a[k]) * 1000)])) : null;
const results = [];
async function windowed(label, action, ms) {
  await page.evaluate(() => window.__p.start());
  if (o.prof && cdp) { await cdp.send('Profiler.enable'); await cdp.send('Profiler.setSamplingInterval', {interval: 200}); await cdp.send('Profiler.start'); }
  const m0 = await metrics(); const t0 = Date.now();
  await action();
  await page.waitForTimeout(ms);
  const m1 = await metrics();
  const r = await page.evaluate(() => window.__p.stop());
  let top = null;
  if (o.prof && cdp) {
    const {profile} = await cdp.send('Profiler.stop'); const self = new Map(); const dt = profile.timeDeltas; const byId = new Map(profile.nodes.map(n => [n.id, n]));
    profile.samples.forEach((id, i) => { const n = byId.get(id), k = `${n.callFrame.functionName || '(anon)'} ${n.callFrame.url.split('/').pop()}:${n.callFrame.lineNumber}`; self.set(k, (self.get(k) ?? 0) + (dt[i] ?? 0) / 1000); });
    top = [...self].sort((a, b) => b[1] - a[1]).slice(0, +(o.top ?? 14)).map(([k, v]) => `${v.toFixed(0)}ms ${k}`);
  }
  const info = await page.evaluate(() => { const g = window.StillleafReader.gardenDebug?.(false); return {href: window.StillleafReader.bookmark()?.href, prog: +(window.StillleafReader.bookmark()?.locations?.progression ?? 0).toFixed(3), cells: g?.cells.length, ticks: g?.ticks, drawMs: Math.round(g?.drawMs ?? 0), slowestDraw: Math.round(g?.slowestDraw ?? 0), on: g?.on, mode: g?.mode, ambient: g?.ambient?.frames}; });
  results.push({label, ...r, cpu: diff(m0, m1), info, top});
}
if (o.start) { await page.evaluate(p => window.StillleafReader.go({href: 'c1.html', type: 'text/html', locations: {progression: +p}}), o.start); await page.waitForTimeout(3500); await page.waitForFunction(() => { const d = window.StillleafReader.slideDebug?.(); return !d || (d.frames === 2 && d.fresh); }, null, {timeout: 60000}).catch(() => {}); await page.waitForTimeout(2500); }
if (scenario === 'chapter') {
  const toEnd = async () => { await page.evaluate(() => window.StillleafReader.go({href: 'c1.html', type: 'text/html', locations: {progression: 0.9999}})); await page.waitForTimeout(3500); await page.waitForFunction(() => { const d = window.StillleafReader.slideDebug?.(); return !d || (d.frames === 2 && d.fresh); }, null, {timeout: 60000}); await page.waitForTimeout(2500); };
  await toEnd(); let k = 0;
  while (k < 6) { k++; await page.keyboard.press('ArrowRight'); await page.waitForTimeout(1300); if ((await page.evaluate(() => window.StillleafReader.bookmark().href)) !== 'c1.html') break; }
  await toEnd(); for (let i = 0; i < k - 1; i++) { await page.keyboard.press('ArrowRight'); await page.waitForTimeout(1300); }
  await page.waitForTimeout(3000); results.push({crossingPress: k});
}
if (scenario === 'turn' || scenario === 'chapter') {
  const n = +(o.turns ?? 5);
  for (let i = 0; i < n; i++) {
    await windowed(`turn${i + 1}`, async () => { await page.keyboard.press('ArrowRight'); }, scenario === 'chapter' ? 13000 : +(o.window ?? 2500));
    if (scenario === 'chapter') break;
  }
} else if (scenario === 'scroll') {
  await page.mouse.move(700, 400);
  for (let i = 0; i < +(o.turns ?? 3); i++) await windowed(`scroll${i + 1}`, async () => { for (let k = 0; k < 60; k++) { await page.mouse.wheel(0, 70); await page.waitForTimeout(16); } }, 1500);
} else if (scenario === 'idle') {
  await windowed('idle', async () => {}, 6000);
}
console.log(JSON.stringify({engine, dpr: o.dpr ?? 2, scenario, paras: P, results, errors}, null, 1));
await Promise.race([browser.close(), new Promise(resolve => setTimeout(resolve, 3000))]); server.close(); process.exit(0);
