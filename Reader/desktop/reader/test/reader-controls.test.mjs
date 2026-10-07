import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile, mkdir} from 'node:fs/promises';
import path from 'node:path';
import {chromium, webkit} from 'playwright';

// The reader's panels (Contents, Search, Appearance) are one family: same glass,
// header, rows and close behaviour. These checks pin that family down.
const output = process.env.READER_CONTROLS_OUTPUT || '/tmp/reader-controls';
const chapter = title => `<html><body><h1>${title}</h1>${'<p>The light fell across the open book. She turned a page and settled into her chair.</p>'.repeat(40)}</body></html>`;
const book = {
  editionId: 'reader-controls', title: 'At the lakeside', contentProgress: true,
  readingOrder: [{href: 'one.html', type: 'text/html', title: 'The shore'}, {href: 'two.html', type: 'text/html', title: 'The long water'}, {href: 'three.html', type: 'text/html', title: 'Evening'}],
  resources: [['one.html', 'The shore'], ['two.html', 'The long water'], ['three.html', 'Evening']].map(([href, title]) => ({href, type: 'text/html', dataBase64: Buffer.from(chapter(title)).toString('base64')})),
};

async function emulateTransparency(page, value) {
  const session = await page.context().newCDPSession(page);
  await session.send('Emulation.setEmulatedMedia', {features: [{name: 'prefers-reduced-transparency', value}]});
}

async function launch(t, viewport = {width: 1100, height: 860}) {
  const root = path.resolve(import.meta.dirname, '../dist');
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
  const browser = process.env.READER_TEST_BROWSER === 'webkit' ? await webkit.launch()
    : await chromium.launch({executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true});
  t.after(() => browser.close());
  const page = await browser.newPage({viewport, reducedMotion: 'reduce'});
  // The host's own Reduce Transparency setting (CI runners have it on) must not decide what these tests see.
  if (browser.browserType() === chromium) await emulateTransparency(page, 'no-preference');
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  await page.evaluate(input => window.StillleafReader.open(input), book);
  await mkdir(output, {recursive: true});
  return page;
}

const PANELS = [
  {id: 'library-panel', trigger: '#contents', name: 'contents'},
  {id: 'search-panel', trigger: '#search', name: 'search'},
  {id: 'appearance-panel', trigger: '#appearance', name: 'appearance'},
];

const luminance = ([r, g, b]) => [r, g, b].map(v => { v /= 255; return v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4; }).reduce((sum, v, i) => sum + v * [.2126, .7152, .0722][i], 0);
const ratio = (a, b) => { const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x); return (hi + .05) / (lo + .05); };
// Computed colours arrive as rgb()/rgba() or, for color-mix(), as color(srgb r g b / a) with 0-1 channels.
const parseColor = text => {
  const srgb = text.match(/color\(srgb ([^)]+)\)/);
  if (srgb) { const [r, g, b, a = 1] = srgb[1].split(/[ /]+/).filter(Boolean).map(Number); return {rgb: [r, g, b].map(v => v * 255), alpha: a}; }
  const [r, g, b, a = 1] = text.match(/rgba?\(([^)]+)\)/)[1].split(/[ ,/]+/).filter(Boolean).map(Number);
  return {rgb: [r, g, b], alpha: a};
};
const over = (top, bottom) => top.rgb.map((v, i) => v * top.alpha + bottom[i] * (1 - top.alpha));

// What the stylesheet declares for the glass, resolved through its variable. WebKit on a Mac that has
// Reduce Transparency on reports a computed backdrop filter of none, so the declaration is the evidence there.
const declaredFilter = page => page.evaluate(() => {
  for (const sheet of document.styleSheets) for (const rule of sheet.cssRules) {
    if (rule.selectorText?.replace(/\s/g, '') === '.panel,.note-panel' && rule.style.getPropertyValue('border-radius') === 'var(--panel-radius)') {
      const value = rule.style.getPropertyValue('backdrop-filter') || rule.style.getPropertyValue('-webkit-backdrop-filter');
      const name = value.match(/var\((--[\w-]+)\)/)?.[1];
      return name ? getComputedStyle(document.documentElement).getPropertyValue(name).trim() : value;
    }
  }
  return '';
});

