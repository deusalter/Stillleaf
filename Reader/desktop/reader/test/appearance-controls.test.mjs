import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile, mkdir} from 'node:fs/promises';
import path from 'node:path';
import {chromium, webkit} from 'playwright';

test('typography choices support keyboard, saved custom values, and compact footers', {timeout: 45000}, async t => {
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
  const page = await browser.newPage({viewport: {width: 1000, height: 800}, reducedMotion: 'reduce'});
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  const text = '<html><body><h1>At the lakeside</h1>' + '<p>The light fell across the open book. She turned a page and settled into her chair.</p>'.repeat(120) + '</body></html>';
  await page.evaluate(input => window.StillleafReader.open(input), {
    editionId: 'appearance-controls', title: 'At the lakeside', contentProgress: true,
    readingOrder: [{href: 'chapter.html', type: 'text/html'}],
    resources: [{href: 'chapter.html', type: 'text/html', dataBase64: Buffer.from(text).toString('base64')}],
  });
  await page.getByRole('button', {name: 'Appearance', exact: true}).click();
  await page.locator('.advanced-appearance > summary').click();
  const weight = page.getByRole('radiogroup', {name: 'Text weight', exact: true});
  await weight.getByRole('radio', {name: 'Regular', exact: true}).click();
  await page.keyboard.press('ArrowRight');
  await page.waitForFunction(() => window.StillleafReader.exportState().preferences.fontWeight === 700);
  assert.equal(await weight.getByRole('radio', {name: 'Bold', exact: true}).getAttribute('aria-checked'), 'true');
  await page.keyboard.press('Home');
  await page.waitForFunction(() => window.StillleafReader.exportState().preferences.fontWeight === null);
  await page.getByRole('radiogroup', {name: 'Alignment', exact: true}).getByRole('radio', {name: 'Justified'}).click();
  await page.getByRole('radiogroup', {name: 'Hyphenation', exact: true}).getByRole('radio', {name: 'Off'}).click();
  await page.waitForFunction(() => {
    const p = window.StillleafReader.exportState().preferences;
    return p.textAlign === 'justify' && p.hyphens === false;
  });
  await page.evaluate(() => window.StillleafReader.setPreferences({fontWeight: 550}));
  assert.equal(await weight.getByRole('radio', {name: 'Custom'}).getAttribute('aria-checked'), 'true');
  await weight.getByRole('radio', {name: 'Regular', exact: true}).click();
  await page.waitForFunction(() => window.StillleafReader.exportState().preferences.fontWeight === 400);
  assert.equal(await weight.getByRole('radio', {name: 'Custom'}).count(), 0);
  const output = process.env.READER_REVIEW_OUTPUT;
  if (output) await mkdir(output, {recursive: true});
  for (const theme of ['paper', 'dark']) {
    await page.evaluate(theme => window.StillleafReader.setPreferences({theme}), theme);
    if (output) await page.screenshot({path: path.join(output, `typography-${theme}.png`)});
  }
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => /^Page \d+ of \d+ · Chapter \d+$/.test(document.querySelector('#position-label').textContent));
  for (const width of [1000, 520, 360]) {
    await page.setViewportSize({width, height: 700});
    await page.waitForTimeout(300);
    const bounds = await page.evaluate(() => {
      const rect = selector => {
        const r = document.querySelector(selector).getBoundingClientRect();
        return {left: r.left, right: r.right, top: r.top, bottom: r.bottom};
      };
      return {navigation: rect('.footer-navigation'), book: rect('#position-label'), chapter: rect('#chapter-label'), reader: rect('#reading-viewport'), footer: rect('.reading-footer'), width: innerWidth, height: innerHeight};
    });
    assert.ok(bounds.navigation.right <= bounds.book.left, 'navigation and book pages do not overlap');
    assert.ok(bounds.book.right <= bounds.width && bounds.chapter.right <= bounds.width, 'progress remains inside window');
    assert.ok(bounds.footer.bottom <= bounds.height && bounds.reader.bottom <= bounds.footer.top, 'footer remains below reading surface');
    if (width > 460) assert.ok(bounds.book.right <= bounds.chapter.left, 'book and chapter pages have separate positions');
    if (output) await page.screenshot({path: path.join(output, `footer-${width}.png`)});
  }
});
