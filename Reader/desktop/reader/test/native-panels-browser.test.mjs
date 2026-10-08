import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {chromium, webkit} from 'playwright';

// The native host's Contents, Bookmarks, Notes and Search panels are fed by the renderer over the
// native-control channel. Rows go out, ids come back, and the renderer keeps the locators.
const titles = ['PROLOGUE', 'BOOK ONE', 'CHAPTER ONE', 'CHAPTER TWO', 'Notes on the Text'];
const chapter = title => `<html><body><h1>${title}</h1>${'<p>The light fell across the open book. She turned a page and settled into her chair.</p>'.repeat(30)}</body></html>`;
const locator = (index, progression = .2) => ({href: `c${index}.html`, type: 'text/html', locations: {progression}, text: {highlight: 'The light fell across the open book.'}});
const book = {
  editionId: 'native-panels', title: 'At the lakeside', contentProgress: true,
  readingOrder: titles.map((title, i) => ({href: `c${i}.html`, type: 'text/html', title})),
  toc: [{title: 'PROLOGUE', href: 'c0.html'}, {title: 'BOOK ONE', href: 'c1.html', children: [{title: 'CHAPTER ONE', href: 'c2.html'}, {title: 'CHAPTER TWO', href: 'c3.html'}]}, {title: 'Notes on the Text', href: 'c4.html'}],
  landmarks: [{title: 'Start of reading', href: 'c1.html'}],
  resources: titles.map((title, i) => ({href: `c${i}.html`, type: 'text/html', dataBase64: Buffer.from(chapter(title)).toString('base64')})),
  state: {schemaVersion: 1, editionId: 'native-panels', revision: 0, position: null, preferences: {theme: 'paper', fontFamily: 'publisher', fontSize: 1.2, lineHeight: 1.6, measure: 65},
    bookmarks: [{id: 'b1', locator: locator(2), label: 'CHAPTER ONE', createdAt: '2026-10-01T10:00:00Z'}, {id: 'b2', locator: locator(3), label: 'CHAPTER TWO', createdAt: '2026-10-03T10:00:00Z'}],
    annotations: [{id: 'n1', locator: locator(2), quote: 'The light fell across the open book.', note: 'Remember the light.', color: 'gold', createdAt: '2026-10-01T10:00:00Z', updatedAt: '2026-10-01T10:00:00Z'},
      {id: 'n2', locator: locator(3), quote: 'She turned a page.', note: '', color: 'sage', createdAt: '2026-10-02T10:00:00Z', updatedAt: '2026-10-02T10:00:00Z'}]},
};