const surface = (page, id) => page.evaluate(id => {
  const panel = document.getElementById(id), s = getComputedStyle(panel), heading = getComputedStyle(panel.querySelector('.panel-heading')), root = getComputedStyle(document.documentElement);
  return {filter: s.backdropFilter || s.webkitBackdropFilter, background: s.backgroundColor, radius: s.borderTopLeftRadius, shadow: s.boxShadow, border: s.borderTopWidth + ' ' + s.borderTopStyle,
    headingSize: heading.fontSize, headingWeight: heading.fontWeight, headingPad: heading.padding, ink: root.getPropertyValue('--ink').trim(), paper: root.getPropertyValue('--paper').trim(), panelColor: root.getPropertyValue('--panel').trim()};
}, id);

test('appearance panel is grouped, with advanced typography behind a disclosure', {timeout: 60000}, async t => {
  const page = await launch(t);
  await page.locator('#appearance').click();
  const groups = await page.locator('#appearance-panel section[data-group]').evaluateAll(nodes => nodes.map(n => [n.dataset.group, n.querySelector('h3')?.textContent]));
  assert.deepEqual(groups, [['theme', 'Theme'], ['text', 'Text'], ['layout', 'Layout'], ['garden', 'Garden']]);
  const placement = id => page.locator('#' + id).evaluate(node => node.closest('section[data-group]')?.dataset.group ?? (node.closest('details.advanced-appearance') ? 'advanced' : null));
  for (const [id, group] of Object.entries({'theme-options': 'theme', 'font-options': 'text', 'font-size': 'text', 'font-weight': 'text', 'line-height': 'text', 'reading-mode': 'layout', margins: 'layout', 'side-margin': 'layout', 'content-width': 'layout', measure: 'layout', immersive: 'layout', vines: 'garden',
    'letter-spacing': 'advanced', 'word-spacing': 'advanced', 'text-align': 'advanced', hyphens: 'advanced', 'background-color': 'advanced', 'text-color': 'advanced'})) {
    assert.equal(await placement(id), group, `${id} belongs to ${group}`);
  }
  const advanced = page.locator('#appearance-panel details.advanced-appearance');
  assert.equal(await advanced.evaluate(node => node.open), false, 'advanced typography starts collapsed');
  assert.equal(await page.locator('#letter-spacing').isVisible(), false);
  assert.equal(await page.locator('#font-size').isVisible(), true, 'everyday controls are not hidden');
  assert.equal(await page.locator('#appearance-panel details.advanced-appearance > summary').textContent(), 'Advanced');
  await page.locator('#appearance-panel details.advanced-appearance > summary').click();
  for (const id of ['letter-spacing', 'word-spacing', 'text-align', 'hyphens', 'background-color', 'text-color']) assert.equal(await page.locator('#' + id).isVisible(), true, `${id} is revealed`);
  const metrics = await page.locator('#appearance-panel .panel-body').evaluate(node => ({scrolls: node.scrollHeight > node.clientHeight, sections: [...node.querySelectorAll('section[data-group]')].map(s => s.getBoundingClientRect().height)}));
  assert.ok(metrics.sections.every(h => h > 60), 'sections are roomy');
  assert.ok(metrics.scrolls, 'the body scrolls rather than the panel growing past the window');
  await page.screenshot({path: path.join(output, 'appearance-advanced.png')});
});

