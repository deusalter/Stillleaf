import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium, webkit} from 'playwright';

test('held navigation keys settle on release and secondary link clicks preserve the reading place', {timeout: 90000}, async t => {
  const root = path.resolve(import.meta.dirname, '../dist');
  const server = createServer(async (req, res) => {
    try {
      const file = path.resolve(root, '.' + new URL(req.url, 'http://localhost').pathname);
      if (!file.startsWith(root + path.sep)) throw Error();
      res.setHeader('Content-Type', {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css'}[path.extname(file)] ?? 'application/octet-stream');
      res.end(await readFile(file));
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const engine = process.env.READER_TEST_BROWSER === 'webkit' ? webkit : chromium;
  let browser;
  t.after(async () => { await browser?.close(); server.closeAllConnections(); server.close(); });
  browser = await engine.launch({...(engine === chromium ? {executablePath: process.env.CHROME_PATH || (process.platform === 'darwin' ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : undefined)} : {}), headless: true});
  const page = await browser.newPage({viewport: {width: 1000, height: 800}, reducedMotion: 'no-preference'});
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  const chapter = '<!doctype html><html><body><h1>First chapter</h1><a id="jump" href="two.html">Read the ending</a>'
    + '<p>A quiet passage with room to read, and long afternoons in the garden.</p>'.repeat(1000) + '</body></html>';
  await page.evaluate(book => StillleafReader.open(book), {
    editionId: 'input-navigation', title: 'Input navigation',
    readingOrder: ['one.html', 'two.html'].map(href => ({href, type: 'text/html'})),
    resources: [{href: 'one.html', type: 'text/html', dataBase64: Buffer.from(chapter).toString('base64')},
      {href: 'two.html', type: 'text/html', dataBase64: Buffer.from('<html><body><h1>The ending</h1><p>A quiet conclusion.</p></body></html>').toString('base64')}],
  });
  await page.evaluate(() => {
    window.turnEvents = [];
    window.addEventListener('stillleaf-reader-event', event => {
      if (event.detail.type === 'pageTurn') turnEvents.push({time: performance.now(), direction: event.detail.direction});
    });
  });
  for (const key of ['ArrowRight', 'PageDown']) {
    const result = await page.evaluate(async key => {
      turnEvents.length = 0;
      for (let index = 0; index < 15; index++) {
        window.dispatchEvent(new KeyboardEvent('keydown', {key, repeat: index > 0, bubbles: true, cancelable: true}));
        await new Promise(resolve => setTimeout(resolve, 30));
      }
      const released = performance.now();
      window.dispatchEvent(new KeyboardEvent('keyup', {key, bubbles: true}));
      // Appearance waits for the real navigation queue; no guessed settle delay.
      await StillleafReader.setPreferences({});
      return {turns: turnEvents.length, afterRelease: turnEvents.filter(event => event.time > released).length};
    }, key);
    assert.ok(result.turns > 0 && result.turns < 15, `${key} repeats do not accumulate queued turns`);
    assert.ok(result.afterRelease <= 1, `${key} may finish its active turn after release, with no repeat backlog`);
  }
  const directions = await page.evaluate(async () => {
    turnEvents.length = 0;
    for (const key of ['ArrowLeft', 'ArrowLeft']) window.dispatchEvent(new KeyboardEvent('keydown', {key, repeat: false, bubbles: true, cancelable: true}));
    await StillleafReader.setPreferences({});
    return turnEvents.map(event => event.direction);
  });
  assert.deepEqual(directions, ['backward', 'backward'], 'separate key presses remain queued');
  assert.deepEqual(await page.evaluate(async () => {
    turnEvents.length = 0;
    await Promise.all(['next', 'next', 'previous', 'previous'].map(direction => StillleafReader[direction]()));
    return turnEvents.map(event => event.direction);
  }), ['forward', 'forward', 'backward', 'backward'], 'programmatic navigation remains lossless');

  await page.emulateMedia({reducedMotion: 'reduce'});
  const returnToStart = async () => {
    await page.evaluate(() => StillleafReader.go({href: 'one.html', type: 'text/html', locations: {progression: 0}}));
    await page.waitForFunction(() => StillleafReader.bookmark()?.href === 'one.html');
  };
  await returnToStart();
  const link = page.locator('#reader iframe:visible').first().contentFrame().locator('#jump');
  for (const options of [{button: 'right'}, {button: 'middle'}, {modifiers: ['Meta']}, {modifiers: ['Control']}, {modifiers: ['Alt']}, {modifiers: ['Shift']}]) {
    await link.click(options);
    await page.evaluate(() => StillleafReader.setPreferences({}));
    assert.equal(await page.evaluate(() => StillleafReader.bookmark().href), 'one.html', `secondary or modified click preserves place: ${JSON.stringify(options)}`);
  }
  assert.equal(page.context().pages().length, 1, 'modified links do not open unsupported publication tabs');
  await link.click();
  await page.waitForFunction(() => StillleafReader.bookmark()?.href === 'two.html');
  await returnToStart();
  await link.focus(); await page.keyboard.press('Enter');
  await page.waitForFunction(() => StillleafReader.bookmark()?.href === 'two.html');
});
