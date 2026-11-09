// The page and everything around it are one surface. With the ink removed, a full-screen reader must be exactly one colour:
// any card, frame, inset, seam, gradient or colour step in any theme, mode or size fails on a single stray pixel.
// READER_SURFACE_ENGINES=webkit limits the engines; both run by default.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import {THEMES, resolveTheme} from '../src/appearance.js';
import {SIZES, MODES, serve, launchBrowser, openReader, settle, hideInk, showInk, decodePNG, census, uniformColour} from './surface-support.mjs';

const root = path.resolve(import.meta.dirname, '../dist');
const engines = (process.env.READER_SURFACE_ENGINES ?? 'webkit,chromium').split(',');
const CUSTOM = {theme: 'custom', backgroundColor: '#2a3550', textColor: '#f0f0e8'};
const themes = [
  {name: 'system-light', dark: false, set: {theme: 'system', backgroundColor: null, textColor: null}, page: resolveTheme('system', false).background},
  {name: 'system-dark', dark: true, set: {theme: 'system', backgroundColor: null, textColor: null}, page: resolveTheme('system', true).background},
  ...THEMES.filter(t => t.id !== 'custom').map(t => ({name: t.id, dark: false, set: {theme: t.id, backgroundColor: null, textColor: null}, page: t.background})),
  {name: 'custom', dark: false, set: CUSTOM, page: CUSTOM.backgroundColor},
];

/** The whole window, ink removed: one colour, and the theme's own page colour. Polls briefly while a theme change lands. */
async function assertOneSurface(page, expected, label) {
  let image;
  for (let attempt = 0; attempt < 12; attempt++) {
    image = decodePNG(await page.screenshot());
    if (uniformColour(image) === expected.toLowerCase()) return;
    await page.waitForTimeout(150);
  }
  const colours = census(image);
  const strays = colours.slice(0, 5).map(c => `${c.color} ×${c.count} first at ${c.x},${c.y}`).join('; ');
  assert.fail(`${label}: the surface should be only ${expected}, found ${colours.length} colours: ${strays}`);
}

async function suite(t, engine) {
  const server = await serve(root), browser = await launchBrowser(engine);
  t.after(async () => { await browser.close(); server.close(); });
  return {server, browser};
}