test('every panel shares one light glass surface and header', {timeout: 90000}, async t => {
  const page = await launch(t);
  const browser = page.context().browser();
  // WebKit cannot emulate this preference, so on a host that has Reduce Transparency on (CI runners do),
  // the honest check is that every panel is opaque.
  if (await page.evaluate(() => matchMedia('(prefers-reduced-transparency: reduce)').matches)) {
    for (const panel of PANELS) {
      await page.locator(panel.trigger).click();
      const s = await surface(page, panel.id);
      assert.ok(!/blur/.test(s.filter) && parseColor(s.background).alpha === 1, `${panel.name} is opaque on a host that reduces transparency`);
      await page.keyboard.press('Escape');
    }
    return;
  }
  const seen = [];
  for (const panel of PANELS) {
    await page.locator(panel.trigger).click();
    const measured = await surface(page, panel.id);
    assert.match(await declaredFilter(page), /blur\(\d+px\)/, 'the stylesheet declares the glass blur');
    if (browser.browserType() !== chromium && measured.filter === 'none') measured.filter = await declaredFilter(page);
    seen.push({name: panel.name, ...measured});
    await page.screenshot({path: path.join(output, `${panel.name}-paper.png`)});
    await page.keyboard.press('Escape');
  }
  for (const s of seen) {
    const blur = Number(s.filter.match(/blur\(([\d.]+)px\)/)?.[1]);
    assert.ok(blur >= 4 && blur <= 14, `${s.name} blur is light (${s.filter})`);
    const fill = parseColor(s.background);
    assert.ok(fill.alpha >= .6 && fill.alpha <= .92, `${s.name} fill is translucent but legible (${s.background})`);
    for (const key of ['filter', 'background', 'radius', 'shadow', 'border', 'headingSize', 'headingWeight', 'headingPad']) assert.equal(s[key], seen[0][key], `${s.name} shares ${key}`);
    assert.match(s.shadow, /inset/, `${s.name} has a crisp inner rim`);
  }
  // Reduced transparency makes the same surface opaque, whether the host or the system asks for it.
  if (browser.browserType() === chromium) {
    await emulateTransparency(page, 'reduce');
    for (const panel of PANELS) {
      await page.locator(panel.trigger).click();
      const s = await surface(page, panel.id);
      assert.ok(!/blur/.test(s.filter) && parseColor(s.background).alpha === 1, `${panel.name} is opaque under prefers-reduced-transparency`);
      await page.keyboard.press('Escape');
    }
    await emulateTransparency(page, 'no-preference');
  }
  await page.evaluate(() => document.body.classList.add('native-reduceTransparency'));
  for (const panel of PANELS) {
    await page.locator(panel.trigger).click();
    const s = await surface(page, panel.id);
    assert.ok(s.filter === 'none' || !/blur/.test(s.filter), `${panel.name} drops blur`);
    assert.equal(parseColor(s.background).alpha, 1, `${panel.name} is opaque`);
    await page.keyboard.press('Escape');
  }
});

test('panel text keeps AA contrast on the glass in every theme', {timeout: 120000}, async t => {
  const page = await launch(t);
  const failures = [];
  for (const theme of ['system', 'original', 'paper', 'sepia', 'calm', 'focus', 'quiet', 'dark', 'night', 'white', 'stone', 'mist', 'forest', 'dusk', 'midnight']) {
    await page.evaluate(theme => window.StillleafReader.setPreferences({theme}), theme);
    await page.locator('#appearance').click();
    const probe = await page.evaluate(() => {
      const panel = document.getElementById('appearance-panel'), s = getComputedStyle(panel);
      return {fill: s.backgroundColor, ink: getComputedStyle(panel).color, paper: getComputedStyle(document.documentElement).getPropertyValue('--paper').trim(),
        secondary: getComputedStyle(panel.querySelector('.panel-note, .small-note')).color, summary: getComputedStyle(panel.querySelector('summary')).color,
        scheme: document.documentElement.dataset.theme};
    });
    const paper = await page.evaluate(() => { const c = document.createElement('canvas').getContext('2d'); c.fillStyle = getComputedStyle(document.documentElement).getPropertyValue('--paper'); return c.fillStyle; });
    const hex = paper.startsWith('#') ? [1, 3, 5].map(i => parseInt(paper.slice(i, i + 2), 16)) : parseColor(paper).rgb;
    const base = over(parseColor(probe.fill), hex);
    for (const key of ['ink', 'secondary', 'summary']) {
      const r = ratio(parseColor(probe[key]).rgb, base);
      if (r < 4.5) failures.push(`${theme}/${key}: ${r.toFixed(2)}`);
    }
    await page.keyboard.press('Escape');
  }
  assert.deepEqual(failures, []);
});

