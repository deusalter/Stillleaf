import {test} from 'node:test';
import assert from 'node:assert/strict';
import {chromium, webkit} from 'playwright';
import {buildSync} from 'esbuild';
import {fileURLToPath} from 'node:url';

// The index must give the same text nodes a full walk of the chapter finds on screen, at every scroll offset and
// after every layout change, while measuring the chapter once per layout instead of once per page turn.
const bundle = buildSync({entryPoints: [fileURLToPath(new URL('../src/page-text-index.js', import.meta.url))], bundle: true, format: 'iife', globalName: 'textIndex', write: false}).outputFiles[0].text;

const paragraph = 'The ferry crossed slowly while the gulls kept pace with the wake. <em>Nothing</em> moved quickly there; even the <a href="#x">tide</a> seemed to wait. ';
const html = (extra = '') => `<!doctype html><html style="${extra}"><head><style>body{margin:0;font:1.125rem/1.5 serif;columns:2;column-gap:60px;height:100vh;padding:0 30px}p{margin:0 0 12px}script,style{display:none}</style></head><body>`
  + Array.from({length: 260}, (_, i) => `<p>${i}. ${paragraph.repeat(2)}</p>${i % 17 === 5 ? '<p>\n  </p>' : ''}`).join('') + '</body></html>';

test('page text index finds the same nodes as a full walk at every page and after layout changes', {timeout: 120000}, async t => {
  const browser = process.env.READER_TEST_BROWSER === 'webkit' ? await webkit.launch({headless: true})
    : await chromium.launch({executablePath: process.env.CHROME_PATH || (process.platform === 'darwin' ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : undefined), headless: true});
  t.after(() => browser.close());
  const page = await browser.newPage({viewport: {width: 900, height: 600}});
  await page.setContent('<iframe id="f" style="width:800px;height:500px;border:0"></iframe>');
  await page.addScriptTag({content: bundle});
  const result = await page.evaluate(async ({markup, alt}) => {
    const frame = document.getElementById('f'), wnd = frame.contentWindow, doc = frame.contentDocument;
    doc.open(); doc.write(markup); doc.close();
    await new Promise(resolve => setTimeout(resolve, 200));
    const fullWalk = (axis, from, to) => {
      const walk = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT), range = doc.createRange(), found = [];
      let node, offset = 0;
      while ((node = walk.nextNode())) {
        if (!node.parentElement?.closest('script,style') && node.textContent.trim()) {
          range.selectNodeContents(node);
          if ([...range.getClientRects()].some(r => r.width > 0 && r.height > 0 && (axis === 'x' ? r.right > from && r.left < to : r.bottom > from && r.top < to))) found.push(offset);
        }
        offset += node.length;
      }
      return found;
    };
    const check = axis => {
      const to = axis === 'x' ? wnd.innerWidth : wnd.innerHeight, offsets = textIndex.pageTextCandidates(wnd, axis, 0, to).map(c => c.offset);
      const expected = fullWalk(axis, 0, to);
      return {missing: expected.filter(o => !offsets.includes(o)).length, extra: offsets.length - expected.length, count: expected.length, ordered: offsets.every((o, i) => i === 0 || o > offsets[i - 1])};
    };
    const out = {pages: [], width: wnd.document.scrollingElement.scrollWidth};
    const step = wnd.innerWidth;
    for (let x = 0, i = 0; x < out.width && i < 40; x += step, i++) { wnd.scrollTo(x, 0); out.pages.push(check('x')); }
    // A layout change the index cannot see from the DOM alone: a larger font, applied through the root style.
    wnd.scrollTo(0, 0);
    const before = check('x');
    doc.documentElement.setAttribute('style', alt);
    await new Promise(resolve => setTimeout(resolve, 100));
    const afterWidth = wnd.document.scrollingElement.scrollWidth;
    const afterPages = [];
    for (let x = 0, i = 0; x < afterWidth && i < 40; x += step, i++) { wnd.scrollTo(x, 0); afterPages.push(check('x')); }
    // Content changes announced with touch(): a paragraph inserted at the start moves everything after it.
    const p = doc.createElement('p'); p.textContent = 'An inserted opening paragraph. '.repeat(30); doc.body.prepend(p);
    textIndex.touchTextIndex(doc);
    wnd.scrollTo(0, 0);
    const inserted = check('x');
    // Scrolled axis, as Readium's scroll mode lays out a chapter.
    doc.body.style.columns = 'auto'; doc.body.style.height = 'auto'; textIndex.touchTextIndex(doc);
    const vertical = [];
    for (let y = 0, i = 0; y < wnd.document.scrollingElement.scrollHeight && i < 30; y += wnd.innerHeight * 0.7, i++) { wnd.scrollTo(0, y); vertical.push(check('y')); }
    return {...out, before, afterWidth, afterPages, inserted, vertical};
  }, {markup: html(), alt: 'font-size:24px'});
  t.diagnostic(`${result.pages.length} pages of ${result.width}px, ${result.afterPages.length} after the font change, ${result.vertical.length} scrolled positions`);
  const exact = c => c.missing === 0 && c.ordered;
  assert.ok(result.pages.length > 8, 'the chapter spans many pages');
  assert.ok(result.pages.every(exact), 'a page lost a node the full walk found: ' + JSON.stringify(result.pages.filter(c => !exact(c))[0]));
  assert.ok(result.pages.every(c => c.extra <= 3), 'candidates stay close to the visible set');
  assert.ok(result.afterWidth > result.width, 'the larger font reflowed the chapter');
  assert.ok(result.afterPages.every(exact), 'a stale index survived a layout change: ' + JSON.stringify(result.afterPages.filter(c => !exact(c))[0]));
  assert.ok(exact(result.inserted), 'an announced content change was not picked up');
  assert.ok(result.vertical.length > 5 && result.vertical.every(exact), 'a scrolled chapter lost a node');
});

test('page text index measures a chapter once per layout, not once per page', {timeout: 60000}, async t => {
  const browser = process.env.READER_TEST_BROWSER === 'webkit' ? await webkit.launch({headless: true})
    : await chromium.launch({executablePath: process.env.CHROME_PATH || (process.platform === 'darwin' ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : undefined), headless: true});
  t.after(() => browser.close());
  const page = await browser.newPage({viewport: {width: 900, height: 600}});
  await page.setContent('<iframe id="f" style="width:800px;height:500px;border:0"></iframe>');
  await page.addScriptTag({content: bundle});
  const calls = await page.evaluate(async markup => {
    const frame = document.getElementById('f'), wnd = frame.contentWindow, doc = frame.contentDocument;
    doc.open(); doc.write(markup); doc.close();
    await new Promise(resolve => setTimeout(resolve, 200));
    const proto = wnd.Range.prototype, original = proto.getBoundingClientRect;
    let measured = 0;
    proto.getBoundingClientRect = function () { measured++; return original.call(this); };
    const perPage = [];
    for (let i = 0; i < 6; i++) { wnd.scrollTo(i * wnd.innerWidth, 0); const before = measured; textIndex.pageTextCandidates(wnd, 'x', 0, wnd.innerWidth); perPage.push(measured - before); }
    proto.getBoundingClientRect = original;
    return perPage;
  }, html());
  t.diagnostic('Range measurements per page: ' + calls.join(', '));
  assert.ok(calls[0] > 100, 'the first page builds the index');
  assert.deepEqual(calls.slice(1), [0, 0, 0, 0, 0], 'later pages of the same layout must not measure any text');
});