for (const engine of engines) {
  for (const [width, height] of SIZES) test(`${engine}: every theme and mode is one surface at ${width}x${height}`, {timeout: 600000}, async t => {
    const {server, browser} = await suite(t, engine);
    for (const [mode, layout] of Object.entries(MODES)) {
      const {page, context, errors} = await openReader(browser, server.url, {width, height, preferences: layout});
      await settle(page, 600);
      await hideInk(page);
      for (const theme of themes) {
        await page.emulateMedia({colorScheme: theme.dark ? 'dark' : 'light'});
        await page.evaluate(set => window.StillleafReader.setPreferences(set), theme.set);
        await assertOneSurface(page, theme.page, `${engine} ${width}x${height} ${mode} ${theme.name}`);
      }
      assert.deepEqual(errors, []);
      await context.close();
    }
  });

  test(`${engine}: the check itself sees text, so a blank window cannot pass`, {timeout: 120000}, async t => {
    const {server, browser} = await suite(t, engine);
    const {page, context} = await openReader(browser, server.url, {width: 1512, height: 982, preferences: MODES.single});
    await settle(page, 600);
    const inked = census(decodePNG(await page.screenshot()));
    assert.ok(inked.length > 20, `only ${inked.length} colours with the text showing`);
    assert.ok(inked[0].share < 0.98, 'the page shows no text');
    await hideInk(page);
    assert.equal(census(decodePNG(await page.screenshot())).length, 1);
    await showInk(page);
    assert.ok(census(decodePNG(await page.screenshot())).length > 20, 'the text did not come back');
    await context.close();
  });

  test(`${engine}: no card or frame in focus reading, under the web bar, or with the garden on`, {timeout: 400000}, async t => {
    const {server, browser} = await suite(t, engine);
    const [width, height] = SIZES[1];
    const cases = [
      ['focus reading', {native: true, preferences: {...MODES.facing, immersive: true}}],
      ['web bar and footer', {native: false, preferences: MODES.facing}],
      ['garden on, single', {native: true, preferences: {...MODES.single, vines: 'margins', vinesChosen: true}}],
      ['garden on, facing', {native: true, preferences: {...MODES.facing, vines: 'margins', vinesChosen: true}}],
    ];
    for (const [label, options] of cases) for (const theme of ['night', 'paper', 'sepia']) {
      const {page, context, errors} = await openReader(browser, server.url, {width, height, ...options});
      await page.evaluate(id => window.StillleafReader.setPreferences({theme: id}), theme);
      await settle(page, 700);
      await hideInk(page);
      await assertOneSurface(page, THEMES.find(x => x.id === theme).background, `${engine} ${label} ${theme}`);
      assert.deepEqual(errors, []);
      await context.close();
    }
  });

  test(`${engine}: a page in mid turn crosses the window with no band, frame or colour step`, {timeout: 200000}, async t => {
    const {server, browser} = await suite(t, engine);
    for (const [width, height] of [SIZES[0], SIZES[3]]) for (const mode of ['single', 'facing']) {
      const {page, context} = await openReader(browser, server.url, {width, height, reducedMotion: 'no-preference', preferences: {...MODES[mode], theme: 'sepia'}});
      await settle(page, 900);
      await page.waitForFunction(() => window.StillleafReader.slideDebug().frames >= 2);
      await page.evaluate(() => {
        const track = () => document.querySelector('.page-slide-track');
        const raw = Element.prototype.animate;
        // Hold the turn half way through its motion, so a frame of it can be examined.
        Element.prototype.animate = function (...args) { const a = raw.apply(this, args); a.pause(); a.currentTime = 90; (window.heldTurn ??= []).push(a); return a; };
        window.turning = window.StillleafReader.next();
        window.turnX = () => new DOMMatrix(getComputedStyle(track()).transform).m41;
      });
      await page.waitForFunction(() => window.heldTurn?.length > 0 && window.turnX() < -1);
      const moving = await page.evaluate(() => ({x: window.turnX(), reader: (r => ({left: r.left, right: r.right}))(document.getElementById('reader').getBoundingClientRect())}));
      assert.ok(moving.x < -1, 'the page is not moving');
      // The stage does not clip at the column: its pages are on the strip at the full window's distance.
      const reach = await page.evaluate(() => [...document.querySelectorAll('.page-slide-snapshot')].map(f => parseFloat(f.style.left)).filter(left => left > -50000));
      const needed = Math.max(moving.reader.right, width - moving.reader.left);
      assert.ok(reach.includes(Math.round(needed * 1000) / 1000) || reach.some(left => Math.abs(left - needed) < 0.5), `the next page starts at ${reach}, not beyond the window (${needed})`);
      assert.equal(await page.evaluate(() => getComputedStyle(document.querySelector('.reader-page-slide')).overflowX), 'visible');
      await hideInk(page);
      await assertOneSurface(page, THEMES.find(x => x.id === 'sepia').background, `${engine} ${width}x${height} ${mode} mid turn`);
      await page.evaluate(() => { for (const a of window.heldTurn) a.finish(); return window.turning; });
      await context.close();
    }
  });
}

test('the garden is off unless it was chosen: saved Off stays, the old default turns off, a choice is kept', {timeout: 120000}, async t => {
  const {server, browser} = await suite(t, engines[0]);
  const stateOf = page => page.evaluate(() => { const {vines, vinesChosen} = window.StillleafReader.exportState().preferences; return {vines, vinesChosen, on: document.documentElement.classList.contains('garden-on')}; });
  const opened = async preferences => { const r = await openReader(browser, server.url, {width: 1400, height: 900, preferences}); await settle(r.page); return r; };

  // A new book, and a book saved while Margins was the default: nobody chose either.
  for (const preferences of [{}, {vines: 'margins'}]) {
    const {page, context} = await opened(preferences);
    assert.deepEqual(await stateOf(page), {vines: 'off', vinesChosen: false, on: false}, JSON.stringify(preferences));
    await context.close();
  }
  // A saved Off stays off.
  {
    const {page, context} = await opened({vines: 'off'});
    assert.deepEqual(await stateOf(page), {vines: 'off', vinesChosen: false, on: false});
    await context.close();
  }
  // Choosing the garden sticks through a save and reopen, and Reset returns to the default.
  const {page, context} = await opened({});
  await page.evaluate(() => window.StillleafReader.setPreferences({vines: 'margins'}));
  await page.waitForTimeout(300);
  assert.deepEqual(await stateOf(page), {vines: 'margins', vinesChosen: true, on: true});
  const saved = await page.evaluate(() => window.StillleafReader.exportState().preferences);
  const reopened = await opened(saved);
  assert.deepEqual(await stateOf(reopened.page), {vines: 'margins', vinesChosen: true, on: true});
  await reopened.context.close();
  await page.evaluate(() => window.StillleafReader.setPreferences({vines: 'off'}));
  await page.waitForTimeout(200);
  assert.deepEqual(await stateOf(page), {vines: 'off', vinesChosen: false, on: false});
  await context.close();
});
