const {test} = require('node:test');
const assert = require('node:assert/strict');
const {ImportCoordinator, epubArguments} = require('../src/import-coordinator.cjs');

test('cold OS events wait for host readiness and present one Library', async () => {
  let presentations = 0; const imported = [];
  const queue = new ImportCoordinator({presentLibrary: () => presentations++, importFile: async path => { imported.push(path); return {status:'imported', publication:{id:path}}; }});
  await queue.enqueue(['/fixtures/a.epub']); await queue.enqueue(['/fixtures/b.epub','/fixtures/a.epub']);
  assert.equal(presentations, 0); assert.equal(imported.length, 0);
  await queue.setReady();
  assert.equal(presentations, 1); assert.equal(imported.length, 2);
  assert.deepEqual(queue.snapshot().items.map(x=>x.state), ['imported','imported']);
});

test('warm events append to one serial queue, preserve failure and cancellation outcomes', async () => {
  let finish; let active = 0, maximum = 0;
  const queue = new ImportCoordinator({presentLibrary:()=>{}, importFile: async path => {
    maximum = Math.max(maximum, ++active);
    if (path.endsWith('/a.epub')) await new Promise(resolve => finish = resolve);
    active--; return {status:'imported', publication:{id:path}};
  }});
  await queue.setReady();
  const batch = queue.enqueue(['/fixtures/a.epub', '/fixtures/invalid.pdf']);
  await new Promise(resolve => setImmediate(resolve));
  queue.enqueue(['/fixtures/b.epub']); queue.cancelPending(); finish(); await batch;
  assert.equal(maximum, 1);
  assert.deepEqual(queue.snapshot().items.map(x=>x.state), ['imported','failed','cancelled']);
});

test('later explicit open can return a duplicate without reading', async () => {
  let count = 0;
  const queue = new ImportCoordinator({presentLibrary:()=>{}, importFile: async () => ({status: ++count === 1 ? 'imported' : 'duplicate'})});
  await queue.setReady(); await queue.enqueue(['/fixtures/a.epub']); await queue.enqueue(['/fixtures/a.epub']);
  assert.equal(queue.snapshot().items[0].state, 'duplicate');
});

test('invalid importer results fail and next file proceeds; queue cap bounds a batch', async () => {
  const queue = new ImportCoordinator({limit:2, presentLibrary:()=>{}, importFile:async path => path.endsWith('/a.epub') ? {} : {status:'imported'}});
  await queue.setReady(); await queue.enqueue(['/fixtures/a.epub','/fixtures/b.epub','/fixtures/c.epub']);
  assert.deepEqual(queue.snapshot().items.map(x=>x.state), ['failed','imported']); assert.equal(queue.snapshot().overflow,1);
});

test('OS arguments exclude executables and options', () => {
  assert.deepEqual(epubArguments(['/app/Stillleaf','--inspect','/books/a.EPUB','relative.epub','/books/a.pdf']), ['/books/a.EPUB']);
});

 test('Windows argv and case aliases use Windows path semantics even in fixture tests', async () => {
  assert.deepEqual(epubArguments(['C:\\Stillleaf.exe','C:\\Books\\One.epub'], 'win32'), ['C:\\Books\\One.epub']);
  const queue = new ImportCoordinator({platform:'win32', presentLibrary:()=>{}, importFile:async()=>({status:'imported'})});
  await queue.enqueue(['C:\\Books\\One.epub','c:\\books\\one.EPUB']);
  await queue.setReady(); assert.equal(queue.snapshot().items.length,1);
});