test('native panels read rows from the renderer, send ids back, and cannot forge locators', {timeout: 90000}, async t => {
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
  const page = await browser.newPage({viewport: {width: 1100, height: 800}, reducedMotion: 'reduce'});
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  await page.evaluate(b => window.StillleafReader.open(b), book);
  let id = 0;
  const send = (command, payload) => page.evaluate(request => window.StillleafReader.nativeControl(request),
    {version: 1, editionId: book.editionId, id: ++id, command, ...(payload === undefined ? {} : {payload})});
  const href = () => page.evaluate(() => window.StillleafReader.bookmark()?.href);
  await send('activate');

  // Contents: a tree, titles shown as titles, landmarks grouped, the current chapter marked.
  const outline = (await send('panel', {name: 'outline'})).panel;
  assert.equal(outline.name, 'outline');
  assert.deepEqual(outline.rows.map(r => r.title), ['Prologue', 'Book One', 'Notes on the Text', 'Landmarks']);
  assert.deepEqual(outline.rows[1].children.map(r => r.title), ['Chapter One', 'Chapter Two']);
  assert.equal(outline.rows[3].group, true);
  assert.equal(outline.rows[3].openable, false);
  assert.deepEqual(outline.rows[3].children.map(r => r.title), ['Start of reading']);
  assert.equal(outline.rows[0].current, true, 'the book opens at its first chapter');
  assert.match(outline.empty, /table of contents/, 'the host shows this when there are no rows');
  const chapterTwo = outline.rows[1].children[1];
  const afterGo = await send('go', {kind: 'outline', id: chapterTwo.id});
  assert.equal(await href(), 'c3.html', 'opening a row navigates to its chapter');
  assert.equal(afterGo.dialogOpen, false, 'the web panel does not open');
  assert.equal((await send('panel', {name: 'outline'})).panel.rows[1].children[1].current, true, 'the current chapter follows the reading place');
  await assert.rejects(send('go', {kind: 'outline', id: 'o999'}), /not available/);
  await assert.rejects(send('go', {kind: 'outline', id: outline.rows[3].id}), /not available/, 'a group has no target');

  // Bookmarks and notes.
  const marks = (await send('panel', {name: 'bookmarks'})).panel;
  assert.deepEqual(marks.rows.map(r => [r.id, r.title]), [['b1', 'Chapter One'], ['b2', 'Chapter Two']]);
  assert.match(marks.empty, /bookmark/i);
  await send('go', {kind: 'bookmark', id: 'b1'});
  assert.equal(await href(), 'c2.html');
  const afterRemove = await send('remove', {kind: 'bookmark', id: 'b1'});
  assert.deepEqual(afterRemove.panel.rows.map(r => r.id), ['b2']);
  assert.equal(await page.evaluate(() => window.StillleafReader.exportState().bookmarks.length), 1);
  await assert.rejects(send('go', {kind: 'bookmark', id: 'missing'}), /not available/);
  const notes = (await send('panel', {name: 'notes'})).panel;
  assert.deepEqual(notes.rows.map(r => [r.id, r.quote, r.note, r.color]), [['n1', 'The light fell across the open book.', 'Remember the light.', '#e4c778'], ['n2', 'She turned a page.', '', '#a7cbb0']]);
  await send('go', {kind: 'note', id: 'n2'});
  assert.equal(await href(), 'c3.html');
  const edited = await send('editNote', {id: 'n1'});
  assert.equal(edited.dialogOpen, true, 'the note editor is the web dialog');
  assert.equal(await page.locator('#note-text').inputValue(), 'Remember the light.');
  await page.locator('#note-panel [data-close]').click();
  await assert.rejects(send('editNote', {id: 'nope'}), /not available/);
  const afterNoteRemove = await send('remove', {kind: 'note', id: 'n2'});
  assert.deepEqual(afterNoteRemove.panel.rows.map(r => r.id), ['n1']);

  // Search: rows with the match marked, a floor on the query, and newer searches supersede older ones.
  const short = (await send('find', {query: 'a'})).panel;
  assert.deepEqual([short.rows, short.status], [[], 'Enter at least two characters.']);
  const found = (await send('find', {query: 'light'})).panel;
  assert.equal(found.name, 'search');
  assert.ok(found.rows.length >= 5 && found.rows.length <= 200);
  assert.deepEqual(Object.keys(found.rows[0]).sort(), ['after', 'before', 'chapter', 'id', 'match']);
  assert.equal(found.rows[0].match.toLowerCase(), 'light');
  assert.match(found.status, /matching passages/);
  assert.equal(found.rows[0].chapter, 'Prologue');
  const none = (await send('find', {query: 'zzzzzz'})).panel;
  assert.deepEqual([none.rows, none.status], [[], 'No matching passages.']);
  const [first, second] = await Promise.all([send('find', {query: 'light'}), send('find', {query: 'chair'})]);
  assert.equal(first.panel.stale, true, 'a search that was overtaken says so');
  assert.equal(second.panel.query, 'chair');
  assert.ok(second.panel.rows.length > 0 && !second.panel.stale);
  const target = second.panel.rows[7];
  await send('go', {kind: 'result', id: target.id});
  assert.equal(await href(), 'c0.html', 'a result opens the chapter it came from');
  await assert.rejects(send('go', {kind: 'result', id: 'r9999'}), /not available/);

  // A web dialog open means the web owns the screen.
  await send('search');
  await assert.rejects(send('panel', {name: 'outline'}), /Finish the open/);
});
