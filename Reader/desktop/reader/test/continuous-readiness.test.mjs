import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import {build} from 'esbuild';
import {chromium, webkit} from 'playwright';

test('continuous chapter operations defer until document readiness and resume with retained preferences and notes', {timeout: 30000}, async t => {
  const bundle = await build({entryPoints: [path.resolve(import.meta.dirname, '../src/continuous.js')], bundle: true, write: false, format: 'iife', globalName: 'ReaderLifecycle'});
  const engine = process.env.READER_TEST_BROWSER === 'webkit' ? webkit : chromium;
  const browser = await engine.launch({...(engine === chromium && process.env.CHROME_PATH ? {executablePath: process.env.CHROME_PATH} : {}), headless: true});
  t.after(() => browser.close());
  const page = await browser.newPage({viewport: {width: 800, height: 600}});
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  await page.setContent('<div id="reader" style="height:400px;width:600px;overflow:auto"></div>');
  await page.addScriptTag({content: bundle.outputFiles[0].text});
  const result = await page.evaluate(async () => {
    const container = document.getElementById('reader');
    const settings = {fontSize: 1, lineHeight: 1.6, backgroundColor: '#ffffff', textColor: '#000000', linkColor: '#0000ff', selectionBackgroundColor: '#eeeeee'};
    const html = '<html><body><p id="passage">A passage worth keeping.</p><p>Another line for the reader.</p></body></html>';
    const positions = [], reportedErrors = [];
    const reader = new ReaderLifecycle.ContinuousNavigator(container, {readingOrder: [{href: 'chapter.html', title: 'Chapter'}]},
      {size: () => html.length, chapter: async () => html},
      {positionChanged: value => positions.push(value.serialize()), error: error => reportedErrors.push(error.message)}, null, settings);
    // Use a real iframe Document and the actual adapter methods. Its entry is
    // visible before it has a body or a stylesheet owned by that document.
    const frame = document.createElement('iframe'); frame.style.height='200px'; container.append(frame);
    const doc = frame.contentDocument, body = doc.body;
    body.innerHTML = '<p id="passage">A passage worth keeping.</p><p>Another line for the reader.</p>';
    const staging = new DOMParser().parseFromString('<html><head><style></style></head><body></body></html>', 'text/html');
    const entry = {frame, section: frame, index: 0, link: {href: 'chapter.html'}, height: 200,
      appearance: staging.querySelector('style'), ranges: [], geometryRevision: 0};
    reader.entries = [entry];
    const pendingOwnedDocument = reader.loadedDocument(entry);
    body.remove();
    const pendingAnchor = reader.captureAnchor();
    const pendingRestore = reader.restoreAnchorNow({locator: {href: 'chapter.html', locations: {progression: 0}}, offset: 0});
    reader.invalidate(entry); await reader.remeasure();
    reader.applyDecorations([{id: 'kept', locator: {href: 'chapter.html', text: {highlight: 'A passage worth keeping.'}}, style: {tint: '#e4c778'}}]);
    await reader.submitPreferences({...settings, fontSize: 1.75});
    const positionsBeforeReady = positions.length;
    doc.documentElement.append(body);
    entry.appearance = doc.createElement('style'); doc.head.append(entry.appearance);
    // The same post-load operations must now observe the latest settings and
    // retained decorations, rather than the stale preparatory document.
    await reader.submitPreferences(reader.settings); reader.paint(entry);
    const result = {pendingOwnedDocument, pendingAnchor, pendingRestore, positionsBeforeReady, reportedErrors,
      loaded: Boolean(reader.loadedDocument(entry)), zoom: doc.defaultView.getComputedStyle(doc.body).zoom,
      highlights: [...doc.defaultView.CSS.highlights.values()].flatMap(highlight => [...highlight].map(range => range.toString())),
      href: reader.captureLocator()?.href};
    frame.remove(); return result;
  });
  assert.equal(result.pendingOwnedDocument, null, 'an about:blank document is not a loaded chapter');
  assert.equal(result.pendingAnchor, null);
  assert.equal(result.pendingRestore, false);
  assert.equal(result.positionsBeforeReady, 0, 'incomplete documents never publish a fabricated position');
  assert.equal(result.loaded, true);
  assert.equal(Number(result.zoom), 1.75, 'preference updates resume with the settings retained during loading');
  assert.deepEqual(result.highlights, ['A passage worth keeping.'], 'deferred decorations paint when the chapter is ready');
  assert.equal(result.href, 'chapter.html');
  assert.deepEqual(result.reportedErrors, []);
  assert.deepEqual(errors, []);
});
