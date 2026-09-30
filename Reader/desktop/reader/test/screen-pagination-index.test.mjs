import {test} from 'node:test';
import assert from 'node:assert/strict';
import {ScreenPaginationIndex} from '../src/screen-pagination-index.js';

test('whole-book screens sum chapters, include odd spreads, and invalidate layout generations',async()=>{
 const index=new ScreenPaginationIndex({measure:async chapter=>[4,3,1][chapter]});
 index.configure('book-facing-font1-1400x800',3);
 assert.equal(index.pages(1,{first:2}),null,'unknown chapters stay calculating');
 await index.queue;
 assert.deepEqual(index.pages(1,{first:2}),{first:6,last:6,total:8});
 index.configure('book-single-font1-700x800',3);index.record(0,7);index.record(1,5);index.record(2,1);
 assert.deepEqual(index.pages(1,{first:3}),{first:10,last:10,total:13});
 index.configure('book-facing-font1-1400x800',3);
 assert.deepEqual(index.pages(1,{first:2}),{first:6,last:6,total:8},'bounded layout cache reused');
 index.invalidate(1);assert.equal(index.pages(1,{first:2}),null);await index.queue;
 assert.equal(index.pages(1,{first:2}).total,8);index.close();
});

test('stale chapter measurements cannot populate a new font or viewport generation',async()=>{
 let release,started;const begun=new Promise(resolve=>started=resolve);
 const index=new ScreenPaginationIndex({measure:async(_chapter,_signal,key)=>{
  if(key==='old'){started();return new Promise(resolve=>release=resolve)}return 2;
 }});
 index.configure('old',2);await begun;
 index.configure('resized-new-font',2);release(99);await index.queue;
 assert.deepEqual(index.counts,[2,2]);assert.equal(index.pages(1,{first:1}).first,3);
 index.close();
});

test('a no-op preference or resize can resume an interrupted layout',async()=>{
 let release,started;const begun=new Promise(resolve=>started=resolve);let calls=0;
 const index=new ScreenPaginationIndex({measure:async()=>{if(!calls++){started();return new Promise(resolve=>release=resolve)}return 3}});
 index.configure('same-layout',2);await begun;index.cancel();index.configure('same-layout',2);release(99);await index.queue;
 assert.deepEqual(index.counts,[3,3]);index.close();
});

test('an unsettled chapter never becomes an invented exact denominator',async()=>{
 const index=new ScreenPaginationIndex({measure:async()=>{throw Error('pending image')}});
 index.configure('layout',2);index.record(0,3);await index.queue;
 assert.equal(index.pages(0,{first:1}),null);
 index.record(1,5);assert.deepEqual(index.pages(1,{first:2}),{first:5,last:5,total:8});index.close();
});
