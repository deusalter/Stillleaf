import {test} from 'node:test';
import assert from 'node:assert/strict';
import {screenPages,pageLabel} from '../src/page-progress.js';

test('screen page counts include the last partial page and clamp at either end',()=>{
 assert.deepEqual(screenPages({extent:2300,viewport:600,offset:1200}),{first:3,last:3,total:4});
 assert.equal(pageLabel(screenPages({extent:2300,viewport:600,offset:-20})),'Page 1 of 4');
 assert.equal(pageLabel(screenPages({extent:2300,viewport:600,offset:2400})),'Page 4 of 4');
 assert.equal(pageLabel(screenPages({extent:120,viewport:600})),'Page 1 of 1');
 assert.equal(screenPages({extent:0,viewport:600}),null);
 assert.equal(pageLabel(screenPages({extent:2300,viewport:600,offset:1700})),'Page 4 of 4','bottom-aligned partial final screen is the final page');
});
test('facing pages count each full spread once and tolerate floating point progressions',()=>{
 assert.equal(pageLabel(screenPages({extent:1,viewport:2/7,offset:2/7,columns:2})),'Page 2 of 4');
 assert.equal(pageLabel(screenPages({extent:1,viewport:2/7,offset:6/7,columns:2})),'Page 4 of 4');
 assert.equal(pageLabel(screenPages({extent:1,viewport:1/7,offset:3/7})),'Page 4 of 7');
});

test('book reference pages weight unequal chapters and retain covers independently of layout',async()=>{
 const {bookPages}=await import('../src/page-progress.js');
 const counts=[0,2048,1025,100];
 assert.deepEqual(bookPages({counts,chapter:0}),{first:1,last:1,total:6,remaining:0});
 assert.deepEqual(bookPages({counts,chapter:1,lower:1024,upper:1500}),{first:3,last:3,total:6,remaining:0});
 assert.deepEqual(bookPages({counts,chapter:2,lower:0,upper:1025,columns:2}),{first:4,last:5,total:6,remaining:0});
 assert.deepEqual(bookPages({counts,chapter:3,lower:0,atEnd:true}),{first:6,last:6,total:6,remaining:0});
 assert.deepEqual(bookPages({counts,chapter:1,lower:0,upper:900}),{first:2,last:2,total:6,remaining:1});
 assert.equal(bookPages({counts:null,chapter:0}),null);
 assert.equal(bookPages({counts,chapter:-1}),null);
 assert.deepEqual(bookPages({counts,chapter:2,progression:1}),{first:5,last:5,total:6,remaining:0});
});
test('chapter pages remaining reach zero on a partial final continuous screen',async()=>{
 const {chapterPagesLeft}=await import('../src/page-progress.js');
 assert.equal(chapterPagesLeft({extent:2300,viewport:600,offset:0}),3);
 assert.equal(chapterPagesLeft({extent:2300,viewport:600,offset:1700}),0);
 assert.equal(chapterPagesLeft({extent:2400,viewport:1200,columns:2}),1);
 assert.equal(chapterPagesLeft({extent:100,viewport:600}),0);
 assert.equal(chapterPagesLeft({extent:0,viewport:600}),null);
});
