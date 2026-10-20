import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,statSync} from 'node:fs';

// The Mac reader parses this script every time a book opens. css-tree's full entry alone added
// about 120 KB of validator tables the publisher-CSS rewrite never uses; keep the main chunk lean.
const budget=650*1024;

test('the renderer entry chunk stays within its size budget',()=>{
 const dist=new URL('../dist/',import.meta.url);
 const entry=readFileSync(new URL('index.html',dist),'utf8').match(/src="\.\/(assets\/index-[^"]+\.js)"/)?.[1];
 assert.ok(entry,'dist/index.html names its entry script (run npm run build first)');
 const size=statSync(new URL(entry,dist)).size;
 assert.ok(size<=budget,`entry chunk is ${(size/1024).toFixed(0)} KB, over the ${budget/1024} KB budget`);
 assert.doesNotMatch(readFileSync(new URL('../src/resources.js',import.meta.url),'utf8'),/from 'css-tree';/,
  'import css-tree/parser, /walker and /generator rather than the full entry');
});
