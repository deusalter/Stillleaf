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
 // Several chapters lay out at once; every late old-layout result must be ignored.
 const late=[],release=value=>late.forEach(resolve=>resolve(value));let started;const begun=new Promise(resolve=>started=resolve);
 const index=new ScreenPaginationIndex({measure:async(_chapter,_signal,key)=>{
  if(key==='old'){started();return new Promise(resolve=>late.push(resolve))}return 2;
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

test('chapters before the reader count first, several at a time, and a finished layout is reported once',async()=>{
 const order=[],completed=[];let inFlight=0,most=0;
 const index=new ScreenPaginationIndex({concurrency:3,completed:(key,counts)=>completed.push([key,counts]),measure:async chapter=>{
  order.push(chapter);most=Math.max(most,++inFlight);await new Promise(resolve=>setTimeout(resolve,5));inFlight--;return chapter+1;
 }});
 index.configure('layout',8,5);index.record(5,6);await index.queue;
 assert.deepEqual(order.slice(0,5).sort(),[0,1,2,3,4],'the page number settles before the total');
 assert.equal(most,3);
 assert.deepEqual(completed,[['layout',[1,2,3,4,5,6,7,8]]]);
 index.record(5,6);assert.equal(completed.length,1,'an unchanged map is not reported again');
 index.record(5,7);assert.deepEqual(completed.at(-1),['layout',[1,2,3,4,5,7,7,8]],'a live correction is reported');
 index.close();
});

test('saved layouts open exact without measuring, and serve as references for new ones',async()=>{
 let measured=0;const completed=[];
 const index=new ScreenPaginationIndex({completed:(key)=>completed.push(key),measure:async()=>{measured++;return 2}});
 index.seed([{key:'recent',counts:[3,4]},{key:'older',counts:[1,1]},{key:'wrong-shape',counts:[1,1,1]}]);
 index.configure('recent',2);await index.queue;
 assert.equal(measured,0);assert.deepEqual(index.pages(1,{first:1}),{first:4,last:4,total:7});
 assert.deepEqual(completed,[],'a saved layout is not sent back to the host');
 index.configure('new',2);
 assert.deepEqual(index.references(),[[3,4],[1,1]],'most recent first, matching this book only');
 await index.queue;assert.deepEqual(completed,['new']);index.close();
});

test('an invalidated chapter offers its last count while it is measured again',async()=>{
 const index=new ScreenPaginationIndex({measure:async()=>3});
 index.configure('layout',2);index.record(0,3);index.record(1,4);
 index.invalidate(1);assert.equal(index.counts[1],null);assert.equal(index.previous[1],4);
 index.configure('other',2);assert.deepEqual(index.previous,[],'a new layout has no previous counts');
 await index.queue;index.close();
});

test('a saved map that a live chapter contradicts is measured again and reported corrected',async()=>{
 const completed=[];let measured=0;
 const index=new ScreenPaginationIndex({completed:(key,counts)=>completed.push([key,counts]),measure:async chapter=>{measured++;return [2,5,4][chapter]}});
 index.seed([{key:'layout',counts:[9,9,9]}]);index.configure('layout',3);await index.queue;
 assert.equal(measured,0,'a saved map is trusted');
 index.record(0,9);await index.queue;assert.equal(measured,0,'a live chapter that agrees changes nothing');
 index.record(1,5);
 assert.deepEqual(index.counts,[null,5,null]);assert.deepEqual([index.previous[0],index.previous[2]],[9,9],'the saved counts stay as the best guess');
 await index.queue;
 assert.equal(measured,2);assert.deepEqual(completed,[['layout',[2,5,4]]]);
 index.record(2,4);index.record(0,2);await index.queue;assert.equal(measured,2,'once measured here, the map is trusted again');
 index.close();
});
