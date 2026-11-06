// Renders the reader at full-screen sizes for every theme and mode and reports how many colours make up the surface
// around the text. Writes PNGs and report.json; Books reference images never come through here.
//   node scripts/render-reader-surface.mjs out=/tmp/x [dist=path] [engine=webkit] [sizes=1512x982,3840x2160] [themes=night,paper] [modes=single,facing] [png=all|first] [prefs='{"vines":"margins"}']
// Needs `npm ci` and `npm run build` in Reader/desktop/reader first.
import {mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const here = path.resolve(import.meta.dirname, '../Reader/desktop/reader');
const {SIZES, MODES, serve, launchBrowser, openReader, settle, hideInk, showInk, decodePNG, census, hexAt} = await import(pathToFileURL(path.join(here, 'test/surface-support.mjs')).href);
const o = Object.fromEntries(process.argv.slice(2).map(a => { const i = a.indexOf('='); return [a.slice(0, i), a.slice(i + 1)]; }));
const out = path.resolve(o.out ?? '/tmp/reader-apple-books/surface'), dist = path.resolve(o.dist ?? path.join(here, 'dist')), engine = o.engine ?? 'webkit';
const sizes = o.sizes ? o.sizes.split(',').map(s => s.split('x').map(Number)) : SIZES;
const themes = (o.themes ?? 'system-light,system-dark,original,paper,sepia,calm,focus,quiet,dark,night,white,stone,mist,forest,dusk,midnight,custom').split(',');
const modes = (o.modes ?? Object.keys(MODES).join(',')).split(',');
await mkdir(out, {recursive: true});
const server = await serve(dist), browser = await launchBrowser(engine), report = [];
try {
  for (const [width, height] of sizes) for (const mode of modes) {
    for (const scheme of [false, true]) {
      const list = themes.filter(t => t.startsWith('system') ? t === (scheme ? 'system-dark' : 'system-light') : !scheme);
      if (!list.length) continue;
      const {page, context} = await openReader(browser, server.url, {width, height, dark: scheme, preferences: {...MODES[mode], ...JSON.parse(o.prefs ?? '{}')}});
      await settle(page, 700);
      for (const theme of list) {
        const id = theme.startsWith('system') ? 'system' : theme;
        await page.evaluate(id => window.StillleafReader.setPreferences(id === 'custom' ? {theme: 'custom', backgroundColor: '#2a3550', textColor: '#f0f0e8'} : {theme: id, backgroundColor: null, textColor: null}), id);
        await settle(page, 300);
        const name = `${width}x${height}-${mode}-${theme}`;
        const shot = await page.screenshot();
        if (o.png !== 'none') await writeFile(path.join(out, name + '.png'), shot);
        await hideInk(page);
        const surface = decodePNG(await page.screenshot()), colours = census(surface);
        await showInk(page);
        const facts = await page.evaluate(() => {
          const rect = s => { const r = document.querySelector(s)?.getBoundingClientRect(); return r ? {left: r.left, right: r.right, top: r.top, bottom: r.bottom} : null; };
          const style = getComputedStyle(document.documentElement);
          return {paper: style.getPropertyValue('--paper').trim(), backdrop: style.getPropertyValue('--backdrop').trim(), classes: document.documentElement.className, viewport: rect('#reading-viewport'), footer: rect('.reading-footer')};
        });
        const entry = {name, width, height, mode, theme, colours: colours.length, top: colours.slice(0, 6), corner: hexAt(surface, 4, 4), centre: hexAt(surface, width >> 1, height >> 1), ...facts};
        report.push(entry);
        console.log(`${name.padEnd(38)} ${String(colours.length).padStart(5)} colours  corner ${entry.corner}  centre ${entry.centre}  ${entry.classes}`);
      }
      await context.close();
    }
  }
} finally { await browser.close(); server.close(); }
await writeFile(path.join(out, 'report.json'), JSON.stringify(report, null, 1));
const failing = report.filter(r => r.colours !== 1);
console.log(`${report.length} renders, ${failing.length} with more than one surface colour`);