test('contents, search and saved rows share one row style and the same close behaviour', {timeout: 90000}, async t => {
  const page = await launch(t);
  await page.evaluate(() => window.StillleafReader.setPreferences({theme: 'paper'}));
  // Saved bookmark so the third kind of row exists.
  await page.getByRole('button', {name: 'Add bookmark'}).click();
  const rowStyle = locator => locator.evaluate(node => { const s = getComputedStyle(node); return {pad: s.padding, radius: s.borderTopLeftRadius, size: s.fontSize, weight: s.fontWeight, min: s.minHeight}; });
  await page.locator('#contents').click();
  const chapterRow = page.locator('#library-panel .chapter-button:not([aria-current=true])').first();
  const base = await rowStyle(chapterRow);
  await page.getByRole('tab', {name: 'Bookmarks'}).click();
  const saved = await rowStyle(page.locator('#library-panel .saved-link').first());
  await page.getByRole('tab', {name: 'Contents'}).click();
  await page.keyboard.press('Escape');
  await page.locator('#search').click();
  await page.locator('#search-query').fill('light');
  await page.locator('#search-results .result-link').first().waitFor();
  const result = await rowStyle(page.locator('#search-results .result-link').first());
  for (const [name, row] of [['saved', saved], ['search result', result]]) {
    for (const key of ['radius', 'size', 'weight', 'min']) assert.equal(row[key], base[key], `${name} row shares ${key}`);
    assert.equal(row.pad, base.pad, `${name} row shares padding`);
  }
  const hover = async locator => { await locator.hover(); return locator.evaluate(node => getComputedStyle(node).backgroundColor); };
  const resultHover = await hover(page.locator('#search-results .result-link').nth(1));
  // Escape in a search field clears the text first, so use the close button here.
  await page.locator('#search-panel [data-close]').click();
  await page.locator('#contents').click();
  const rowHover = await hover(page.locator('#library-panel .chapter-button').nth(1));
  assert.equal(rowHover, resultHover, 'hover state is shared');
  assert.notEqual(rowHover, 'rgba(0, 0, 0, 0)', 'rows visibly react to hover');
  const selected = await page.locator('#library-panel .chapter-button[aria-current=true]').evaluate(node => getComputedStyle(node).backgroundColor);
  assert.notEqual(selected, 'rgba(0, 0, 0, 0)', 'the current chapter is marked');
  assert.notEqual(selected, rowHover, 'selection is distinct from hover');
  await page.screenshot({path: path.join(output, 'contents-rows.png')});
  await page.keyboard.press('Escape');

  // Close behaviour: Escape, the close button and a click outside all close and return focus to the trigger.
  for (const panel of PANELS) {
    for (const how of ['escape', 'button', 'outside']) {
      await page.locator(panel.trigger).click();
      assert.equal(await page.locator('#' + panel.id).evaluate(node => node.open), true, `${panel.name} opens`);
      assert.equal(await page.locator(`#${panel.id} [data-close]`).count(), 1, `${panel.name} has one labelled close button`);
      if (how === 'escape') await page.keyboard.press('Escape');
      else if (how === 'button') await page.locator(`#${panel.id} [data-close]`).click();
      else await page.mouse.click(550, 840);
      assert.equal(await page.locator('#' + panel.id).evaluate(node => node.open), false, `${panel.name} closes by ${how}`);
      assert.equal(await page.evaluate(() => document.activeElement.id), panel.trigger.slice(1), `${panel.name} returns focus after ${how}`);
    }
  }
});

test('panel screenshots in dark and compact windows', {timeout: 90000}, async t => {
  const page = await launch(t);
  await page.evaluate(() => window.StillleafReader.setPreferences({theme: 'dark'}));
  for (const panel of PANELS) {
    await page.locator(panel.trigger).click();
    await page.screenshot({path: path.join(output, `${panel.name}-dark.png`)});
    await page.keyboard.press('Escape');
  }
  await page.setViewportSize({width: 430, height: 700});
  await page.waitForTimeout(300);
  await page.locator('#appearance').click();
  const box = await page.locator('#appearance-panel').boundingBox();
  assert.ok(box.x >= 0 && box.x + box.width <= 430 && box.y >= 0 && box.y + box.height <= 700, 'compact panel stays inside the window');
  await page.screenshot({path: path.join(output, 'appearance-compact.png')});
});
