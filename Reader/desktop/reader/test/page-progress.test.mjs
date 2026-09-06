import {test} from 'node:test';
import assert from 'node:assert/strict';
import {screenPages,pageLabel} from '../src/page-progress.js';

test('screen page counts include the last partial page and clamp at either end',()=>{
 assert.deepEqual(screenPages({extent:2300,viewport:600,offset:1200}),{first:3,last:3,total:4});
 assert.equal(pageLabel(screenPages({extent:2300,viewport:600,offset:-20})),'Page 1 of 4');
 assert.equal(pageLabel(screenPages({extent:2300,viewport:600,offset:2400})),'Page 4 of 4');
 assert.equal(pageLabel(screenPages({extent:120,viewport:600})),'Page 1 of 1');
 assert.equal(screenPages({extent:0,viewport:600}),null);
});
test('facing pages use two leaves per visible spread and tolerate floating point progressions',()=>{
 assert.equal(pageLabel(screenPages({extent:1,viewport:2/7,offset:2/7,columns:2})),'Pages 3–4 of 7');
 assert.equal(pageLabel(screenPages({extent:1,viewport:2/7,offset:6/7,columns:2})),'Page 7 of 7');
 assert.equal(pageLabel(screenPages({extent:1,viewport:1/7,offset:3/7})),'Page 4 of 7');
});
